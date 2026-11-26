//! lcgf-gen's HTML front end: one page and its stylesheets in, one Zig module out.
//!
//!   lcgf-gen page.html [--css extra.css]... --lang zig -o OUT [--depfile OUT.d]
//!            [--check VENDORED] [--explain] [--no-warnings]
//!   lcgf-gen --mappings        (the manifest as TSV)
//!
//! On any error nothing is written: the messages go to stderr in GNU format and the exit code
//! is 1. Output is deterministic: no timestamps, a fixed number format.

const std = @import("std");
const lcgf = @import("lcgf");
const diag = @import("diag.zig");
const html = @import("html.zig");
const css = @import("css.zig");
const cascade = @import("cascade.zig");
const lower = @import("lower.zig");
const manifest = @import("manifest.zig");
const emit_zig = @import("emit_zig.zig");

const ua_css = @embedFile("ua.css");

pub const Options = struct {
    html: ?[]const u8 = null,
    css: std.ArrayList([]const u8) = .empty,
    lang: []const u8 = "zig",
    out: ?[]const u8 = null,
    depfile: ?[]const u8 = null,
    check: ?[]const u8 = null,
    mappings: bool = false,
    explain: bool = false,
    warnings: bool = true,
    frontend: Frontend = .auto,
};

/// Whether `args` asks for this front end: an `.html` input or `--mappings`.
pub fn wants(args: []const []const u8) bool {
    for (args) |a| if (std.mem.endsWith(u8, a, ".html") or std.mem.eql(u8, a, "--mappings")) return true;
    return false;
}

pub fn main(io: std.Io, arena: std.mem.Allocator, args: []const []const u8) !u8 {
    var o: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const value = struct {
            fn next(list: []const []const u8, at: *usize) ?[]const u8 {
                at.* += 1;
                return if (at.* < list.len) list[at.*] else null;
            }
        }.next;
        if (std.mem.eql(u8, a, "--css")) {
            try o.css.append(arena, value(args, &i) orelse return usage());
        } else if (std.mem.eql(u8, a, "--lang")) {
            o.lang = value(args, &i) orelse return usage();
        } else if (std.mem.eql(u8, a, "-o")) {
            o.out = value(args, &i) orelse return usage();
        } else if (std.mem.eql(u8, a, "--depfile")) {
            o.depfile = value(args, &i) orelse return usage();
        } else if (std.mem.eql(u8, a, "--check")) {
            o.check = value(args, &i) orelse return usage();
        } else if (std.mem.eql(u8, a, "--frontend")) {
            const f = value(args, &i) orelse return usage();
            o.frontend = std.meta.stringToEnum(Frontend, f) orelse {
                std.log.err("--frontend {s}: the Zig emitter has the spec and runtime frontends (tables and static are C++/Rust, M6)", .{f});
                return 2;
            };
        } else if (std.mem.eql(u8, a, "--mappings")) {
            o.mappings = true;
        } else if (std.mem.eql(u8, a, "--explain")) {
            o.explain = true;
        } else if (std.mem.eql(u8, a, "--no-warnings")) {
            o.warnings = false;
        } else if (std.mem.eql(u8, a, "--no-line-directives")) {} else if (a.len > 0 and a[0] == '-') {
            return usage();
        } else o.html = a;
    }
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    if (o.mappings) {
        try manifest.writeTsv(&stdout.interface);
        try stdout.interface.flush();
        return 0;
    }
    if (!std.mem.eql(u8, o.lang, "zig")) {
        std.log.err("--lang {s}: the C++ and Rust emitters wait for the C ABI (docs/plans/markup-compiler.md M6/M7)", .{o.lang});
        return 2;
    }
    const path = o.html orelse return usage();
    var ds: diag.Diags = .{ .arena = arena, .warnings = o.warnings };
    var deps: std.ArrayList([]const u8) = .empty;
    const result = compile(io, arena, &ds, &deps, path, o.css.items, o.explain, o.frontend);
    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
    try ds.render(&stderr.interface);
    try stderr.interface.flush();
    const text = result orelse return 1;
    if (o.check) |vendored| {
        const have = std.Io.Dir.cwd().readFileAlloc(io, vendored, arena, .limited(16 << 20)) catch "";
        if (!std.mem.eql(u8, have, text)) {
            try stderr.interface.print("{s}: error: {s} is stale: regenerate with zig build -Dmarkup-emit={s}\n", .{ vendored, vendored, std.fs.path.dirname(vendored) orelse "." });
            try stderr.interface.flush();
            return 1;
        }
        try deps.append(arena, vendored);
    }
    if (o.out) |out| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = text });
        if (o.depfile) |d| {
            var dep: std.ArrayList(u8) = .empty;
            try dep.print(arena, "{s}:", .{out});
            for (deps.items) |p| {
                try dep.append(arena, ' ');
                for (p) |ch| {
                    if (ch == ' ') try dep.append(arena, '\\');
                    try dep.append(arena, ch);
                }
            }
            try dep.append(arena, '\n');
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = d, .data = dep.items });
        }
    } else {
        try stdout.interface.writeAll(text);
        try stdout.interface.flush();
    }
    return 0;
}

fn usage() u8 {
    std.log.err("usage: lcgf-gen page.html [--css extra.css]... --lang zig -o OUT [--depfile OUT.d] [--check VENDORED]  |  lcgf-gen --mappings", .{});
    return 2;
}

/// Loads `@import`ed and `<link>`ed stylesheets relative to the page.
const Loader = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    dir: []const u8,
    deps: *std.ArrayList([]const u8),
    loaded: std.ArrayList([]const u8) = .empty,

    fn file(l: *Loader, c: *css.Css, href: []const u8, at: diag.Loc) ?u16 {
        if (std.mem.startsWith(u8, href, "http:") or std.mem.startsWith(u8, href, "https:") or std.mem.startsWith(u8, href, "//")) {
            c.ds.err(at, "{s}", .{manifest.refusal("value", "remote-url", "").?});
            return null;
        }
        const path = std.fs.path.join(l.arena, &.{ l.dir, href }) catch @panic("out of memory");
        for (l.loaded.items) |p| if (std.mem.eql(u8, p, path)) {
            c.ds.err(at, "{s} is imported twice", .{href});
            return null;
        };
        const bytes = std.Io.Dir.cwd().readFileAlloc(l.io, path, l.arena, .limited(4 << 20)) catch |e| {
            c.ds.err(at, "cannot read {s}: {s}", .{ path, @errorName(e) });
            return null;
        };
        l.loaded.append(l.arena, path) catch @panic("out of memory");
        l.deps.append(l.arena, path) catch @panic("out of memory");
        return c.ds.addFile(path, bytes);
    }

    pub fn load(l: *Loader, c: *css.Css, a: u32, b: u32) ?[2]u32 {
        _ = b;
        const t = c.toks.get(a);
        const href = switch (t.type) {
            .string, .url => t.str,
            .function => if (css.eq(t.str, "url") and a + 1 < c.toks.len and c.toks.items(.type)[a + 1] == .string) c.toks.items(.str)[a + 1] else {
                c.ds.err(t.loc, "@import takes a quoted path", .{});
                return null;
            },
            else => {
                c.ds.err(t.loc, "@import takes a quoted path", .{});
                return null;
            },
        };
        const f = l.file(c, href, t.loc) orelse return null;
        return c.tokenize(f, 0, c.ds.files.items[f].bytes);
    }
};

/// The generated module's source, or null after reporting errors.
pub fn compile(io: std.Io, arena: std.mem.Allocator, ds: *diag.Diags, deps: *std.ArrayList([]const u8), path: []const u8, extra_css: []const []const u8, explain: bool, frontend: Frontend) ?[]const u8 {
    const src = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20)) catch |e| {
        std.log.err("cannot read {s}: {s}", .{ path, @errorName(e) });
        return null;
    };
    deps.append(arena, path) catch @panic("out of memory");
    // Messages name the page as the build gave it, without a leading "./".
    const file = ds.addFile(if (std.mem.startsWith(u8, path, "./")) path[2..] else path, src);
    if (!std.unicode.utf8ValidateSlice(src)) {
        ds.err(.{ .file = file, .off = 0 }, "only UTF-8 sources are read", .{});
        return null;
    }
    const doc = html.parse(arena, ds, file) catch {
        ds.err(.{ .file = file }, "the HTML parser failed", .{});
        return null;
    };
    var c: css.Css = .{ .arena = arena, .ds = ds };
    var loader: Loader = .{ .io = io, .arena = arena, .dir = std.fs.path.dirname(path) orelse ".", .deps = deps };
    // The UA sheet, behind the default theme's tokens.
    {
        const th: lcgf.widgets_base.Theme = .{};
        var text: std.ArrayList(u8) = .empty;
        text.appendSlice(arena, ":root {") catch unreachable;
        inline for (.{ "text", "panel", "control", "control_hot", "control_held", "accent" }) |f| {
            const col = @field(th, f);
            text.print(arena, " --lcgf-{s}: #{x:0>2}{x:0>2}{x:0>2}{x:0>2};", .{ comptime dash(f), col.r, col.g, col.b, col.a }) catch unreachable;
        }
        inline for (.{ "text_px", "radius", "pad", "gap" }) |f| text.print(arena, " --lcgf-{s}: {d}px;", .{ comptime dash(f), @field(th, f) }) catch unreachable;
        text.appendSlice(arena, " }\n" ++ ua_css) catch unreachable;
        const f = ds.addFile("ua.css", text.items);
        const r = c.tokenize(f, 0, text.items);
        c.sheet(r[0], r[1], .ua, css.NoImports{});
    }
    // Author sheets in document order, then --css.
    const kinds = doc.nodes.items(.kind);
    for (0..doc.nodes.len) |n_| {
        const n: u32 = @intCast(n_);
        if (kinds[n] != .element) continue;
        if (doc.isElement(n, "link")) {
            const rel = doc.value(n, "rel") orelse continue;
            if (!std.ascii.eqlIgnoreCase(rel, "stylesheet")) continue;
            const href_a = doc.attr(n, "href") orelse {
                ds.err(doc.loc(n), "<link rel=stylesheet> needs href", .{});
                continue;
            };
            const f = loader.file(&c, doc.attrs.items(.value)[href_a], doc.valueLoc(href_a)) orelse continue;
            const r = c.tokenize(f, 0, ds.files.items[f].bytes);
            c.sheet(r[0], r[1], .author, &loader);
        } else if (doc.isElement(n, "style")) {
            if (n + 1 < doc.nodes.len and doc.nodes.items(.parent)[n + 1] == n and kinds[n + 1] == .text) {
                const r = c.tokenize(file, doc.nodes.items(.src)[n + 1], doc.nodes.items(.name)[n + 1]);
                c.sheet(r[0], r[1], .author, &loader);
            }
        }
    }
    for (extra_css) |p| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(4 << 20)) catch |e| {
            std.log.err("cannot read {s}: {s}", .{ p, @errorName(e) });
            return null;
        };
        deps.append(arena, p) catch @panic("out of memory");
        const f = ds.addFile(p, bytes);
        const r = c.tokenize(f, 0, bytes);
        c.sheet(r[0], r[1], .author, &loader);
    }
    // Inline styles.
    for (0..doc.nodes.len) |n_| {
        const n: u32 = @intCast(n_);
        if (kinds[n] != .element) continue;
        const a = doc.attr(n, "style") orelse continue;
        const v = doc.attrs.items(.value)[a];
        const r = c.tokenize(file, doc.attrs.items(.value_src)[a], v);
        _ = c.inlineStyle(r[0], r[1], n);
    }
    const k = cascade.run(arena, &doc, &c);
    var l = lower.init(arena, ds, &doc, &c, &k, std.fs.path.stem(path), path);
    l.checkDeclarations();
    l.run();
    const runtime = switch (frontend) {
        .runtime => true,
        .spec => false,
        .auto => l.page.runtime,
    };
    if (runtime) l.checkRuntime();
    if (explain) ds.note(.{ .file = file, .off = 0 }, "{s}", .{if (runtime) "runtime frontend: the page is a build(ui, frame) of Frame and widget calls" else "spec frontend: every construct on this page lowers to a comptime Spec"});
    if (ds.errors > 0) return null;
    var e: emit_zig.Emit = .{ .arena = arena, .ds = ds, .page = &l.page, .runtime = runtime };
    // The output is formatted as `zig fmt` would, so it reads like code written by hand.
    const raw = arena.dupeSentinel(u8, e.file(path), 0) catch @panic("out of memory");
    var tree = std.zig.Ast.parse(arena, raw, .{}) catch @panic("out of memory");
    if (tree.errors.len > 0) return raw; // a bug in the emitter: let the Zig compiler point at it
    return tree.renderAlloc(arena) catch @panic("out of memory");
}

/// Which lowering `--frontend` asks for; `auto` takes the page's `lcgf-frontend`, else spec.
pub const Frontend = enum { auto, spec, runtime };

fn dash(comptime f: []const u8) []const u8 {
    comptime {
        var out: [f.len]u8 = undefined;
        for (f, &out) |ch, *o| o.* = if (ch == '_') '-' else ch;
        const final = out;
        return &final;
    }
}
