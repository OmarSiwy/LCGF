//! Memory and frame-time probe for the Vulkan back end, the counterpart of probe_wgpu.zig, for
//! tools/bench/probe.py:
//!
//!     python3 tools/bench/probe.py -- zig-out/bin/vk-probe device
//!     python3 tools/bench/probe.py -- zig-out/bin/vk-probe empty
//!     python3 tools/bench/probe.py -- zig-out/bin/vk-probe scenes
//!
//! device: instance and device only, no back end: the driver's own share (lavapipe is large).
//! empty: what an empty window costs: device, renderer (default capacities), an 800x600 target
//! and one cleared frame. scenes: the four conformance scenes drawn `frames` times in turn at
//! 160x120, timing the CPU side of each frame (prepare, record, submit) and the whole frame
//! (until the GPU is done). Prints one "ready ..." line and waits for stdin to close.
//!
//! Offscreen targets stand in for a window in both probes, so both measure the same thing on a
//! machine with no display: wgpu-native has no headless surface.
const std = @import("std");
const lcgf = @import("lcgf");
const vk = @import("vk.zig");
const c = vk.c;
const host = vk.host;
const pass = vk.pass;
const conformance = lcgf.render_conformance;

pub const frames = 2000;

var st: [conformance.scenes.len]conformance.Storage = @splat(.{});

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const mode = args.next() orelse "empty";
    const scenes = std.mem.eql(u8, mode, "scenes");

    var h: host.Host = undefined;
    try h.init();
    defer h.deinit();
    if (std.mem.eql(u8, mode, "device")) return ready("ready vk device only\n");
    const d = &h.device;
    const sampler = try host.nearestSampler(d);
    defer d.fns.vkDestroySampler.?(d.handle, sampler, null);
    var white = try h.sampled(1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
    defer d.destroyImage(&white);
    var gfx = try vk.Renderer.init(d, .{ .format = c.VK_FORMAT_R8G8B8A8_UNORM }, white.view, sampler);
    defer gfx.deinit(d);

    var line: [128]u8 = undefined;
    var msg: []const u8 = undefined;
    if (!scenes) {
        var target = try host.Target.init(d, 800, 600, 1);
        defer target.deinit(d);
        const cmd = try h.once.begin(d);
        pass.begin(d, cmd, target.begin(.{ 0, 0, 0, 1 }));
        pass.end(d, cmd, .{ .image = target.image.handle, .layout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL });
        try h.once.submit(d);
        msg = try std.fmt.bufPrint(&line, "ready vk empty 800x600 ({s})\n", .{d.name()});
        ready(msg);
        return;
    }
    var target = try host.Target.init(d, 160, 120, 1);
    defer target.deinit(d);
    for (&st, &conformance.scenes) |*s, *scene| s.load(scene);
    var record_ns: u64 = 0;
    var frame_ns: u64 = 0;
    for (0..frames) |n| {
        const s = &st[n % st.len];
        const t0 = now();
        gfx.prepare(@intCast(n % 2), &s.draw, s.glyphs(), .{ 160, 120 }, 1);
        const cmd = try h.once.begin(d);
        pass.begin(d, cmd, target.begin(.{ 0, 0, 0, 1 }));
        gfx.render(cmd, &s.draw);
        pass.end(d, cmd, .{ .image = target.image.handle, .layout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL });
        try h.once.send(d);
        const t1 = now();
        try h.once.wait(d);
        record_ns += t1 - t0;
        frame_ns += now() - t0;
    }
    msg = try std.fmt.bufPrint(&line, "ready vk scenes frames={d} cpu_us={d:.1} frame_us={d:.1}\n", .{ frames, us(record_ns), us(frame_ns) });
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

/// Prints the ready line and blocks until stdin closes (probe.py samples /proc meanwhile).
fn ready(msg: []const u8) void {
    _ = std.os.linux.write(1, msg.ptr, msg.len);
    var buf: [64]u8 = undefined;
    while (std.os.linux.read(0, &buf, buf.len) > 0) {}
}
