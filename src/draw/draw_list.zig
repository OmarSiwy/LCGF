//! Draw list: what a renderer consumes. Flat arrays and u32 indices only; every row type that
//! crosses to the GPU is `extern` with `[4]f32` fields, because `@Vector` is not allowed in an
//! extern struct (docs/ZIG_0_17_1.md). Tier 0. Ported from prototype/ui.zig ("Draw list").

const std = @import("std");

/// One instance of the quad pipeline. This is the GPU vertex-buffer layout,
/// so the whole array uploads with a single copy.
pub const Quad = extern struct {
    /// x0, y0, x1, y1 in logical pixels.
    rect: [4]f32,
    /// Clipping is per instance, so a clip change never splits a batch.
    clip: [4]f32,
    /// Material uniforms.
    params: [4]f32,
    /// u0, v0, u1, v1.
    uv: [4]f32,
    fill: u32,
    border_color: u32,
    radius: f32,
    border: f32,
};

const testing = std.testing;

test "layout: Quad is the 80-byte instance row the quad pipeline declares" {
    // Renderers declare vertex attributes at these offsets (prototype/ui_wgpu.zig quad_attrs).
    try testing.expectEqual(80, @sizeOf(Quad));
    try testing.expectEqual(4, @alignOf(Quad));
    inline for (.{ "rect", "clip", "params", "uv", "fill", "border_color", "radius", "border" }, .{ 0, 16, 32, 48, 64, 68, 72, 76 }) |name, off|
        try testing.expectEqual(off, @offsetOf(Quad, name));
}
