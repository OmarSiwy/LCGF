//! The projection's own checks, written once against `lcgf_render.gpu` and run by every back
//! end on a real device: the parts of WebGPU's model the conformance scene's gradient does not
//! reach. Each is three steps, so a host whose readback is asynchronous (a browser) can run the
//! middle one itself: `init` and `record` the work, the host submits and reads back, `verify`
//! the result. The `renderToTexture` and `compute` wrappers do all three for a host `h` with
//!
//!     h.upload(staging: *gpu.Staging) !gpu.Upload  a command stream begun for one submission
//!     h.submit() !void                            submit it and wait
//!     h.readTexture(t: gpu.Texture, out: []u8) !void   RGBA8 rows from the top
//!     h.readBuffer(b: gpu.Buffer, out: []u8) !void
//!
//! `shaders` is the shaders module (`src/render/gpu/*.wgsl` translated for the back end).

const std = @import("std");

/// Upload a 2x2 pattern through staging, draw it into a 4x4 texture, sample that into an 8x8
/// one in a second pass (the render-to-texture convention), read it back: each source texel
/// is a 4x4 block.
pub fn RenderToTexture(comptime gpu: type, comptime shaders: type) type {
    return struct {
        const R = @This();
        const S = gpu.Shader(shaders.textured);
        pub const width = 8;
        pub const height = 8;

        arena: gpu.Arena,
        host_arena: gpu.Arena,
        staging: gpu.Staging,
        pattern: gpu.Texture,
        middle: gpu.Texture,
        final: gpu.Texture,
        smp: gpu.Sampler,
        quad: gpu.Buffer,
        tint: gpu.Buffer,
        pipeline: gpu.RenderPipeline(S),
        first: gpu.BindGroup(S, 0),
        second: gpu.BindGroup(S, 0),

        /// Fills `r` in place: the arenas must not move once resources live in them.
        pub fn init(r: *R, dev: gpu.Device) !void {
            r.arena = try .init(dev, .{ .bytes = 1 << 20 });
            r.host_arena = try .init(dev, .{ .bytes = 1 << 16, .memory = .host });
            r.staging = try .init(dev, &r.host_arena, 1 << 12);
            r.pattern = try dev.createTexture(&r.arena, .{ .size = .{ .width = 2, .height = 2 }, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .copy_dst = true } });
            r.middle = try dev.createTexture(&r.arena, .{ .size = .{ .width = 4, .height = 4 }, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .render_attachment = true } });
            r.final = try dev.createTexture(&r.arena, .{ .size = .{ .width = width, .height = height }, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .render_attachment = true, .copy_src = true } });
            r.smp = try dev.createSampler(.{});
            r.quad = try dev.createBuffer(&r.arena, .{ .size = 6 * 8, .usage = .{ .vertex = true, .copy_dst = true } });
            r.tint = try dev.createBuffer(&r.arena, .{ .size = 16, .usage = .{ .uniform = true, .copy_dst = true } });
            r.pipeline = try dev.createRenderPipeline(S, .{
                .vertex = .{ .buffers = &.{.{ .array_stride = 8, .attributes = &.{.{ .format = .float32x2, .offset = 0, .shader_location = 0 }} }} },
                .fragment = .{ .targets = &.{.{ .format = .rgba8_unorm }} },
            });
            // The bind group's fields are textured.wgsl's group 0: params, tex, smp.
            r.first = try dev.createBindGroup(&r.arena, r.pipeline, 0, .{ .params = r.tint, .tex = r.pattern.createView(), .smp = r.smp });
            r.second = try dev.createBindGroup(&r.arena, r.pipeline, 0, .{ .params = r.tint, .tex = r.middle.createView(), .smp = r.smp });
        }

        pub fn deinit(r: *R, dev: gpu.Device) void {
            dev.destroyRenderPipeline(r.pipeline);
            dev.destroyBuffer(r.tint);
            dev.destroyBuffer(r.quad);
            dev.destroySampler(r.smp);
            dev.destroyTexture(r.final);
            dev.destroyTexture(r.middle);
            dev.destroyTexture(r.pattern);
            r.staging.deinit(dev);
            r.host_arena.deinit();
            r.arena.deinit();
        }

        pub fn record(r: *R, up: *gpu.Upload) !void {
            // Red, green / blue, white: rows from the top.
            try up.writeTexture(r.pattern, &.{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 }, 8);
            const corners = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
            up.writeBuffer(r.quad, 0, std.mem.sliceAsBytes(&corners));
            up.writeBuffer(r.tint, 0, std.mem.asBytes(&[4]f32{ 1, 1, 1, 1 }));
            var enc = up.finish();
            inline for (.{ .{ "middle", "first" }, .{ "final", "second" } }) |step| {
                var pass = enc.beginRenderPass(.{ .color_attachments = &.{.{ .view = @field(r, step[0]).createView(), .clear_value = .{ .a = 1 } }} });
                pass.setPipeline(r.pipeline);
                pass.setBindGroup(0, &@field(r, step[1]));
                pass.setVertexBuffer(0, r.quad, 0);
                pass.draw(6, 1, 0, 0);
                pass.end();
            }
        }

        /// Whether `px` (the final texture's RGBA8 rows) has each source texel as a 4x4 block.
        pub fn verify(px: []const u8) bool {
            const expected = [_]struct { usize, usize, [4]u8 }{
                .{ 1, 1, .{ 255, 0, 0, 255 } },
                .{ 6, 1, .{ 0, 255, 0, 255 } },
                .{ 1, 6, .{ 0, 0, 255, 255 } },
                .{ 6, 6, .{ 255, 255, 255, 255 } },
            };
            for (expected) |e| {
                const got = px[(e[1] * width + e[0]) * 4 ..][0..4];
                if (!std.mem.eql(u8, got, &e[2])) return false;
            }
            return true;
        }
    };
}

/// A compute pass writes a storage buffer from its index and a uniform; the host reads it.
pub fn Compute(comptime gpu: type, comptime shaders: type) type {
    return struct {
        const K = @This();
        pub const S = gpu.Shader(shaders.fill);
        pub const count = 200;

        shared: gpu.Arena,
        staging: gpu.Staging,
        out: gpu.Buffer,
        base: gpu.Buffer,
        pipeline: gpu.ComputePipeline(S),
        group: gpu.BindGroup(S, 0),

        pub fn init(k: *K, dev: gpu.Device) !void {
            k.shared = try .init(dev, .{ .bytes = 1 << 16, .memory = .host });
            k.staging = try .init(dev, &k.shared, 256);
            k.out = try dev.createBuffer(&k.shared, .{ .size = count * 4, .usage = .{ .storage = true, .copy_src = true } });
            k.base = try dev.createBuffer(&k.shared, .{ .size = 16, .usage = .{ .uniform = true, .copy_dst = true } });
            k.pipeline = try dev.createComputePipeline(S, .{ .entry_point = "main" });
            k.group = try dev.createBindGroup(&k.shared, k.pipeline, 0, .{ .out = k.out, .base = k.base });
        }

        pub fn deinit(k: *K, dev: gpu.Device) void {
            dev.destroyComputePipeline(k.pipeline);
            dev.destroyBuffer(k.base);
            dev.destroyBuffer(k.out);
            k.staging.deinit(dev);
            k.shared.deinit();
        }

        pub fn record(k: *K, up: *gpu.Upload) void {
            up.writeBuffer(k.base, 0, std.mem.asBytes(&[4]u32{ 7, 0, 0, 0 }));
            var enc = up.finish();
            var cp = enc.beginComputePass();
            cp.setPipeline(k.pipeline);
            cp.setBindGroup(0, &k.group);
            cp.dispatchWorkgroups(4, 1, 1);
            cp.end();
        }

        /// Whether element i of `values` is i * 3 + 7.
        pub fn verify(values: []const u32) bool {
            if (values.len != count) return false;
            for (values, 0..) |v, i| if (v != i * 3 + 7) return false;
            return true;
        }
    };
}

pub fn renderToTexture(comptime gpu: type, comptime shaders: type, dev: gpu.Device, h: anytype) !void {
    const R = RenderToTexture(gpu, shaders);
    var r: R = undefined;
    try r.init(dev);
    defer r.deinit(dev);
    var up: gpu.Upload = try h.upload(&r.staging);
    try r.record(&up);
    try h.submit();
    var px: [R.width * R.height * 4]u8 = undefined;
    try h.readTexture(r.final, &px);
    try std.testing.expect(R.verify(&px));
}

pub fn compute(comptime gpu: type, comptime shaders: type, dev: gpu.Device, h: anytype) !void {
    const K = Compute(gpu, shaders);
    var k: K = undefined;
    try k.init(dev);
    defer k.deinit(dev);
    try std.testing.expectEqual([3]u32{ 64, 1, 1 }, comptime K.S.module.entryPoint("main").workgroup_size);
    var up: gpu.Upload = try h.upload(&k.staging);
    k.record(&up);
    try h.submit();
    var values: [K.count]u32 = undefined;
    try h.readBuffer(k.out, std.mem.sliceAsBytes(&values));
    try std.testing.expect(K.verify(&values));
}
