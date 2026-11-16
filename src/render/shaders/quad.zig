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
