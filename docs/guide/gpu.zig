//! The example of docs/guide/gpu.md: an application's custom drawing, written once against
//! `lcgf_render.gpu`. It is generic over the projection (`gpu`) and the translated shader
//! (`source`), so it compiles for every back end; src/render/vk/gpu.zig runs it on a real
//! Vulkan device (its test "the gpu guide's picture"), the guide tests only check the data.

const std = @import("std");

/// A 2 × 2 picture, tinted, drawn into a rectangle: textured.wgsl, the projection's test shader.
pub fn Picture(comptime gpu: type, comptime source: type) type {
    return struct {
        const P = @This();
        pub const Shader = gpu.Shader(source);

        pipeline: gpu.RenderPipeline(Shader),
        group: gpu.BindGroup(Shader, 0),
        image: gpu.Texture,
        smp: gpu.Sampler,
        quad: gpu.Buffer,
        tint: gpu.Buffer,

        pub fn init(dev: gpu.Device, arena: *gpu.Arena, target: gpu.Target) !P {
            const image = try dev.createTexture(arena, .{ .size = .{ .width = 2, .height = 2 }, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .copy_dst = true } });
            const smp = try dev.createSampler(.{});
            const quad = try dev.createBuffer(arena, .{ .size = 6 * 8, .usage = .{ .vertex = true, .copy_dst = true } });
            const tint = try dev.createBuffer(arena, .{ .size = 16, .usage = .{ .uniform = true, .copy_dst = true } });
            const pipeline = try dev.createRenderPipeline(Shader, .{
                .vertex = .{ .buffers = &.{.{ .array_stride = 8, .attributes = &.{.{ .format = .float32x2, .offset = 0, .shader_location = 0 }} }} },
                .fragment = .{ .targets = &.{.{ .format = target.format, .blend = .premultiplied }} },
                .multisample = .{ .count = target.samples },
            });
            // Group 0 of textured.wgsl as a struct: a binding misspelt, missing or of the wrong
            // kind is a compile error, not a validation message at run time.
            const group = try dev.createBindGroup(arena, pipeline, 0, .{ .params = tint, .tex = image.createView(), .smp = smp });
            return .{ .pipeline = pipeline, .group = group, .image = image, .smp = smp, .quad = quad, .tint = tint };
        }

        pub fn deinit(p: *P, dev: gpu.Device) void {
            dev.destroyRenderPipeline(p.pipeline);
            dev.destroyBuffer(p.tint);
            dev.destroyBuffer(p.quad);
            dev.destroySampler(p.smp);
            dev.destroyTexture(p.image);
        }

        /// The upload phase: copies only, before any pass of the frame.
        pub fn upload(p: *const P, up: *gpu.Upload, tint: [4]f32) !void {
            try up.writeTexture(p.image, &checker, 8);
            up.writeBuffer(p.quad, 0, std.mem.sliceAsBytes(&corners));
            up.writeBuffer(p.tint, 0, std.mem.asBytes(&tint));
        }

        /// Draws into `rect` of the pass's target. It sets everything it depends on, so it
        /// can follow any UI draw in the UI's own pass (the inline route).
        pub fn draw(p: *const P, pass: *gpu.RenderPass, rect: gpu.Rect) void {
            if (rect.width == 0 or rect.height == 0) return;
            pass.setViewport(@floatFromInt(rect.x), @floatFromInt(rect.y), @floatFromInt(rect.width), @floatFromInt(rect.height), 0, 1);
            pass.setScissorRect(rect.x, rect.y, rect.width, rect.height);
            pass.setPipeline(p.pipeline);
            pass.setBindGroup(0, &p.group);
            pass.setVertexBuffer(0, p.quad, 0);
            pass.draw(6, 1, 0, 0);
        }

        /// Draws into a texture of its own in a pass of its own (the texture-in route): the
        /// pass ends with `target` ready to sample, as `Style.texture` or anything else.
        pub fn drawInto(p: *const P, enc: gpu.Encoder, target: gpu.Texture) void {
            var pass = enc.beginRenderPass(.{ .color_attachments = &.{.{ .view = target.createView(), .clear_value = .{ .a = 1 } }} });
            p.draw(&pass, .{ .x = 0, .y = 0, .width = target.width, .height = target.height });
            pass.end();
        }
    };
}

/// Red, green / blue, white: rows from the top.
pub const checker = [16]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 };
/// Two triangles over the target, as textured.wgsl takes them: 0..1, rows from the top.
pub const corners = [6][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };

test "gpu guide: the picture's data" {
    try std.testing.expectEqual(4 * 4, checker.len);
    try std.testing.expectEqual(48, @sizeOf(@TypeOf(corners)));
}
