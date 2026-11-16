//! The quad shader and the vertex layout that matches `draw_list.Quad`. quad.wgsl is the single
//! source for every dumper and back end: every variant is quad.wgsl plus one material function,
//! assembled at comptime (`shader`). Data only, so tier 0 may import it; no GPU API here.
const std = @import("std");
const Quad = @import("../../draw/draw_list.zig").Quad;

/// The stock material (material.wgsl): fill or gradient times the bound texture, nine-slice uv.
pub const stock_material = @embedFile("material.wgsl");

/// The full quad shader around `material_fn`, a WGSL `fn material(in: Frag) -> vec4f`.
/// `in.params` carries `Style.params`; `in.local` is the pixel offset from the quad's centre and
/// `in.half` its half size, both in logical pixels. quad.wgsl's helpers (`gradient`, `nine_uv`,
/// `rounded_box`, `tex`, `samp`, `globals`) are in scope.
pub fn shader(comptime material_fn: []const u8) [:0]const u8 {
    return @embedFile("quad.wgsl") ++ material_fn;
}

/// The stock shader: `Style.material = .solid`.
pub const wgsl = shader(stock_material);

pub const Variant = struct { name: []const u8, wgsl: [:0]const u8 };

/// Every shader the framework ships; ci/jobs/shaders.sh validates each one on a real wgpu device.
pub const variants = [_]Variant{
    .{ .name = "stock", .wgsl = wgsl },
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
