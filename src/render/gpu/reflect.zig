//! WGSL reflection at compile time: the resource bindings (`@group(g) @binding(b) var ...`) and
//! entry points (`@vertex fn`, `@fragment fn`, `@compute @workgroup_size(...) fn`) of a shader,
//! read from its source by the Zig compiler. A projection builds its pipeline layout from this,
//! and `Group(g)` turns group g into a struct with one field per binding, so creating a bind
//! group with a missing, extra or mistyped resource does not compile.
//!
//! This reads declarations only; naga translates the shader (src/render/shaders/translate.sh,
//! build.zig `addShader`). It understands WGSL's module-scope `var` forms and the attribute
//! order WGSL allows; anything it does not recognise is a compile error naming the text.

const std = @import("std");

pub const Kind = enum {
    uniform,
    storage_read,
    storage_read_write,
    texture,
    storage_texture,
    sampler,
    comparison_sampler,

    pub fn isBuffer(k: Kind) bool {
        return k == .uniform or k == .storage_read or k == .storage_read_write;
    }
};

pub const SampleType = enum { float, sint, uint, depth };
pub const ViewDimension = enum { @"1d", @"2d", @"2d_array", cube, cube_array, @"3d" };
pub const Access = enum { read, write, read_write };

pub const Binding = struct {
    group: u32,
    binding: u32,
    name: []const u8,
    kind: Kind,
    /// Textures: what they sample as and their shape.
    sample_type: SampleType = .float,
    view_dimension: ViewDimension = .@"2d",
    multisampled: bool = false,
    /// Storage textures: the texel format as WGSL spells it, and the access.
    storage_format: []const u8 = "",
    access: Access = .read,
    /// Storage buffers whose last member is a runtime-sized array (Metal passes their sizes).
    runtime_sized: bool = false,
};

pub const Stage = enum { vertex, fragment, compute };

pub const EntryPoint = struct {
    stage: Stage,
    name: []const u8,
    workgroup_size: [3]u32 = .{ 1, 1, 1 },
};

pub const Module = struct {
    bindings: []const Binding,
    entry_points: []const EntryPoint,

    /// Number of groups: one past the highest group index used.
    pub fn groupCount(comptime m: Module) u32 {
        var n: u32 = 0;
        for (m.bindings) |b| n = @max(n, b.group + 1);
        return n;
    }

    /// The bindings of group `g`, ordered by binding index.
    pub fn group(comptime m: Module, comptime g: u32) []const Binding {
        comptime {
            var out: []const Binding = &.{};
            var next: u32 = 0;
            while (true) {
                var best: ?Binding = null;
                for (m.bindings) |b| if (b.group == g and b.binding >= next and (best == null or b.binding < best.?.binding)) {
                    best = b;
                };
                const found = best orelse break;
                out = out ++ [_]Binding{found};
                next = found.binding + 1;
            }
            return out;
        }
    }

    pub fn entryPoint(comptime m: Module, comptime name: []const u8) EntryPoint {
        // Unrolled, so a found entry point ends analysis before the error (a runtime loop would
        // reach the @compileError whatever it found).
        inline for (m.entry_points) |e| if (comptime std.mem.eql(u8, e.name, name)) return e;
        @compileError("the shader has no entry point `" ++ name ++ "`");
    }

    /// The struct a bind group of group `g` is created from: one field per binding, named as
    /// in WGSL, of type `Buffer` for uniform and storage buffers, `TextureView` for textures
    /// and storage textures, `Sampler` for samplers. The types are the projection's own.
    pub fn Group(comptime m: Module, comptime g: u32, comptime Buffer: type, comptime TextureView: type, comptime Sampler: type) type {
        const bindings = m.group(g);
        if (bindings.len == 0) @compileError(std.fmt.comptimePrint("the shader declares nothing in @group({d})", .{g}));
        var names: [bindings.len][]const u8 = undefined;
        var types: [bindings.len]type = undefined;
        for (bindings, &names, &types) |b, *n, *t| {
            n.* = b.name;
            t.* = switch (b.kind) {
                .uniform, .storage_read, .storage_read_write => Buffer,
                .texture, .storage_texture => TextureView,
                .sampler, .comparison_sampler => Sampler,
            };
        }
        return @Struct(.auto, null, &names, &types, &@splat(.{}));
    }
};

/// Reflects WGSL source `src` while compiling. A shader the reflection cannot read is a compile
/// error naming the text.
pub fn parse(comptime src: []const u8) Module {
    comptime {
        @setEvalBranchQuota(200 * src.len + 10_000);
        var text: [src.len]u8 = undefined;
        var bindings: [std.mem.count(u8, src, "var") + 1]Binding = undefined;
        var entries: [std.mem.count(u8, src, "fn") + 1]EntryPoint = undefined;
        var failure: Failure = .{};
        const m = parseInto(src, &text, &bindings, &entries, &failure) catch
            @compileError("WGSL reflection: " ++ failure.what ++ " at `" ++ failure.at ++ "`");
        // The names point into `text`, a comptime var: give each its own constant.
        var bs: [m.bindings.len]Binding = undefined;
        for (m.bindings, &bs) |b, *out| {
            out.* = b;
            const name = b.name[0..b.name.len].*;
            out.name = &name;
            const format = b.storage_format[0..b.storage_format.len].*;
            out.storage_format = &format;
        }
        var es: [m.entry_points.len]EntryPoint = undefined;
        for (m.entry_points, &es) |e, *out| {
            out.* = e;
            const name = e.name[0..e.name.len].*;
            out.name = &name;
        }
        const b = bs;
        const e = es;
        return .{ .bindings = &b, .entry_points = &e };
    }
}

/// Why `parseInto` refused a shader: what it expected, and the source from there on (40 bytes).
pub const Failure = struct { what: []const u8 = "", at: []const u8 = "" };

pub const Error = error{Wgsl};

/// Reflects `src` at run time or at comptime, into the caller's memory: `text` (src.len bytes,
/// the source without comments, which the names point into), `bindings` and `entries`. This is
/// the one reader: `parse` calls it while compiling, lcgf-gen (tools/lcgf-gen/) when it runs.
pub fn parseInto(src: []const u8, text: []u8, bindings: []Binding, entries: []EntryPoint, failure: *Failure) Error!Module {
    const stripped = stripComments(src, text);
    var nb: usize = 0;
    var ne: usize = 0;
    var p: Parser = .{ .s = stripped, .failure = failure };
    while (p.skipSpace()) {
        if (p.peek() != '@') {
            p.skipStatement();
            continue;
        }
        var attrs: Attrs = .{};
        while (p.skipSpace() and p.peek() == '@') try p.attribute(&attrs);
        if (p.keyword("var")) {
            if (attrs.group == null or attrs.binding == null) {
                p.skipStatement();
                continue;
            }
            if (nb == bindings.len) return p.fail("too many bindings");
            bindings[nb] = try p.variable(attrs.group.?, attrs.binding.?);
            nb += 1;
        } else if (p.keyword("fn")) {
            const name = try p.ident();
            if (attrs.stage) |stage| {
                if (ne == entries.len) return p.fail("too many entry points");
                entries[ne] = .{ .stage = stage, .name = name, .workgroup_size = attrs.workgroup_size };
                ne += 1;
            }
            try p.skipFunction();
        } else p.skipStatement();
    }
    for (bindings[0..nb], 0..) |a, i| for (bindings[i + 1 .. nb]) |b| {
        if (a.group == b.group and a.binding == b.binding) {
            failure.* = .{ .what = "a @group and @binding declared twice", .at = b.name };
            return error.Wgsl;
        }
    };
    return .{ .bindings = bindings[0..nb], .entry_points = entries[0..ne] };
}

/// The bindings of group `g` in `m`, ordered by binding index, into `out`: `Module.group` at run
/// time.
pub fn groupInto(m: Module, g: u32, out: []Binding) []Binding {
    var n: usize = 0;
    var next: u32 = 0;
    while (true) {
        var best: ?Binding = null;
        for (m.bindings) |b| if (b.group == g and b.binding >= next and (best == null or b.binding < best.?.binding)) {
            best = b;
        };
        const found = best orelse break;
        out[n] = found;
        n += 1;
        next = found.binding + 1;
    }
    return out[0..n];
}

const Attrs = struct {
    group: ?u32 = null,
    binding: ?u32 = null,
    stage: ?Stage = null,
    workgroup_size: [3]u32 = .{ 1, 1, 1 },
};

fn stripComments(src: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    var depth: u32 = 0;
    while (i < src.len) {
        if (depth == 0 and i + 1 < src.len and src[i] == '/' and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
        } else if (i + 1 < src.len and src[i] == '/' and src[i + 1] == '*') {
            depth += 1;
            i += 2;
        } else if (depth > 0 and i + 1 < src.len and src[i] == '*' and src[i + 1] == '/') {
            depth -= 1;
            i += 2;
            out[n] = ' ';
            n += 1;
        } else {
            if (depth == 0) {
                out[n] = src[i];
                n += 1;
            }
            i += 1;
        }
    }
    return out[0..n];
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    failure: *Failure,

    fn fail(p: *const Parser, what: []const u8) Error {
        p.failure.* = .{ .what = what, .at = p.s[@min(p.i, p.s.len)..@min(p.s.len, p.i + 40)] };
        return error.Wgsl;
    }

    fn peek(p: *const Parser) u8 {
        return p.s[p.i];
    }

    /// Skips whitespace; false at the end of the source.
    fn skipSpace(p: *Parser) bool {
        while (p.i < p.s.len and std.ascii.isWhitespace(p.s[p.i])) p.i += 1;
        return p.i < p.s.len;
    }

    fn isIdent(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_';
    }

    fn ident(p: *Parser) Error![]const u8 {
        _ = p.skipSpace();
        const start = p.i;
        while (p.i < p.s.len and isIdent(p.s[p.i])) p.i += 1;
        if (p.i == start) return p.fail("expected a name");
        return p.s[start..p.i];
    }

    /// Consumes `word` if it is the next token.
    fn keyword(p: *Parser, word: []const u8) bool {
        _ = p.skipSpace();
        if (!std.mem.startsWith(u8, p.s[p.i..], word)) return false;
        const after = p.i + word.len;
        if (after < p.s.len and isIdent(p.s[after])) return false;
        p.i = after;
        return true;
    }

    fn expect(p: *Parser, ch: u8) Error!void {
        _ = p.skipSpace();
        if (p.i >= p.s.len or p.s[p.i] != ch) return p.fail(switch (ch) {
            '(' => "expected `(`",
            ')' => "expected `)`",
            ':' => "expected `:`",
            '@' => "expected `@`",
            else => "expected a punctuation mark",
        });
        p.i += 1;
    }

    fn number(p: *Parser) Error!u32 {
        _ = p.skipSpace();
        const start = p.i;
        while (p.i < p.s.len and (std.ascii.isAlphanumeric(p.s[p.i]))) p.i += 1;
        var digits: []const u8 = p.s[start..p.i];
        if (std.mem.endsWith(u8, digits, "u") or std.mem.endsWith(u8, digits, "i")) digits = digits[0 .. digits.len - 1];
        return std.fmt.parseInt(u32, digits, 0) catch p.fail("expected an integer literal (reflection reads literals, not constants)");
    }

    /// The text up to the matching close of an already-consumed `open`.
    fn balanced(p: *Parser, open: u8, close: u8) Error![]const u8 {
        const start = p.i;
        var depth: u32 = 1;
        while (p.i < p.s.len) : (p.i += 1) {
            if (p.s[p.i] == open) depth += 1;
            if (p.s[p.i] == close) {
                depth -= 1;
                if (depth == 0) {
                    p.i += 1;
                    return p.s[start .. p.i - 1];
                }
            }
        }
        return p.fail("unbalanced brackets");
    }

    fn attribute(p: *Parser, a: *Attrs) Error!void {
        try p.expect('@');
        const name = try p.ident();
        if (std.mem.eql(u8, name, "group")) {
            try p.expect('(');
            a.group = try p.number();
            try p.expect(')');
        } else if (std.mem.eql(u8, name, "binding")) {
            try p.expect('(');
            a.binding = try p.number();
            try p.expect(')');
        } else if (std.mem.eql(u8, name, "vertex")) {
            a.stage = .vertex;
        } else if (std.mem.eql(u8, name, "fragment")) {
            a.stage = .fragment;
        } else if (std.mem.eql(u8, name, "compute")) {
            a.stage = .compute;
        } else if (std.mem.eql(u8, name, "workgroup_size")) {
            try p.expect('(');
            var k: usize = 0;
            while (k < 3) : (k += 1) {
                a.workgroup_size[k] = try p.number();
                _ = p.skipSpace();
                if (p.i < p.s.len and p.peek() == ',') {
                    p.i += 1;
                    _ = p.skipSpace();
                    if (p.i < p.s.len and p.peek() == ')') break;
                    continue;
                }
                break;
            }
            try p.expect(')');
        } else {
            _ = p.skipSpace();
            if (p.i < p.s.len and p.peek() == '(') {
                p.i += 1;
                _ = try p.balanced('(', ')');
            }
        }
    }

    /// `var<space, access> name: type;` or `var name: type;`, after the `var` keyword.
    fn variable(p: *Parser, group: u32, binding: u32) Error!Binding {
        var space: []const u8 = "";
        _ = p.skipSpace();
        if (p.i < p.s.len and p.peek() == '<') {
            p.i += 1;
            space = trim(try p.balanced('<', '>'));
        }
        const name = try p.ident();
        try p.expect(':');
        _ = p.skipSpace();
        const start = p.i;
        while (p.i < p.s.len and p.s[p.i] != ';') p.i += 1;
        const ty = trim(p.s[start..p.i]);
        p.i += 1;
        var b: Binding = .{ .group = group, .binding = binding, .name = name, .kind = .uniform };
        if (space.len > 0) {
            var parts = std.mem.splitScalar(u8, space, ',');
            const where = trim(parts.first());
            const access = trim(parts.rest());
            if (std.mem.eql(u8, where, "uniform")) {
                b.kind = .uniform;
            } else if (std.mem.eql(u8, where, "storage")) {
                b.kind = if (std.mem.eql(u8, access, "read_write")) .storage_read_write else .storage_read;
                b.runtime_sized = std.mem.startsWith(u8, ty, "array<") and std.mem.count(u8, ty, ",") == 0;
            } else return p.fail("unsupported address space");
            return b;
        }
        if (std.mem.eql(u8, ty, "sampler")) {
            b.kind = .sampler;
        } else if (std.mem.eql(u8, ty, "sampler_comparison")) {
            b.kind = .comparison_sampler;
        } else if (std.mem.startsWith(u8, ty, "texture_storage_")) {
            b.kind = .storage_texture;
            const open = std.mem.indexOfScalar(u8, ty, '<') orelse return p.fail("storage texture without a format");
            b.view_dimension = dimension(ty["texture_storage_".len..open]) orelse return p.fail("unknown storage texture shape");
            var args = std.mem.splitScalar(u8, ty[open + 1 .. ty.len - 1], ',');
            b.storage_format = trim(args.first());
            const acc = trim(args.rest());
            b.access = if (std.mem.eql(u8, acc, "read")) .read else if (std.mem.eql(u8, acc, "write")) .write else .read_write;
        } else if (std.mem.startsWith(u8, ty, "texture_depth_")) {
            b.kind = .texture;
            b.sample_type = .depth;
            const shape: []const u8 = ty["texture_depth_".len..];
            b.multisampled = std.mem.startsWith(u8, shape, "multisampled_");
            b.view_dimension = dimension(if (b.multisampled) shape["multisampled_".len..] else shape) orelse return p.fail("unknown depth texture shape");
        } else if (std.mem.startsWith(u8, ty, "texture_")) {
            b.kind = .texture;
            const open = std.mem.indexOfScalar(u8, ty, '<') orelse return p.fail("texture without a sample type");
            var shape: []const u8 = ty["texture_".len..open];
            b.multisampled = std.mem.startsWith(u8, shape, "multisampled_");
            if (b.multisampled) shape = shape["multisampled_".len..];
            b.view_dimension = dimension(shape) orelse return p.fail("unknown texture shape");
            const st = trim(ty[open + 1 .. ty.len - 1]);
            b.sample_type = if (std.mem.eql(u8, st, "f32")) .float else if (std.mem.eql(u8, st, "i32")) .sint else if (std.mem.eql(u8, st, "u32")) .uint else return p.fail("unknown texture sample type");
        } else return p.fail("a resource without an address space that is not a texture or sampler");
        return b;
    }

    fn skipStatement(p: *Parser) void {
        var depth: u32 = 0;
        while (p.i < p.s.len) : (p.i += 1) switch (p.s[p.i]) {
            '{', '(' => depth += 1,
            '}', ')' => {
                if (depth == 0) {
                    p.i += 1;
                    return;
                }
                depth -= 1;
                if (depth == 0 and p.s[p.i] == '}') {
                    p.i += 1;
                    // A struct or block ends the statement, optionally followed by `;`.
                    _ = p.skipSpace();
                    if (p.i < p.s.len and p.s[p.i] == ';') p.i += 1;
                    return;
                }
            },
            ';' => if (depth == 0) {
                p.i += 1;
                return;
            },
            else => {},
        };
    }

    fn skipFunction(p: *Parser) Error!void {
        while (p.i < p.s.len and p.s[p.i] != '{') p.i += 1;
        if (p.i == p.s.len) return p.fail("function without a body");
        p.i += 1;
        _ = try p.balanced('{', '}');
    }
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn dimension(s: []const u8) ?ViewDimension {
    const table = .{ .{ "1d", .@"1d" }, .{ "2d", .@"2d" }, .{ "2d_array", .@"2d_array" }, .{ "cube", .cube }, .{ "cube_array", .cube_array }, .{ "3d", .@"3d" } };
    inline for (table) |row| if (std.mem.eql(u8, s, row[0])) return row[1];
    return null;
}

const testing = std.testing;

const sample =
    \\// A comment with @group(9) @binding(9) var<uniform> ignored: f32;
    \\struct Params { tint: vec4f, scale: vec2f };
    \\@group(0) @binding(0) var<uniform> params: Params;
    \\@binding(1) @group(0) var tex: texture_2d<f32>;
    \\@group(0) @binding(2) var smp: sampler;
    \\/* block @group(7) @binding(7) var x: sampler; */
    \\@group(1) @binding(0) var<storage, read> data: array<vec4f>;
    \\@group(1) @binding(1) var<storage, read_write> out: array<u32, 4>;
    \\@group(2) @binding(0) var img: texture_storage_2d<rgba8unorm, write>;
    \\@group(2) @binding(1) var depth: texture_depth_2d;
    \\@group(2) @binding(2) var ms: texture_multisampled_2d<u32>;
    \\@group(2) @binding(3) var shadow: sampler_comparison;
    \\const k: u32 = 3u;
    \\struct V { @builtin(position) pos: vec4f, @location(0) uv: vec2f };
    \\@vertex fn vs(@builtin(vertex_index) i: u32, @location(0) at: vec2f) -> V { return V(vec4f(at, 0.0, 1.0), at); }
    \\@fragment
    \\fn fs(v: V) -> @location(0) vec4f { if (true) { return textureSample(tex, smp, v.uv); } return vec4f(); }
    \\@compute @workgroup_size(8, 4,) fn main(@builtin(global_invocation_id) id: vec3u) { out[0] = 1u; }
;

test "reflect: bindings, in any attribute order, with comments ignored" {
    const m = comptime parse(sample);
    try testing.expectEqual(9, m.bindings.len);
    try testing.expectEqual(3, comptime m.groupCount());
    const g0 = comptime m.group(0);
    try testing.expectEqualStrings("params", g0[0].name);
    try testing.expectEqual(Kind.uniform, g0[0].kind);
    try testing.expectEqualStrings("tex", g0[1].name);
    try testing.expectEqual(Kind.texture, g0[1].kind);
    try testing.expectEqual(ViewDimension.@"2d", g0[1].view_dimension);
    try testing.expectEqual(Kind.sampler, g0[2].kind);
    const g1 = comptime m.group(1);
    try testing.expectEqual(Kind.storage_read, g1[0].kind);
    try testing.expect(g1[0].runtime_sized);
    try testing.expectEqual(Kind.storage_read_write, g1[1].kind);
    try testing.expect(!g1[1].runtime_sized);
    const g2 = comptime m.group(2);
    try testing.expectEqual(Kind.storage_texture, g2[0].kind);
    try testing.expectEqualStrings("rgba8unorm", g2[0].storage_format);
    try testing.expectEqual(Access.write, g2[0].access);
    try testing.expectEqual(SampleType.depth, g2[1].sample_type);
    try testing.expect(g2[2].multisampled);
    try testing.expectEqual(SampleType.uint, g2[2].sample_type);
    try testing.expectEqual(Kind.comparison_sampler, g2[3].kind);
}

test "reflect: entry points and workgroup sizes" {
    const m = comptime parse(sample);
    try testing.expectEqual(3, m.entry_points.len);
    try testing.expectEqual(Stage.vertex, comptime m.entryPoint("vs").stage);
    try testing.expectEqual(Stage.fragment, comptime m.entryPoint("fs").stage);
    const cs = comptime m.entryPoint("main");
    try testing.expectEqual(Stage.compute, cs.stage);
    try testing.expectEqual([3]u32{ 8, 4, 1 }, cs.workgroup_size);
}

test "reflect: a group becomes a struct with one field per binding" {
    const m = comptime parse(sample);
    const B = struct { b: u8 };
    const T = struct { t: u16 };
    const S = struct { s: u32 };
    const G0 = m.Group(0, B, T, S);
    const fields = @typeInfo(G0).@"struct";
    try testing.expectEqual(3, fields.field_names.len);
    try testing.expectEqualStrings("params", fields.field_names[0]);
    try testing.expectEqual(B, fields.field_types[0]);
    try testing.expectEqual(T, fields.field_types[1]);
    try testing.expectEqual(S, fields.field_types[2]);
    const g: G0 = .{ .params = .{ .b = 1 }, .tex = .{ .t = 2 }, .smp = .{ .s = 3 } };
    try testing.expectEqual(@as(u16, 2), g.tex.t);
}

test "reflect: the same reader at run time" {
    var text: [sample.len]u8 = undefined;
    var bindings: [16]Binding = undefined;
    var entries: [4]EntryPoint = undefined;
    var failure: Failure = .{};
    const m = try parseInto(sample, &text, &bindings, &entries, &failure);
    const want = comptime parse(sample);
    try testing.expectEqual(want.bindings.len, m.bindings.len);
    for (want.bindings, m.bindings) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expectEqual(a.kind, b.kind);
        try testing.expectEqual(a.group, b.group);
        try testing.expectEqual(a.binding, b.binding);
    }
    var g: [8]Binding = undefined;
    try testing.expectEqual(4, groupInto(m, 2, &g).len);
    try testing.expectEqual(Stage.compute, m.entry_points[2].stage);
    try testing.expectEqual([3]u32{ 8, 4, 1 }, m.entry_points[2].workgroup_size);
    try testing.expectError(error.Wgsl, parseInto("@group(0) @binding(0) var x: banana;", &text, &bindings, &entries, &failure));
    try testing.expectEqualStrings("a resource without an address space that is not a texture or sampler", failure.what);
}

test "reflect: the conformance gradient" {
    const m = comptime parse(@embedFile("gradient.wgsl"));
    try testing.expectEqual(1, m.bindings.len);
    try testing.expectEqualStrings("screen", m.bindings[0].name);
    try testing.expectEqual(2, m.entry_points.len);
}
