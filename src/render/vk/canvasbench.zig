//! The canvas benchmark on Vulkan (docs/plans/schemify.md C4): bench/micro/canvasbench.zig's
//! 100,000 mixed primitives drawn by the vk renderer's canvas pipeline into a 1920x1080 RGBA8
//! target, frame after frame while the camera pans, zooms, and while 100 rows change a frame.
//! Each frame is prepare (the upload), the command buffer recorded, submitted and waited for,
//! so a frame's time is the CPU's work plus the GPU's, one after the other. Prints per scenario
//! the min, median and p90 frame time, the CPU time of prepare and recording, and the bytes
//! prepare wrote. The device is device.zig `pick`'s: a discrete GPU if there is one, else
//! whatever VK_ICD_FILENAMES offers (lavapipe in `nix develop .#golden`).
//!
//!     zig build vk-canvasbench && zig-out/bin/vk-canvasbench [--frames 120]
const std = @import("std");
const lcgf = @import("lcgf");
const bench = @import("canvasbench");
const loader = @import("loader.zig");
const host = @import("host.zig");
const pass = @import("pass.zig");
const Renderer = @import("renderer.zig").CanvasRenderer;
const c = loader.c;
const canvas = lcgf.canvas;
const DrawList = lcgf.draw_list.DrawList;
const iface = lcgf.render_iface;

var shape_buf: [canvas.Instances.requiredBytes(bench.count, bench.count / 10 * 3, 64, .{})]u8 align(lcgf.mem.column_align) = undefined;
var list_buf: [list_bytes]u8 align(lcgf.mem.column_align) = undefined;
const list_bytes = blk: {
    var counter: lcgf.mem.Carver = .{ .buf = null };
    _ = DrawList.init(&counter, 1, 1, 1);
    break :blk counter.off;
};
var h: host.Host = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    var frames: u32 = 120;
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--frames")) frames = try std.fmt.parseInt(u32, args.next().?, 10);
    }
    const size = [2]u32{ 1920, 1080 };
    const wf: f32 = @floatFromInt(size[0]);
    const hf: f32 = @floatFromInt(size[1]);

    var carver: lcgf.mem.Carver = .{ .buf = &shape_buf };
    var shapes = canvas.Instances.init(&carver, bench.count, bench.count / 10 * 3, 64, .{});
    bench.build(&shapes);
    var lc: lcgf.mem.Carver = .{ .buf = &list_buf };
    var list = DrawList.init(&lc, 1, 1, 1);
    var rows: [1]lcgf.draw_list.CanvasDraw = undefined;
    const all = [_]canvas.Range{shapes.since(0)};
    list.canvases = &rows;
    list.customs[0] = .{ .rect = .{ 0, 0, wf, hf }, .clip = .{ 0, 0, wf, hf }, .data = 0, .id = 0, .node = 0 };
    list.custom_len = 1;
    list.cmd.kind[0] = @backingInt(DrawList.Kind.canvas);
    list.cmd.first[0] = 0;
    list.cmd.count[0] = 1;
    list.cmd_len = 1;

    try h.init();
    defer h.deinit();
    const d = &h.device;
    const sampler = try host.nearestSampler(d);
    defer d.fns.vkDestroySampler.?(d.handle, sampler, null);
    var white = try h.sampled(1, 1, &.{ 255, 255, 255, 255 });
    defer d.destroyImage(&white);
    const atlas_px = try gpa.alloc(u8, 128 * 256 * 4);
    for (atlas_px, 0..) |*p, k| p.* = @intCast((k * 37) & 255);
    var atlas = try h.sampled(128, 256, atlas_px);
    defer d.destroyImage(&atlas);
    var gfx = try Renderer.init(d, .{ .format = c.VK_FORMAT_R8G8B8A8_UNORM, .canvas_rows = bench.count, .canvas_verts = bench.count / 10 * 3 }, white.view, sampler);
    defer gfx.deinit(d);
    const atlas_handle = try gfx.addTexture(d, atlas.view, sampler);
    var target = try host.Target.init(d, size[0], size[1], 1);
    defer target.deinit(d);

    const world_w: f32 = bench.cols * bench.cell;
    const fit = wf / world_w;
    const total = try gpa.alloc(u64, frames);
    const cpu = try gpa.alloc(u64, frames);
    const bytes = try gpa.alloc(usize, frames);
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    try w.print("vk canvas: {s}, {d} instances, {d}x{d}, {d} frames a row\n", .{ std.mem.sliceTo(&d.props.deviceName, 0), shapes.len, size[0], size[1], frames });
    try w.print("{s:<9} {s:>8} {s:>10} {s:>8} {s:>12} {s:>12} {s:>8}\n", .{ "scenario", "min ms", "median ms", "p90 ms", "cpu med us", "bytes/frame", "fps" });
    var slot: u32 = 0;
    // Warm up: the first frames upload everything into both ring slots.
    for ([_][]const u8{ "warm", "pan-all", "pan-4x", "zoom", "edit-100" }) |scenario| {
        for (0..frames) |f| {
            const t: f32 = @floatFromInt(f);
            const cam: canvas.Camera = if (std.mem.eql(u8, scenario, "pan-4x"))
                .{ .origin = .{ 600_000 + @as(i64, @intFromFloat(t * 1_000)), 600_000 }, .scale = 4 * fit }
            else if (std.mem.eql(u8, scenario, "zoom"))
                bench.zoomed(fit * std.math.pow(f32, 8, t / @as(f32, @floatFromInt(frames))), wf, hf, world_w)
            else
                .{ .origin = .{ @intFromFloat(t * 2_000), 0 }, .scale = fit };
            if (std.mem.eql(u8, scenario, "edit-100")) {
                // 100 rows rewritten in place (moved by a unit), as an edit marks them.
                const first: u32 = @intCast((f * 997) % (bench.count - 100));
                for (shapes.c.pos[first..][0..100]) |*p| p[0] +%= 1;
                shapes.markDirty(.{ .first = first, .count = 100 });
            }
            rows[0] = .{ .instances = &shapes, .camera = cam, .ranges = &all, .palette = &bench.palette };
            const t0 = now();
            gfx.prepare(slot, &list, .{ .texture = atlas_handle }, .{ wf, hf }, 1);
            shapes.clearDirty();
            const cmd = try h.once.begin(d);
            pass.begin(d, cmd, target.begin(.{ 0, 0, 0, 1 }));
            iface.render(&gfx, cmd, &list);
            pass.end(d, cmd, .{ .image = target.image.handle, .layout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL });
            const t1 = now();
            try h.once.submit(d);
            total[f] = now() - t0;
            cpu[f] = t1 - t0;
            bytes[f] = gfx.canvas.?.uploaded;
            slot ^= 1;
        }
        if (std.mem.eql(u8, scenario, "warm")) continue;
        std.mem.sort(u64, total, {}, std.sort.asc(u64));
        std.mem.sort(u64, cpu, {}, std.sort.asc(u64));
        std.mem.sort(usize, bytes, {}, std.sort.asc(usize));
        const med = total[frames / 2];
        try w.print("{s:<9} {d:>8.2} {d:>10.2} {d:>8.2} {d:>12.1} {d:>12} {d:>8.0}\n", .{ scenario, ms(total[0]), ms(med), ms(total[frames * 9 / 10]), @as(f64, @floatFromInt(cpu[frames / 2])) / 1e3, bytes[frames / 2], 1e9 / @as(f64, @floatFromInt(med)) });
        try w.flush();
    }
}

fn now() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}
