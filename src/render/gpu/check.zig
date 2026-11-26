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
            errdefer r.arena.deinit();
            r.host_arena = try .init(dev, .{ .bytes = 1 << 16, .memory = .host });
            errdefer r.host_arena.deinit();
            r.staging = try .init(dev, &r.host_arena, 1 << 12);
            errdefer r.staging.deinit(dev);
            r.pattern = try dev.createTexture(&r.arena, .{ .size = .{ .width = 2, .height = 2 }, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .copy_dst = true } });
            errdefer dev.destroyTexture(r.pattern);
            r.middle = try dev.createTexture(&r.arena, .{ .size = .{ .width = 4, .height = 4 }, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .render_attachment = true } });
            errdefer dev.destroyTexture(r.middle);
            r.final = try dev.createTexture(&r.arena, .{ .size = .{ .width = width, .height = height }, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .render_attachment = true, .copy_src = true } });
            errdefer dev.destroyTexture(r.final);
            r.smp = try dev.createSampler(.{});
            errdefer dev.destroySampler(r.smp);
            r.quad = try dev.createBuffer(&r.arena, .{ .size = 6 * 8, .usage = .{ .vertex = true, .copy_dst = true } });
            errdefer dev.destroyBuffer(r.quad);
            r.tint = try dev.createBuffer(&r.arena, .{ .size = 16, .usage = .{ .uniform = true, .copy_dst = true } });
            errdefer dev.destroyBuffer(r.tint);
            r.pipeline = try dev.createRenderPipeline(S, .{
                .vertex = .{ .buffers = &.{.{ .array_stride = 8, .attributes = &.{.{ .format = .float32x2, .offset = 0, .shader_location = 0 }} }} },
                .fragment = .{ .targets = &.{.{ .format = .rgba8_unorm }} },
            });
            errdefer dev.destroyRenderPipeline(r.pipeline);
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
            errdefer k.shared.deinit();
            k.staging = try .init(dev, &k.shared, 256);
            errdefer k.staging.deinit(dev);
            k.out = try dev.createBuffer(&k.shared, .{ .size = count * 4, .usage = .{ .storage = true, .copy_src = true } });
            errdefer dev.destroyBuffer(k.out);
            k.base = try dev.createBuffer(&k.shared, .{ .size = 16, .usage = .{ .uniform = true, .copy_dst = true } });
            errdefer dev.destroyBuffer(k.base);
            k.pipeline = try dev.createComputePipeline(S, .{ .entry_point = "main" });
            errdefer dev.destroyComputePipeline(k.pipeline);
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

/// Instanced draws (instanced.wgsl): a vertex-step buffer of corners, an instance-step buffer
/// of `sint32x2` and `uint32` attributes, and a second instance-step buffer of `sint32x4` bound
/// at an offset, drawn three times with first instances 5, 0 and 2. Each instance fills one
/// column of an 8 x 1 target; the shader turns any wrong value into magenta.
pub fn Instancing(comptime gpu: type, comptime shaders: type) type {
    return struct {
        const I = @This();
        const S = gpu.Shader(shaders.instanced);
        pub const width = 8;
        /// The columns drawn: instances 5 and 6, then 0, then 2.
        pub const drawn = [width]bool{ true, false, true, false, false, true, true, false };
        const Row = extern struct { at: [2]i32, rgba: u32 };

        arena: gpu.Arena,
        host_arena: gpu.Arena,
        staging: gpu.Staging,
        target: gpu.Texture,
        corners: gpu.Buffer,
        rows: gpu.Buffer,
        checks: gpu.Buffer,
        pipeline: gpu.RenderPipeline(S),

        pub fn init(r: *I, dev: gpu.Device) !void {
            r.arena = try .init(dev, .{ .bytes = 1 << 16 });
            errdefer r.arena.deinit();
            r.host_arena = try .init(dev, .{ .bytes = 1 << 16, .memory = .host });
            errdefer r.host_arena.deinit();
            r.staging = try .init(dev, &r.host_arena, 1 << 12);
            errdefer r.staging.deinit(dev);
            r.target = try dev.createTexture(&r.arena, .{ .size = .{ .width = width, .height = 1 }, .format = .rgba8_unorm, .usage = .{ .render_attachment = true, .copy_src = true } });
            errdefer dev.destroyTexture(r.target);
            r.corners = try dev.createBuffer(&r.arena, .{ .size = 6 * 8, .usage = .{ .vertex = true, .copy_dst = true } });
            errdefer dev.destroyBuffer(r.corners);
            r.rows = try dev.createBuffer(&r.arena, .{ .size = width * @sizeOf(Row), .usage = .{ .vertex = true, .copy_dst = true } });
            errdefer dev.destroyBuffer(r.rows);
            r.checks = try dev.createBuffer(&r.arena, .{ .size = (width + 1) * 16, .usage = .{ .vertex = true, .copy_dst = true } });
            errdefer dev.destroyBuffer(r.checks);
            r.pipeline = try dev.createRenderPipeline(S, .{
                .vertex = .{ .buffers = &.{
                    .{ .array_stride = 8, .attributes = &.{.{ .format = .float32x2, .offset = 0, .shader_location = 0 }} },
                    .{ .array_stride = @sizeOf(Row), .step_mode = .instance, .attributes = &.{
                        .{ .format = .sint32x2, .offset = @offsetOf(Row, "at"), .shader_location = 1 },
                        .{ .format = .uint32, .offset = @offsetOf(Row, "rgba"), .shader_location = 2 },
                    } },
                    .{ .array_stride = 16, .step_mode = .instance, .attributes = &.{.{ .format = .sint32x4, .offset = 0, .shader_location = 3 }} },
                } },
                .fragment = .{ .targets = &.{.{ .format = .rgba8_unorm }} },
            });
        }

        pub fn deinit(r: *I, dev: gpu.Device) void {
            dev.destroyRenderPipeline(r.pipeline);
            dev.destroyBuffer(r.checks);
            dev.destroyBuffer(r.rows);
            dev.destroyBuffer(r.corners);
            dev.destroyTexture(r.target);
            r.staging.deinit(dev);
            r.host_arena.deinit();
            r.arena.deinit();
        }

        /// Column `i`'s colour, as `unpack4x8unorm` reads it (red in the low byte).
        pub fn color(i: u32) [4]u8 {
            return .{ @intCast(30 * i), @intCast(255 - 30 * i), @intCast(10 * i), 255 };
        }

        pub fn record(r: *I, up: *gpu.Upload) void {
            const corners = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
            var rows: [width]Row = undefined;
            // Row 0 of `checks` is never read: the buffer is bound 16 bytes in.
            var checks: [width + 1][4]i32 = undefined;
            checks[0] = @splat(99);
            for (0..width) |i| {
                const k: i32 = @intCast(i);
                rows[i] = .{ .at = .{ -k, k }, .rgba = @bitCast(color(@intCast(i))) };
                checks[i + 1] = .{ k, -k, 2 * k, -7 };
            }
            up.writeBuffer(r.corners, 0, std.mem.sliceAsBytes(&corners));
            up.writeBuffer(r.rows, 0, std.mem.sliceAsBytes(&rows));
            up.writeBuffer(r.checks, 0, std.mem.sliceAsBytes(&checks));
            var enc = up.finish();
            var pass = enc.beginRenderPass(.{ .color_attachments = &.{.{ .view = r.target.createView(), .clear_value = .{ .a = 1 } }} });
            pass.setPipeline(r.pipeline);
            pass.setVertexBuffer(0, r.corners, 0);
            pass.setVertexBuffer(1, r.rows, 0);
            pass.setVertexBuffer(2, r.checks, 16);
            pass.draw(6, 2, 0, 5);
            pass.draw(6, 1, 0, 0);
            pass.draw(6, 1, 0, 2);
            pass.end();
        }

        /// Whether `px` (the target's RGBA8 row) has each drawn column's colour and the clear
        /// colour elsewhere.
        pub fn verify(px: []const u8) bool {
            for (0..width) |i| {
                const want: [4]u8 = if (drawn[i]) color(@intCast(i)) else .{ 0, 0, 0, 255 };
                if (!std.mem.eql(u8, px[i * 4 ..][0..4], &want)) return false;
            }
            return true;
        }
    };
}

pub fn instancing(comptime gpu: type, comptime shaders: type, dev: gpu.Device, h: anytype) !void {
    const I = Instancing(gpu, shaders);
    var r: I = undefined;
    try r.init(dev);
    defer r.deinit(dev);
    var up: gpu.Upload = try h.upload(&r.staging);
    r.record(&up);
    try h.submit();
    var px: [I.width * 4]u8 = undefined;
    try h.readTexture(r.target, &px);
    try std.testing.expect(I.verify(&px));
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

/// A `gpu` that fails its `budget`-th creation and counts what is still alive, so each check's
/// `init` can be failed at every step and shown to release what it had made.
const Leaky = struct {
    var live: i32 = 0;
    var budget: u32 = 0;
    fn take(counted: bool) error{OutOfArena}!void {
        if (budget == 0) return error.OutOfArena;
        budget -= 1;
        if (counted) live += 1;
    }
    fn drop() void {
        live -= 1;
    }
    const Pipeline = struct {};
    const Group = struct {};
    pub fn Shader(comptime _: anytype) type {
        return struct {};
    }
    pub fn RenderPipeline(comptime _: type) type {
        return Pipeline;
    }
    pub fn ComputePipeline(comptime _: type) type {
        return Pipeline;
    }
    pub fn BindGroup(comptime _: type, comptime _: u32) type {
        return Group;
    }
    pub const Arena = struct {
        pub fn init(_: Device, _: anytype) !Arena {
            try take(true);
            return .{};
        }
        pub fn deinit(_: *Arena) void {
            drop();
        }
    };
    pub const Staging = struct {
        pub fn init(_: Device, _: *Arena, _: u64) !Staging {
            try take(true);
            return .{};
        }
        pub fn deinit(_: Staging, _: Device) void {
            drop();
        }
    };
    pub const Texture = struct {
        pub fn createView(_: Texture) void {}
    };
    pub const Sampler = struct {};
    pub const Buffer = struct {};
    pub const Device = struct {
        pub fn createTexture(_: Device, _: *Arena, _: anytype) !Texture {
            try take(true);
            return .{};
        }
        pub fn destroyTexture(_: Device, _: Texture) void {
            drop();
        }
        pub fn createSampler(_: Device, _: anytype) !Sampler {
            try take(true);
            return .{};
        }
        pub fn destroySampler(_: Device, _: Sampler) void {
            drop();
        }
        pub fn createBuffer(_: Device, _: *Arena, _: anytype) !Buffer {
            try take(true);
            return .{};
        }
        pub fn destroyBuffer(_: Device, _: Buffer) void {
            drop();
        }
        pub fn createRenderPipeline(_: Device, comptime _: type, _: anytype) !Pipeline {
            try take(true);
            return .{};
        }
        pub fn destroyRenderPipeline(_: Device, _: Pipeline) void {
            drop();
        }
        pub fn createComputePipeline(_: Device, comptime _: type, _: anytype) !Pipeline {
            try take(true);
            return .{};
        }
        pub fn destroyComputePipeline(_: Device, _: Pipeline) void {
            drop();
        }
        // A bind group lives in its arena: nothing to destroy, but it can still fail.
        pub fn createBindGroup(_: Device, _: *Arena, _: anytype, comptime _: u32, _: anytype) !Group {
            try take(false);
            return .{};
        }
    };
    const shaders = struct {
        pub const textured = {};
        pub const fill = {};
        pub const instanced = {};
    };
};

test "every check's init releases what it made when a later step fails" {
    inline for (.{ RenderToTexture(Leaky, Leaky.shaders), Compute(Leaky, Leaky.shaders), Instancing(Leaky, Leaky.shaders) }) |C| {
        var steps: u32 = 0;
        while (true) : (steps += 1) {
            Leaky.budget = steps;
            Leaky.live = 0;
            var c: C = undefined;
            if (c.init(.{})) |_| {
                c.deinit(.{});
                try std.testing.expectEqual(@as(i32, 0), Leaky.live);
                break;
            } else |err| {
                try std.testing.expectEqual(error.OutOfArena, err);
                try std.testing.expectEqual(@as(i32, 0), Leaky.live);
            }
        }
        try std.testing.expect(steps > 3);
    }
}
