//! Canvas benchmark (docs/plans/schemify.md C5): a schematic-like batch of 100,000 mixed
//! primitives drawn by sw (`sw.canvas.draw`, one band per thread as `sw.Setup.draw` does), frame
//! after frame while the camera pans and while it zooms. Prints per scenario and thread count
//! the min, median and p90 frame time and the user-space instructions per frame, summed over the
//! drawing threads (a counter per thread around each band; the pool's spinning is not counted).
//! `empty` looks beside the batch, so it measures what every band pays to cull all of it.
//! Each frame bins the rows into the bands first (`sw.canvas.Bin`, counted and timed with the
//! frame); `--walk` draws without the bin, every band walking the whole batch.
//! Timings compare on one machine only (docs/CHECKS.md); pin it, e.g.
//!
//!     zig build canvasbench-build && taskset -c 2-5 zig-out/bin/canvasbench [--size 1920x1080] [--frames 60]
const std = @import("std");
const lcgf = @import("lcgf");
const linux = std.os.linux;
const sw = lcgf.render_sw;
const canvas = lcgf.canvas;
const DrawList = lcgf.draw_list.DrawList;

pub const std_options: std.Options = .{ .signal_stack_size = null };

pub const count = 100_000;
/// One primitive per cell of a 320-wide grid, 6,000 world units a cell.
pub const cols = 320;
pub const cell = 6_000;
var shape_buf: [canvas.Instances.requiredBytes(count, count / 10 * 3, 4)]u8 align(lcgf.mem.column_align) = undefined;
var list_buf: [list_bytes]u8 align(lcgf.mem.column_align) = undefined;
var bin_buf: [sw.canvas.Bin.requiredBytes(count, 2 * count)]u8 align(lcgf.mem.column_align) = undefined;
const list_bytes = blk: {
    var counter: lcgf.mem.Carver = .{ .buf = null };
    _ = DrawList.init(&counter, 1, 1, 1);
    break :blk counter.off;
};

const layers = [_]canvas.Layer{
    .of(.{ .stroke = .rgb(230, 230, 230), .width = 1 }),
    .of(.{ .stroke = .rgb(90, 200, 255), .fill = .rgba(40, 90, 160, 180), .width = 1 }),
    .of(.{ .stroke = .rgb(255, 120, 60), .fill = .rgb(255, 200, 60), .width = 1 }),
    .of(.{ .stroke = .rgb(250, 250, 120), .width = 1 }),
};
pub const palette: canvas.Palette = .{ .layers = &layers, .zoom_scale = true };

/// Wires (30 %, a tenth of them dashed), rects (20 %), circles (10 %), arcs (10 %),
/// triangles (10 %) and glyphs (20 %), each inside its cell.
pub fn build(s: *canvas.Instances) void {
    var i: u32 = 0;
    while (s.len < count) : (i += 1) {
        const x: i32 = @intCast((i % cols) * cell);
        const y: i32 = @intCast((i / cols) * cell);
        switch (i % 10) {
            0, 1, 2 => _ = s.segment(.{ x, y + 1_000 }, .{ x + 5_000, y + 1_000 + @as(i32, @intCast(i % 3)) * 1_500 }, .{ .weight = @intCast(1 + i % 2), .dash = if (i % 30 == 0) 2 else 0, .cap = .round }),
            3, 4 => _ = s.rect(.{ x + 500, y + 500 }, .{ x + 5_000, y + 4_000 }, .{ .layer = 1, .radius = 400 }),
            5 => _ = s.circle(.{ x + 3_000, y + 3_000 }, 2_000, .{ .layer = 2, .stroke = false }),
            6 => _ = s.arc(.{ x + 3_000, y + 3_000 }, 2_200, .{ .layer = 1, .start = 0.5, .sweep = 3, .cap = .round }),
            7 => _ = s.polygon(&.{ .{ x + 500, y + 500 }, .{ x + 5_000, y + 3_000 }, .{ x + 500, y + 5_500 } }, .{ .layer = 2 }),
            else => _ = s.glyph(.{ x + 1_000, y + 1_000 }, .{ 2_400, 4_000 }, .{ 1.0 / 16.0, 4.0 / 16.0, 2.0 / 16.0, 5.0 / 16.0 }, .{ .layer = 3 }),
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    var size = [2]u32{ 1920, 1080 };
    var frames: u32 = 60;
    var walk = false;
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--walk")) walk = true;
        if (std.mem.eql(u8, a, "--frames")) frames = try std.fmt.parseInt(u32, args.next().?, 10);
        if (std.mem.eql(u8, a, "--size")) {
            var it = std.mem.splitScalar(u8, args.next().?, 'x');
            size = .{ try std.fmt.parseInt(u32, it.next().?, 10), try std.fmt.parseInt(u32, it.next().?, 10) };
        }
    }

    var carver: lcgf.mem.Carver = .{ .buf = &shape_buf };
    var shapes = canvas.Instances.init(&carver, count, count / 10 * 3, 4);
    build(&shapes);
    var bc: lcgf.mem.Carver = .{ .buf = &bin_buf };
    var bin = sw.canvas.Bin.init(&bc, count, 2 * count);
    var lc: lcgf.mem.Carver = .{ .buf = &list_buf };
    var list = DrawList.init(&lc, 1, 1, 1);
    var rows: [1]lcgf.draw_list.CanvasDraw = undefined;
    const all = [_]canvas.Range{shapes.since(0)};
    const wf: f32 = @floatFromInt(size[0]);
    const hf: f32 = @floatFromInt(size[1]);
    list.canvases = &rows;
    list.customs[0] = .{ .rect = .{ 0, 0, wf, hf }, .clip = .{ 0, 0, wf, hf }, .data = 0, .id = 0, .node = 0 };
    list.custom_len = 1;

    const pixels = try gpa.alloc(u32, sw.Framebuffer.len(size[0], size[1]));
    var fb = sw.Framebuffer.init(pixels, size[0], size[1], .rgba8);
    const atlas_px = try gpa.alloc(u8, 128 * 256);
    for (atlas_px, 0..) |*p, k| p.* = @intCast((k * 37) & 255);
    const atlas: sw.Image = .{ .width = 128, .height = 256, .alpha8 = atlas_px };
    // The world is 1,920,000 x 1,890,000 units: at 0.001 px a unit all of it is on screen.
    const world_w: f32 = cols * cell;
    const fit = wf / world_w;
    const samples = try gpa.alloc(u64, frames);
    const insns = try gpa.alloc(u64, frames);

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    try w.print("canvas: {d} instances ({d} B each), {d}x{d}, {d} frames per row\n", .{ shapes.len, 32, size[0], size[1], frames });
    try w.print("{s:<10} {s:>7} {s:>8} {s:>10} {s:>8} {s:>12} {s:>8}\n", .{ "scenario", "threads", "min ms", "median ms", "p90 ms", "insns/frame", "fps" });
    for ([_][]const u8{ "pan-all", "pan-4x", "zoom", "empty" }) |scenario| for ([_]u32{ 1, 2, 4 }) |threads| {
        var pool: sw.bands.Pool = undefined;
        try pool.init(io, threads);
        defer pool.deinit();
        for (0..frames) |f| {
            const t: f32 = @floatFromInt(f);
            const cam: canvas.Camera = if (std.mem.eql(u8, scenario, "pan-all"))
                .{ .origin = .{ @intFromFloat(t * 2_000), 0 }, .scale = fit, .zoom = 1 }
            else if (std.mem.eql(u8, scenario, "pan-4x"))
                .{ .origin = .{ 600_000 + @as(i64, @intFromFloat(t * 1_000)), 600_000 }, .scale = 4 * fit, .zoom = 4 }
            else if (std.mem.eql(u8, scenario, "empty"))
                // Beside the batch: every row is culled, what each band pays to skip them all.
                .{ .origin = .{ -10_000_000 - @as(i64, @intFromFloat(t * 1_000)), 0 }, .scale = 4 * fit, .zoom = 4 }
            else
                // From all of it to 8x, geometrically, about the centre.
                zoomed(fit * std.math.pow(f32, 8, t / @as(f32, @floatFromInt(frames))), wf, hf, world_w);
            rows[0] = .{ .instances = &shapes, .camera = cam, .ranges = &all, .palette = &palette };
            const job: Job = .{ .fb = &fb, .list = &list, .atlas = atlas, .bin = if (walk) null else &bin };
            counted.store(0, .monotonic);
            const t0 = now();
            // The bin is built on the caller's thread before the bands, as `sw.Setup.draw`
            // builds it, and counted with them.
            if (!walk) {
                const fd = instructionCounter();
                const before = readCounter(fd);
                bin.build(&list, 0, 1, fb.all(), threads);
                _ = counted.fetchAdd(readCounter(fd) - before, .monotonic);
            }
            pool.run(threads, &job, Job.band);
            samples[f] = now() - t0;
            insns[f] = counted.load(.monotonic);
        }
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));
        std.mem.sort(u64, insns, {}, std.sort.asc(u64));
        const med = samples[frames / 2];
        try w.print("{s:<10} {d:>7} {d:>8.2} {d:>10.2} {d:>8.2} {d:>12} {d:>8.0}\n", .{ scenario, threads, ms(samples[0]), ms(med), ms(samples[frames * 9 / 10]), insns[frames / 2], 1e9 / @as(f64, @floatFromInt(med)) });
        try w.flush();
    };
}

pub fn zoomed(scale: f32, wf: f32, hf: f32, world_w: f32) canvas.Camera {
    const cx = world_w / 2 - wf / 2 / scale;
    const cy = world_w / 2 - hf / 2 / scale;
    return .{ .origin = .{ @intFromFloat(cx), @intFromFloat(cy) }, .scale = scale, .zoom = scale * world_w / wf };
}

/// Instructions retired by the drawing threads this frame.
var counted: std.atomic.Value(u64) = .init(0);
threadlocal var counter_fd: i32 = -1;

/// This thread's user-space instruction counter, opened on first use.
fn instructionCounter() i32 {
    if (counter_fd >= 0) return counter_fd;
    var attr: linux.perf_event_attr = .{ .type = .HARDWARE, .config = @backingInt(linux.PERF.COUNT.HW.INSTRUCTIONS) };
    attr.flags.exclude_kernel = true;
    attr.flags.exclude_hv = true;
    const rc = linux.perf_event_open(&attr, 0, -1, -1, 0);
    counter_fd = if (linux.errno(rc) == .SUCCESS) @intCast(rc) else -2;
    return counter_fd;
}

fn readCounter(fd: i32) u64 {
    if (fd < 0) return 0;
    var v: u64 = 0;
    _ = linux.read(fd, std.mem.asBytes(&v), 8);
    return v;
}

const Job = struct {
    fb: *sw.Framebuffer,
    list: *const DrawList,
    atlas: sw.Image,
    bin: ?*const sw.canvas.Bin,

    /// Band `k` of `n`: cleared, then the canvas, as `sw.Setup.draw` draws a frame.
    fn band(j: *const Job, k: u32, n: u32) void {
        const fd = instructionCounter();
        const before = readCounter(fd);
        const t: sw.Target = .{ .fb = j.fb, .scissor = sw.tile(j.fb, k, n) };
        j.fb.fill(t.scissor, .rgb(13, 13, 15));
        sw.canvas.drawBinned(t, j.list, 0, 1, j.atlas, j.bin);
        _ = counted.fetchAdd(readCounter(fd) - before, .monotonic);
    }
};

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
