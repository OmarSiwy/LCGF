//! The wgpu side of probe.zig: the same measurements through the wgpu back end over
//! wgpu-native (which runs on the same Vulkan driver), for bench/micro/probe.py:
//!
//!     python3 bench/micro/probe.py -- zig-out/bin/vk-probe-wgpu device
//!     python3 bench/micro/probe.py -- zig-out/bin/vk-probe-wgpu empty
//!     python3 bench/micro/probe.py -- zig-out/bin/vk-probe-wgpu scenes
//!
//! Lives with the Vulkan back end because lane render-vk owns the comparison; it uses
//! src/render/wgpu/native.zig unchanged, as a module (build.zig, -Dwgpu-native).
const std = @import("std");
const lcgf = @import("lcgf");
const native = @import("wgpu_native");
const host = native.host;
const c = native.c;
const conformance = lcgf.render_conformance;

pub const frames = 2000;

var st: [conformance.scenes.len]conformance.Storage = @splat(.{});

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const mode = args.next() orelse "empty";
    const scenes = std.mem.eql(u8, mode, "scenes");

    var h = try host.Host.init();
    defer h.deinit();
    if (std.mem.eql(u8, mode, "device")) return ready("ready wgpu device only\n");
    var ctx = native.Context.init(h.device);
    defer ctx.deinit();
    const sampler = host.nearestSampler(&h);
    defer c.wgpuSamplerRelease(sampler);
    var white = host.Image.init(&h, 1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
    defer white.deinit();
    var gfx = native.Renderer.init(&ctx, .{ .format = c.WGPUTextureFormat_RGBA8Unorm }, white.view, sampler);
    defer gfx.deinit();

    var line: [160]u8 = undefined;
    var name: [96]u8 = undefined;
    var msg: []const u8 = undefined;
    if (!scenes) {
        var target = host.Target.init(&h, 800, 600, c.WGPUTextureFormat_RGBA8Unorm);
        defer target.deinit();
        const encoder = c.wgpuDeviceCreateCommandEncoder(h.device, null);
        host.endPass(host.beginPass(encoder, target.view, null, .{ 0, 0, 0, 1 }));
        h.submit(encoder);
        _ = c.wgpuDevicePoll(h.device, 1, null);
        msg = try std.fmt.bufPrint(&line, "ready wgpu empty 800x600 ({s})\n", .{h.adapterName(&name)});
        ready(msg);
        return;
    }
    var target = host.Target.init(&h, 160, 120, c.WGPUTextureFormat_RGBA8Unorm);
    defer target.deinit();
    for (&st, &conformance.scenes) |*s, *scene| s.load(scene);
    var record_ns: u64 = 0;
    var frame_ns: u64 = 0;
    for (0..frames) |n| {
        const s = &st[n % st.len];
        const t0 = now();
        gfx.prepare(h.queue, &s.draw, s.glyphs(), .{ 160, 120 }, 1);
        const encoder = c.wgpuDeviceCreateCommandEncoder(h.device, null);
        const rp = host.beginPass(encoder, target.view, null, .{ 0, 0, 0, 1 });
        gfx.render(rp, &s.draw);
        host.endPass(rp);
        h.submit(encoder);
        const t1 = now();
        _ = c.wgpuDevicePoll(h.device, 1, null);
        record_ns += t1 - t0;
        frame_ns += now() - t0;
    }
    msg = try std.fmt.bufPrint(&line, "ready wgpu scenes frames={d} cpu_us={d:.1} frame_us={d:.1}\n", .{ frames, us(record_ns), us(frame_ns) });
    ready(msg);
}

fn now() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn us(total_ns: u64) f64 {
    return @as(f64, @floatFromInt(total_ns)) / frames / 1000;
}

fn ready(msg: []const u8) void {
    _ = std.os.linux.write(1, msg.ptr, msg.len);
    var buf: [64]u8 = undefined;
    while (std.os.linux.read(0, &buf, buf.len) > 0) {}
}
