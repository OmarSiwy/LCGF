//! Inline custom draws on Metal. The renderer's `Pass` is the host's own render command encoder
//! (`mtl.RenderEncoder.id`), so at a custom command the host records anything into it with its
//! own pipeline, then the loop continues; the next UI draw rebinds every piece of state
//! (iface.zig, "Full state rebinding").
//!
//!     var i = iface.drawUntilCustom(&gfx, pass, draw, 0);
//!     while (i < draw.cmd_len) : (i = iface.drawUntilCustom(&gfx, pass, draw, i + 1))
//!         gradient.draw(pass, gfx.customScissor(draw.customs[draw.command(i).custom]), gfx.extent);
//!
//! `Gradient` is that host draw as an application would write it: the goldens' host pipeline
//! (src/render/conformance/render.py `scene_pipe`), a gradient over the target scissored to the
//! custom rect, with no blending and its own fragment bytes.

const std = @import("std");
const builtin = @import("builtin");
const lcgr = @import("lcgr");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const pipeline = @import("pipeline.zig");
const Id = objc.Id;
const U = objc.NSUInteger;

/// `custom.rect` cut by `custom.clip`, in the physical pixels of a target of `extent` at
/// `scale`, rows from the top (Metal's own scissor space) and inside the target, as Metal
/// requires. Pixels the rect covers partly are included; an empty result has zero size. The
/// same rect as the Vulkan and GL ES back ends' `customScissor`.
pub fn scissor(extent: [2]u32, scale: f32, custom: lcgr.draw_list.CustomDraw) mtl.ScissorRect {
    const w: f32 = @floatFromInt(extent[0]);
    const h: f32 = @floatFromInt(extent[1]);
    const x0 = std.math.clamp(@floor(@max(custom.rect[0], custom.clip[0]) * scale), 0, w);
    const y0 = std.math.clamp(@floor(@max(custom.rect[1], custom.clip[1]) * scale), 0, h);
    const x1 = std.math.clamp(@ceil(@min(custom.rect[2], custom.clip[2]) * scale), x0, w);
    const y1 = std.math.clamp(@ceil(@min(custom.rect[3], custom.clip[3]) * scale), y0, h);
    return .{ .x = @intFromFloat(x0), .y = @intFromFloat(y0), .width = @intFromFloat(x1 - x0), .height = @intFromFloat(y1 - y0) };
}

const gradient_msl =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct Out { float4 position [[position]]; };
    \\vertex Out vs(uint i [[vertex_id]]) {
    \\    Out o;
    \\    o.position = float4(float(i & 1u) * 4.0 - 1.0, float(i >> 1u) * 4.0 - 1.0, 0.0, 1.0);
    \\    return o;
    \\}
    \\fragment float4 fs(Out in [[stage_in]], constant float2& size [[buffer(0)]]) {
    \\    float2 p = in.position.xy;
    \\    return float4(p.x / size.x * 0.5, 0.25, p.y / size.y * 0.6, 1.0);
    \\}
;

pub const Gradient = struct {
    pipeline: Id,

    pub fn init(device: Id, desc: pipeline.Desc) pipeline.Error!Gradient {
        const pool = objc.Pool.push();
        defer pool.pop();
        const pd = try pipeline.descriptor(device, gradient_msl, desc);
        defer objc.release(pd);
        return .{ .pipeline = try pipeline.create(device, pd) };
    }

    pub fn deinit(g: *Gradient) void {
        objc.release(g.pipeline);
    }

    /// Draws the gradient inside `rect` over a target of `extent` pixels, straight on the
    /// encoder. Leaves its pipeline, viewport, scissor and fragment bytes bound.
    pub fn draw(g: *const Gradient, pass: mtl.RenderEncoder, rect: mtl.ScissorRect, extent: [2]u32) void {
        if (rect.width == 0 or rect.height == 0) return;
        const size = [2]f32{ @floatFromInt(extent[0]), @floatFromInt(extent[1]) };
        const e = pass.id;
        objc.msg(void, e, "setRenderPipelineState:", .{g.pipeline});
        objc.msg(void, e, "setViewport:", .{mtl.Viewport{ .x = 0, .y = 0, .width = size[0], .height = size[1] }});
        objc.msg(void, e, "setScissorRect:", .{rect});
        objc.msg(void, e, "setFragmentBytes:length:atIndex:", .{ @as(*const anyopaque, &size), @as(U, @sizeOf(@TypeOf(size))), @as(U, 0) });
        objc.msg(void, e, "drawPrimitives:vertexStart:vertexCount:", .{ mtl.PrimitiveType.triangle, @as(U, 0), @as(U, 3) });
    }
};

const testing = std.testing;

test "custom: the scissor is the rect cut by its clip, in pixels, inside the target" {
    const open: [4]f32 = .{ -1e6, -1e6, 1e6, 1e6 };
    try testing.expectEqual(mtl.ScissorRect{ .x = 16, .y = 16, .width = 288, .height = 208 }, scissor(.{ 320, 240 }, 2, .{ .rect = .{ 8, 8, 152, 112 }, .clip = open, .data = 0, .id = 0, .node = 0 }));
    try testing.expectEqual(mtl.ScissorRect{ .x = 0, .y = 200, .width = 301, .height = 40 }, scissor(.{ 320, 240 }, 2, .{ .rect = .{ -10, 100.25, 400, 300 }, .clip = .{ 0, 0, 150.2, 1e6 }, .data = 0, .id = 0, .node = 0 }));
    const empty = scissor(.{ 320, 240 }, 2, .{ .rect = .{ 50, 50, 60, 60 }, .clip = .{ 70, 70, 80, 80 }, .data = 0, .id = 0, .node = 0 });
    try testing.expectEqual(0, empty.width * empty.height);
}

test "custom: the host's pipeline compiles on a real device" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try objc.load();
    var dev = try @import("device.zig").Device.init();
    defer dev.deinit();
    var g = try Gradient.init(dev.device, .{ .format = .rgba8_unorm });
    g.deinit();
}
