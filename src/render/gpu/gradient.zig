//! The render conformance scene's custom draw (`custom.png`), written once against
//! `lcgf_render.gpu` and compiled for every back end that has a projection. It replaces the
//! per-back-end copies that each spoke their own API. It is application code, the kind
//! docs/guide/gpu.md shows: a pipeline, a uniform buffer, a bind group, and per frame one
//! write in the upload phase and one draw in the UI's pass.
//!
//!     const Gradient = lcgf.gpu_gradient.Gradient(render.gpu, @import("gpu_shaders").gradient);
//!     var g = try Gradient.init(dev, &arena, target);
//!     g.upload(&up, width, height);                      // before the pass
//!     g.draw(&pass, gpu.scissor(c.rect, c.clip, scale, width, height), width, height);

const std = @import("std");

pub fn Gradient(comptime gpu: type, comptime source: type) type {
    return struct {
        const G = @This();
        pub const Shader = gpu.Shader(source);

        pipeline: gpu.RenderPipeline(Shader),
        group: gpu.BindGroup(Shader, 0),
        screen: gpu.Buffer,

        pub fn init(dev: gpu.Device, arena: *gpu.Arena, target: gpu.Target) !G {
            const screen = try dev.createBuffer(arena, .{ .size = 16, .usage = .{ .uniform = true, .copy_dst = true } });
            errdefer dev.destroyBuffer(screen);
            // No blending: the goldens' host draw replaces what is under it.
            const pipeline = try dev.createRenderPipeline(Shader, .{
                .fragment = .{ .targets = &.{.{ .format = target.format }} },
                .multisample = .{ .count = target.samples },
            });
            errdefer dev.destroyRenderPipeline(pipeline);
            const group = try dev.createBindGroup(arena, pipeline, 0, .{ .screen = screen });
            return .{ .pipeline = pipeline, .group = group, .screen = screen };
        }

        pub fn deinit(g: *G, dev: gpu.Device) void {
            dev.destroyRenderPipeline(g.pipeline);
            dev.destroyBuffer(g.screen);
        }

        /// The target size, written in the frame's upload phase.
        pub fn upload(g: *const G, up: *gpu.Upload, width: u32, height: u32) void {
            const v: [4]f32 = .{ @floatFromInt(width), @floatFromInt(height), 0, 0 };
            up.writeBuffer(g.screen, 0, std.mem.asBytes(&v));
        }

        /// Draws the gradient inside `rect` of a `width` × `height` target. Sets everything it
        /// depends on, so it may follow any UI draw, and leaves its own state bound.
        pub fn draw(g: *const G, pass: *gpu.RenderPass, rect: gpu.Rect, width: u32, height: u32) void {
            if (rect.width == 0 or rect.height == 0) return;
            pass.setViewport(0, 0, @floatFromInt(width), @floatFromInt(height), 0, 1);
            pass.setScissorRect(rect.x, rect.y, rect.width, rect.height);
            pass.setPipeline(g.pipeline);
            pass.setBindGroup(0, g.group);
            pass.draw(3, 1, 0, 0);
        }
    };
}
