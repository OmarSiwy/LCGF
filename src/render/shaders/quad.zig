//! The quad shader and the vertex layout that matches `draw_list.Quad`. quad.wgsl is the single
//! source for every dumper and back end: every variant is quad.wgsl plus one material function,
//! assembled at comptime (`shader`). Data only, so tier 0 may import it; no GPU API here.
const std = @import("std");
const Quad = @import("../../draw/draw_list.zig").Quad;
const Material = @import("../../core/types.zig").Material;

/// The stock material (material.wgsl): fill or gradient times the bound texture, nine-slice uv.
pub const stock_material = @embedFile("material.wgsl");

/// The full quad shader around `material_fn`, a WGSL `fn material(in: Frag) -> vec4f`.
/// `in.params` carries `Style.params`; `in.local` is the pixel offset from the quad's centre and
/// `in.half` its half size, both in logical pixels. quad.wgsl's helpers (`gradient`, `nine_uv`,
/// `nearest_uv`, `rounded_box`, `tex`, `samp`, `globals`) are in scope.
pub fn shader(comptime material_fn: []const u8) [:0]const u8 {
    return @embedFile("quad.wgsl") ++ material_fn;
}

/// The stock shader: `Style.material = .solid`.
pub const wgsl = shader(stock_material);

const Usage = @import("../../draw/features.zig").Usage;
const stock_source = @embedFile("quad.wgsl");

// Reuse whole module-scope functions from the stock WGSL; their closing braces are unindented.
fn function(comptime name: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, stock_source, "fn " ++ name ++ "(").?;
    const end = std.mem.indexOfPos(u8, stock_source, start, "\n}").? + 2;
    return stock_source[start..end] ++ "\n";
}

/// The stock shader with only the helpers needed by this UI. A text run samples an atlas
/// even when none of the UI's other quads use images. The instance and bind layouts are shared.
pub fn stockFor(comptime use: Usage) [:0]const u8 {
    return comptime result: {
        if (std.meta.eql(use, Usage.all)) break :result wgsl;
        @setEvalBranchQuota(500000);
        const tex = use.image or use.text;
        const grad = use.kinds.contains(.linear) or use.kinds.contains(.radial);
        const nine = tex and use.kinds.contains(.nine_slice);
        const pattern = use.border and (use.kinds.contains(.dashed) or use.kinds.contains(.dotted));
        const shadow = use.kinds.contains(.shadow);
        const head = stock_source[0..std.mem.indexOf(u8, stock_source, "@vertex").?];
        const vs = function("vs");
        const grow = "select(0.0, 3.0 * bitcast<f32>(inst.params.y), inst.params.x == k_shadow)";
        const vertex = if (shadow) vs else blk: {
            const at = std.mem.indexOf(u8, vs, grow).?;
            break :blk vs[0..at] ++ "0.0" ++ vs[at + grow.len ..];
        };
        const constants = stock_source[std.mem.indexOf(u8, stock_source, "const k_linear").?..std.mem.indexOf(u8, stock_source, "// Gradients:").?];
        const helpers = function("rounded_box") ++
            (if (use.radius) function("corner_radius") else "") ++
            (if (tex or pattern) function("rect_pos") ++ function("floor_div") else "") ++
            (if (tex) function("texel_centre") ++ function("nearest_uv") else "") ++
            (if (grad) function("gradient") else "") ++
            (if (nine) function("nine_axis") ++ function("nine_uv") else "") ++
            (if (pattern) function("border_pattern") else "") ++
            (if (shadow) function("shadow_coverage") else "");
        // As in the stock shader: per-instance branches, the texture sampled after them.
        const mat = (if (nine) "var uv = nearest_uv(in);\nif (in.params.x == k_nine) {\nuv = nine_uv(in);\n}\n" else "") ++
            (if (grad) "var fill = in.fill;\nif (in.params.x == k_linear || in.params.x == k_radial) {\nfill = gradient(in);\n}\n" else "let fill = in.fill;\n") ++
            "let material = fill" ++
            (if (nine) " * textureSample(tex, samp, uv)" else if (tex) " * textureSample(tex, samp, nearest_uv(in))" else "") ++ ";\n";
        break :result head ++ constants ++ "@vertex\n" ++ vertex ++ helpers ++
            "@fragment fn fs(in: Frag) -> @location(0) vec4f {\n" ++
            "let r = " ++ (if (use.radius) "corner_radius(in.local, in.half, in.radii)" else "0.0") ++ ";\n" ++
            "let d = rounded_box(in.local, in.half, r) * globals.scale;\n" ++
            "let shape = clamp(0.5 - d, 0.0, 1.0);\n" ++
            mat ++
            (if (use.border)
                "let inner = clamp(0.5 - (d + in.border * globals.scale), 0.0, 1.0);\n" ++
                    (if (pattern) "var pattern = 1.0;\nif (in.params.x == k_dashed || in.params.x == k_dotted) {\npattern = border_pattern(in);\n}\n" else "") ++
                    "let edge = (1.0 - mix(1.0, inner, step(0.001, in.border)))" ++
                    (if (pattern) " * pattern" else "") ++ ";\nlet painted = mix(material, in.border_color, edge);\n"
            else
                "let painted = material;\n") ++
            (if (shadow)
                "let shadow = in.params.x == k_shadow;\nlet color = select(painted, in.fill, shadow);\n" ++
                    "var cover = shape;\nif (shadow) {\ncover = shadow_coverage(d / globals.scale, bitcast<f32>(in.params.y));\n}\n"
            else
                "let color = painted;\nlet cover = shape;\n") ++
            "let inside = step(in.clip.xy, in.pixel) * step(in.pixel, in.clip.zw);\n" ++
            (if (use.radius)
                "var rounded = 1.0;\nif (any(in.clip_radii > vec4f(0.0))) {\n" ++
                    "let delta = in.pixel - (in.clip.xy + in.clip.zw) * 0.5;\nlet half = (in.clip.zw - in.clip.xy) * 0.5;\n" ++
                    "let clip_d = rounded_box(delta, half, corner_radius(delta, half, in.clip_radii)) * globals.scale;\n" ++
                    "rounded = clamp(0.5 - clip_d, 0.0, 1.0);\n}\n"
            else
                "let rounded = 1.0;\n") ++
            "let alpha = cover * inside.x * inside.y * rounded * in.opacity;\nreturn vec4f(color.rgb * color.a, color.a) * alpha;\n}\n";
    };
}

/// An example user material (example_material.wgsl): diagonal stripes.
pub const example_material = @embedFile("example_material.wgsl");

pub const max_materials = 16;

/// The material table a back end builds its quad pipelines from: entry i is the shader of
/// `Material` i, and entry 0 is the stock shader (`Material.solid`). Ported from
/// prototype/ui_wgpu.zig `addMaterial`; this keeps the sources, the back end owns the pipelines.
pub const Materials = struct {
    wgsl: [max_materials][:0]const u8 = @splat(wgsl),
    len: u16 = 1,

    /// A material with your fragment logic; build `material_wgsl` with `shader`. Past `max_materials`
    /// the last entry is replaced, as the prototype does, rather than writing out of bounds.
    pub fn add(self: *Materials, material_wgsl: [:0]const u8) Material {
        // u16: @min with a comptime bound narrows to u4, and i + 1 would overflow at the cap.
        const i: u16 = @min(self.len, max_materials - 1);
        self.wgsl[i] = material_wgsl;
        self.len = i + 1;
        return @fromBackingInt(i);
    }

    /// The shader of `m`. A stale handle is clamped to the last entry instead of indexing out of
    /// bounds, as the prototype's `bind` does.
    pub fn source(self: *const Materials, m: Material) [:0]const u8 {
        return self.wgsl[@min(@backingInt(m), self.len - 1)];
    }
};

pub const Variant = struct { name: []const u8, wgsl: [:0]const u8 };

/// Every shader the framework ships; ci/jobs/shaders.sh validates each one on a real wgpu device.
pub const variants = [_]Variant{
    .{ .name = "stock", .wgsl = wgsl },
    .{ .name = "example", .wgsl = shader(example_material) },
    // The theme lane's example material (src/theme/sheen.wgsl), embedded by path so render code
    // does not import the theme module.
    .{ .name = "sheen", .wgsl = shader(@embedFile("../../theme/sheen.wgsl")) },
};

pub const Attr = struct { location: u32, offset: u32, format: []const u8 };

/// Instance attributes of `Quad` for `wgsl`. `xform` is split: a, b, c, d then tx, ty.
pub const attrs = [_]Attr{
    .{ .location = 0, .offset = @offsetOf(Quad, "rect"), .format = "float32x4" },
    .{ .location = 1, .offset = @offsetOf(Quad, "clip"), .format = "float32x4" },
    .{ .location = 2, .offset = @offsetOf(Quad, "params"), .format = "uint32x4" },
    .{ .location = 3, .offset = @offsetOf(Quad, "uv"), .format = "float32x4" },
    .{ .location = 4, .offset = @offsetOf(Quad, "fill"), .format = "unorm8x4" },
    .{ .location = 5, .offset = @offsetOf(Quad, "border_color"), .format = "unorm8x4" },
    .{ .location = 6, .offset = @offsetOf(Quad, "radii"), .format = "float32x4" },
    .{ .location = 7, .offset = @offsetOf(Quad, "border"), .format = "float32" },
    .{ .location = 8, .offset = @offsetOf(Quad, "opacity"), .format = "float32" },
    .{ .location = 9, .offset = @offsetOf(Quad, "xform"), .format = "float32x4" },
    .{ .location = 10, .offset = @offsetOf(Quad, "xform") + 16, .format = "float32x2" },
    .{ .location = 11, .offset = @offsetOf(Quad, "clip_radii"), .format = "float32x4" },
};

pub const stride = @sizeOf(Quad);

test "attrs cover every byte of Quad once" {
    var seen: [stride]bool = @splat(false);
    for (attrs) |a| {
        const len: u32 = if (std.mem.endsWith(u8, a.format, "x4") and !std.mem.startsWith(u8, a.format, "unorm8")) 16 else if (std.mem.endsWith(u8, a.format, "x2")) 8 else 4;
        for (a.offset..a.offset + len) |i| {
            try std.testing.expect(!seen[i]);
            seen[i] = true;
        }
    }
    for (seen) |s| try std.testing.expect(s);
}

test "shader source is assembled at comptime" {
    try std.testing.expectEqual(1, std.mem.count(u8, wgsl, "fn material(in: Frag)"));
    try std.testing.expect(std.mem.endsWith(u8, wgsl, stock_material));
    const user = comptime shader("fn material(in: Frag) -> vec4f { return in.fill; }\n");
    try std.testing.expectEqual(1, std.mem.count(u8, user, "fn material(in: Frag)"));
    try std.testing.expect(std.mem.startsWith(u8, user, @embedFile("quad.wgsl")));
}

test "Materials: solid is the stock shader, add hands out indices in order and clamps" {
    var m: Materials = .{};
    try std.testing.expectEqualStrings(wgsl, m.source(.solid));
    const stripes = comptime shader(example_material);
    const a = m.add(stripes);
    try std.testing.expectEqual(@as(u16, 1), @backingInt(a));
    try std.testing.expectEqualStrings(stripes, m.source(a));
    // A stale handle draws with the last valid entry.
    try std.testing.expectEqualStrings(stripes, m.source(@fromBackingInt(9)));
    for (2..max_materials + 3) |_| _ = m.add(wgsl);
    try std.testing.expectEqual(max_materials, m.len);
    try std.testing.expectEqual(@as(u16, max_materials - 1), @backingInt(m.add(stripes)));
    try std.testing.expectEqualStrings(stripes, m.source(@fromBackingInt(0xffff)));
}

test "every variant has one material, one vs and one fs entry point" {
    for (variants) |v| {
        try std.testing.expectEqual(1, std.mem.count(u8, v.wgsl, "fn material(in: Frag) -> vec4f"));
        try std.testing.expectEqual(1, std.mem.count(u8, v.wgsl, "@vertex\nfn vs("));
        try std.testing.expectEqual(1, std.mem.count(u8, v.wgsl, "@fragment\nfn fs("));
    }
}

test "the WGSL Instance struct matches attrs location for location" {
    const src = @embedFile("quad.wgsl");
    const start = std.mem.indexOf(u8, src, "struct Instance {").?;
    const body = src[start..][0..std.mem.indexOfScalar(u8, src[start..], '}').?];
    var lines = std.mem.tokenizeScalar(u8, body, '\n');
    _ = lines.next();
    var n: u32 = 0;
    while (lines.next()) |line| : (n += 1) {
        // "    @location(N) name: type,"
        const t = std.mem.trim(u8, line, " ,");
        const close = std.mem.indexOfScalar(u8, t, ')').?;
        const location = try std.fmt.parseInt(u32, t["@location(".len..close], 10);
        const wgsl_type = t[std.mem.indexOf(u8, t, ": ").? + 2 ..];
        const a = attrs[n];
        try std.testing.expectEqual(a.location, location);
        // The vertex format each WGSL input type accepts.
        const ok = if (std.mem.eql(u8, wgsl_type, "vec4f"))
            std.mem.eql(u8, a.format, "float32x4") or std.mem.eql(u8, a.format, "unorm8x4")
        else if (std.mem.eql(u8, wgsl_type, "vec4u"))
            std.mem.eql(u8, a.format, "uint32x4")
        else if (std.mem.eql(u8, wgsl_type, "vec2f"))
            std.mem.eql(u8, a.format, "float32x2")
        else
            std.mem.eql(u8, wgsl_type, "f32") and std.mem.eql(u8, a.format, "float32");
        try std.testing.expect(ok);
    }
    try std.testing.expectEqual(attrs.len, n);
}

test "the WGSL feature codes match features.Kind" {
    const Kind = @import("../../draw/features.zig").Kind;
    const src = @embedFile("quad.wgsl");
    inline for (.{ "k_linear", "k_radial", "k_shadow", "k_nine", "k_dashed", "k_dotted" }, .{ Kind.linear, Kind.radial, Kind.shadow, Kind.nine_slice, Kind.dashed, Kind.dotted }) |name, kind| {
        var buf: [64]u8 = undefined;
        const decl = try std.fmt.bufPrint(&buf, "const {s} = {d}u;", .{ name, @backingInt(kind) });
        try std.testing.expectEqual(1, std.mem.count(u8, src, decl));
    }
}

test "stockFor preserves the full shader and removes unused material helpers" {
    try std.testing.expectEqualStrings(wgsl, stockFor(.all));
    const plain = stockFor(.{});
    const text = stockFor(.{ .text = true });
    try std.testing.expect(plain.len < wgsl.len);
    for ([_][]const u8{ "fn gradient(", "fn corner_radius(", "fn nine_uv(", "textureSample(", "fn border_pattern(" }) |disabled|
        try std.testing.expect(std.mem.indexOf(u8, plain, disabled) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "textureSample(") != null);
}
