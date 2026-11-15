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

/// One text node's run, for the renderer's text pass.
pub const TextRun = extern struct {
    /// Content box of the text node.
    rect: [4]f32,
    clip: [4]f32,
    /// Byte range in `DrawList.strings`.
    start: u32,
    bytes: u32,
    px: f32,
    color: u32,
    font: u32,
};

/// A rectangle handed back to the host, which draws it with its own pipeline.
pub const CustomDraw = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    /// Whatever the caller passed to `Frame.custom`.
    data: u64,
    id: u32,
    node: u32,
};

const testing = std.testing;

test "layout: Quad is the 80-byte instance row the quad pipeline declares" {
    // Renderers declare vertex attributes at these offsets (prototype/ui_wgpu.zig quad_attrs).
    try testing.expectEqual(80, @sizeOf(Quad));
    try testing.expectEqual(4, @alignOf(Quad));
    inline for (.{ "rect", "clip", "params", "uv", "fill", "border_color", "radius", "border" }, .{ 0, 16, 32, 48, 64, 68, 72, 76 }) |name, off|
        try testing.expectEqual(off, @offsetOf(Quad, name));
}

test "layout: TextRun and CustomDraw rows" {
    try testing.expectEqual(52, @sizeOf(TextRun));
    try testing.expectEqual(4, @alignOf(TextRun));
    inline for (.{ "rect", "clip", "start", "bytes", "px", "color", "font" }, .{ 0, 16, 32, 36, 40, 44, 48 }) |name, off|
        try testing.expectEqual(off, @offsetOf(TextRun, name));
    try testing.expectEqual(48, @sizeOf(CustomDraw));
    try testing.expectEqual(8, @alignOf(CustomDraw));
    inline for (.{ "rect", "clip", "data", "id", "node" }, .{ 0, 16, 32, 40, 44 }) |name, off|
        try testing.expectEqual(off, @offsetOf(CustomDraw, name));
}
