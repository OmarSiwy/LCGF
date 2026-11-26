//! lcgf-gen's HTML front end: one page and its stylesheets in, one Zig module out.
//!
//!   lcgf-gen page.html [--css extra.css]... --lang zig -o OUT [--depfile OUT.d]
//!            [--check VENDORED] [--explain] [--no-warnings]
//!   lcgf-gen page.html --lang zon|cpp|rust|words ...   (the page in the seam's subset, to_zon.zig)
//!   lcgf-gen --mappings        (the manifest as TSV)
//!
//! On any error nothing is written: the messages go to stderr in GNU format and the exit code
//! is 1. Output is deterministic: no timestamps, a fixed number format.

const std = @import("std");
const lcgf = @import("lcgf");
const diag = @import("diag.zig");
const ir = @import("ir.zig");
const html = @import("html.zig");
const css = @import("css.zig");
const cascade = @import("cascade.zig");
const lower = @import("lower.zig");
const manifest = @import("manifest.zig");
const emit_zig = @import("emit_zig.zig");
const to_zon = @import("to_zon.zig");

/// lcgf-gen's table emitters (tools/lcgf-gen/main.zig): `.zon` text in, the `lang` output out,
/// or null after logging the error.
pub const Tables = *const fn (arena: std.mem.Allocator, lang: []const u8, zon: [:0]const u8, path: []const u8) ?[]const u8;

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
    /// `--runtime-vars=t-`: custom properties `--t-*` are run-time theme tokens.
    runtime_vars: []const u8 = "",
};

/// Whether `args` asks for this front end: an `.html` input or `--mappings`.
pub fn wants(args: []const []const u8) bool {
    for (args) |a| if (std.mem.endsWith(u8, a, ".html") or std.mem.eql(u8, a, "--mappings")) return true;
    return false;
}

pub fn main(io: std.Io, arena: std.mem.Allocator, args: []const []const u8, tables: Tables) !u8 {
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
            o.frontend = std.meta.stringToEnum(Frontend, f) orelse .zon;
            if (o.frontend == .zon) {
                std.log.err("--frontend {s}: the Zig emitter has the spec and runtime frontends (--lang cpp|rust take the seam's tables)", .{f});
                return 2;
            }
        } else if (std.mem.startsWith(u8, a, "--runtime-vars=")) {
            o.runtime_vars = a["--runtime-vars=".len..];
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
    const zig = std.mem.eql(u8, o.lang, "zig");
    if (!zig and std.meta.stringToEnum(enum { zon, cpp, rust, words }, o.lang) == null) return usage();
    const path = o.html orelse return usage();
    var ds: diag.Diags = .{ .arena = arena, .warnings = o.warnings };
    var deps: std.ArrayList([]const u8) = .empty;
    const result = compile(io, arena, &ds, &deps, path, o.css.items, o.explain, if (zig) o.frontend else .zon, o.runtime_vars);
    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
    try ds.render(&stderr.interface);
    try stderr.interface.flush();
    var text = result orelse return 1;
    // C++, Rust and the raw words: the ZON through the table emitters, as a `.zon` input is.
    if (!zig and !std.mem.eql(u8, o.lang, "zon")) text = tables(arena, o.lang, try arena.dupeSentinel(u8, text, 0), path) orelse return 1;
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
    std.log.err("usage: lcgf-gen page.html [--css extra.css]... --lang zig|zon|cpp|rust|words -o OUT [--depfile OUT.d] [--check VENDORED]  |  lcgf-gen --mappings", .{});
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
pub fn compile(io: std.Io, arena: std.mem.Allocator, ds: *diag.Diags, deps: *std.ArrayList([]const u8), path: []const u8, extra_css: []const []const u8, explain: bool, frontend: Frontend, runtime_vars: []const u8) ?[]const u8 {
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
    l.runtime_prefix = runtime_vars;
    l.checkDeclarations();
    l.run();
    // Font files are vendored: each must exist, and editing one reruns the tool.
    for (l.page.fonts.items, l.page.font_locs.items) |f, at| {
        const p = std.fs.path.join(arena, &.{ loader.dir, f.path }) catch @panic("out of memory");
        std.Io.Dir.cwd().access(io, p, .{}) catch |e| {
            ds.err(at, "cannot read the font file {s}: {s}", .{ p, @errorName(e) });
            continue;
        };
        deps.append(arena, p) catch @panic("out of memory");
    }
    const runtime = switch (frontend) {
        .runtime => true,
        .spec, .zon => false,
        .auto => l.page.runtime,
    };
    if (runtime) l.checkRuntime();
    l.checkTokens();
    loadAssets(io, arena, ds, deps, &l.page);
    if (explain) ds.note(.{ .file = file, .off = 0 }, "{s}", .{if (runtime) "runtime frontend: the page is a build(ui, frame) of Frame and widget calls" else "spec frontend: every construct on this page lowers to a comptime Spec"});
    if (ds.errors > 0) return null;
    if (frontend == .zon) return to_zon.text(arena, to_zon.lower(arena, ds, &l.page) orelse return null);
    var e: emit_zig.Emit = .{ .arena = arena, .ds = ds, .page = &l.page, .runtime = runtime };
    // The output is formatted as `zig fmt` would, so it reads like code written by hand.
    const raw = arena.dupeSentinel(u8, e.file(path), 0) catch @panic("out of memory");
    var tree = std.zig.Ast.parse(arena, raw, .{}) catch @panic("out of memory");
    if (tree.errors.len > 0) return raw; // a bug in the emitter: let the Zig compiler point at it
    return tree.renderAlloc(arena) catch @panic("out of memory");
}

/// Reads and decodes each image the page draws (`ir.Asset`), each a dependency of the output.
/// Pixels are embedded in the generated module, so one image is at most 512 x 512.
fn loadAssets(io: std.Io, arena: std.mem.Allocator, ds: *diag.Diags, deps: *std.ArrayList([]const u8), page: *ir.Page) void {
    const png = lcgf.png;
    for (page.assets.items) |*a| {
        if (a.path.len == 0) continue; // a gradient's ramp, made while lowering
        deps.append(arena, a.path) catch @panic("out of memory");
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, a.path, arena, .limited(16 << 20)) catch |e| {
            ds.err(a.loc, "cannot read {s}: {s}", .{ a.path, @errorName(e) });
            continue;
        };
        if (std.ascii.endsWithIgnoreCase(a.path, ".svg")) {
            rasterSvg(arena, ds, a, bytes);
            continue;
        }
        const i = png.info(bytes) catch |e| {
            ds.err(a.loc, "{s} is not a decodable PNG: {s}", .{ a.src, @errorName(e) });
            continue;
        };
        if (@as(u64, i.w) * i.h > 512 * 512) {
            ds.err(a.loc, "{s} is {d} x {d}; an embedded image is at most 512 x 512 pixels: decode a larger one at run time (lcgf.png.decode)", .{ a.src, i.w, i.h });
            continue;
        }
        const pixels = arena.alloc(u8, i.pixelBytes()) catch @panic("out of memory");
        const scratch = arena.alloc(u8, i.scratchBytes()) catch @panic("out of memory");
        _ = png.decode(bytes, pixels, scratch) catch |e| {
            ds.err(a.loc, "{s} is not a decodable PNG: {s}", .{ a.src, @errorName(e) });
            continue;
        };
        a.* = .{ .src = a.src, .path = a.path, .loc = a.loc, .w = i.w, .h = i.h, .pixels = pixels };
    }
}

/// Draws SVG asset `a` (`bytes`) with draw/svg.zig at its raster size, or its own size from
/// its root's width and height (else its viewBox), into premultiplied RGBA8 rows.
fn rasterSvg(arena: std.mem.Allocator, ds: *diag.Diags, a: *ir.Asset, bytes: []const u8) void {
    const svg = lcgf.svg;
    const own = svgSize(bytes) orelse {
        ds.err(a.loc, "{s}: its <svg> needs a width and height, or a viewBox", .{a.src});
        return;
    };
    var size = a.raster;
    if (size[0] == 0 and size[1] == 0) size = own;
    if (size[0] == 0) size[0] = size[1] * own[0] / own[1];
    if (size[1] == 0) size[1] = size[0] * own[1] / own[0];
    const w: u32 = @intFromFloat(@ceil(size[0]));
    const h: u32 = @intFromFloat(@ceil(size[1]));
    if (w == 0 or h == 0 or @as(u64, w) * h > 512 * 512) {
        ds.err(a.loc, "{s} draws at {d} x {d}; an embedded image is 1 to 512 x 512 pixels", .{ a.src, w, h });
        return;
    }
    const oom = "out of memory";
    const Big = lcgf.paths.TestBuffers(4096, 65536);
    const bufs = arena.alloc(Big, 3) catch @panic(oom);
    var p = bufs[0].path();
    var center = bufs[0].polyline();
    var work = bufs[1].polyline();
    var outline = bufs[2].polyline();
    const n = lcgf.surface.requiredPixels(w, h) catch unreachable;
    var layers: [4]lcgf.surface.Surface = undefined;
    for (&layers) |*layer| layer.* = lcgf.surface.init(arena.alloc(u32, n) catch @panic(oom), w, h) catch unreachable;
    const dst = lcgf.surface.init(arena.alloc(u32, n) catch @panic(oom), w, h) catch unreachable;
    const cells = n + 64;
    svg.paint(bytes, dst, .{ .viewport = .{ .x1 = size[0], .y1 = size[1] } }, .{
        .path = &p,
        .centerline = &center,
        .work = &work,
        .outline = &outline,
        .fill = bufs[2].scratch(),
        .accumulator = arena.alloc(f32, cells) catch @panic(oom),
        .coverage = arena.alloc(u8, cells) catch @panic(oom),
        .gradients = arena.alloc(svg.Gradient, 64) catch @panic(oom),
        .stops = arena.alloc(lcgf.brushes.Stop, 256) catch @panic(oom),
        .segments = arena.alloc(lcgf.brushes.Segment, 256) catch @panic(oom),
        .stack = arena.alloc(svg.Frame, 64) catch @panic(oom),
        .layers = &layers,
        .dashes = arena.alloc(f32, 64) catch @panic(oom),
        .clips = arena.alloc(lcgf.decoration.Clip, 4) catch @panic(oom),
    }) catch |e| {
        ds.err(a.loc, "{s} is not an SVG this build draws: {s}", .{ a.src, @errorName(e) });
        return;
    };
    const pixels = arena.alloc(u32, @as(usize, w) * h) catch @panic(oom);
    for (0..h) |y| @memcpy(pixels[y * w ..][0..w], dst.pixels[y * dst.stride ..][0..w]);
    a.w = w;
    a.h = h;
    a.pixels = std.mem.sliceAsBytes(pixels);
}

/// The size an SVG gives itself: its root's width and height in px, else its viewBox's.
fn svgSize(bytes: []const u8) ?[2]f32 {
    const start = std.mem.indexOf(u8, bytes, "<svg") orelse return null;
    const end = std.mem.indexOfScalarPos(u8, bytes, start, '>') orelse return null;
    const tag = bytes[start..end];
    const value = struct {
        fn of(t: []const u8, comptime name: []const u8) ?[]const u8 {
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, t, at, " " ++ name ++ "=")) |i| : (at = i + 1) {
                const q = i + name.len + 2;
                if (q >= t.len) return null;
                const close = std.mem.indexOfScalarPos(u8, t, q + 1, t[q]) orelse return null;
                return t[q + 1 .. close];
            }
            return null;
        }
        fn px(v: []const u8) ?f32 {
            const num = std.mem.trimEnd(u8, std.mem.trim(u8, v, " "), "px");
            return std.fmt.parseFloat(f32, num) catch null;
        }
    };
    if (value.of(tag, "width")) |wv| if (value.of(tag, "height")) |hv| {
        if (value.px(wv)) |w| if (value.px(hv)) |h| if (w > 0 and h > 0) return .{ w, h };
    };
    const vb = value.of(tag, "viewBox") orelse return null;
    var it = std.mem.tokenizeAny(u8, vb, " ,");
    var f: [4]f32 = undefined;
    for (&f) |*x| x.* = std.fmt.parseFloat(f32, it.next() orelse return null) catch return null;
    if (f[2] <= 0 or f[3] <= 0) return null;
    return .{ f[2], f[3] };
}

/// Which lowering `--frontend` asks for; `auto` takes the page's `lcgf-frontend`, else spec.
/// `zon` is the seam's spec language (`--lang zon|cpp|rust|words`).
pub const Frontend = enum { auto, spec, runtime, zon };

fn dash(comptime f: []const u8) []const u8 {
    comptime {
        var out: [f.len]u8 = undefined;
        for (f, &out) |ch, *o| o.* = if (ch == '_') '-' else ch;
        const final = out;
        return &final;
    }
}
