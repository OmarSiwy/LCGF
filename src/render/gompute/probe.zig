//! Measurements of the Gompute back end on CUDA device 0 (src/render/gompute/DECISION.md):
//!
//!     gompute-probe readback    read-back of a cleared frame into a CPU framebuffer at three
//!                               sizes, into pageable and into pinned memory (median of 50)
const std = @import("std");
const lcgr = @import("lcgr");
const gc = @import("gompute.zig");
const sw = lcgr.render_sw;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const mode = std.meta.stringToEnum(enum { readback }, args.next() orelse "readback") orelse return error.Usage;
    var buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &out.interface;

    switch (mode) {
        .readback => for ([_][2]u32{ .{ 800, 600 }, .{ 1920, 1080 }, .{ 3840, 2160 } }) |size| {
            const len = sw.Framebuffer.len(size[0], size[1]);
            var dev = try gc.Device(.cuda).init(0, .{ .width = size[0], .height = size[1], .stride = @intCast(lcgr.simd.padded(size[0])), .quads = 1, .images = 1, .texels = 1 });
            defer dev.deinit();
            const pageable = try gpa.alloc(u32, len);
            defer gpa.free(pageable);
            const pinned_bytes = try dev.raster_k.allocPinned(len * 4);
            defer dev.raster_k.freePinned(pinned_bytes);
            const pinned: []u32 = @alignCast(std.mem.bytesAsSlice(u32, pinned_bytes));
            var us: [2]u64 = undefined;
            for ([_][]u32{ pageable, pinned }, &us) |px, *median| {
                var times: [50]u64 = undefined;
                for (&times) |*ns| {
                    try dev.clear(0xff00_00ff);
                    try dev.synchronize();
                    var fb = sw.Framebuffer.init(px, size[0], size[1], .rgba8);
                    const t0 = std.Io.Timestamp.now(io, .awake);
                    try dev.present(&fb);
                    ns.* = @intCast(t0.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds());
                    if (fb.at(size[0] - 1, size[1] - 1).r != 0xff) return error.WrongPixels;
                }
                std.mem.sort(u64, &times, {}, std.sort.asc(u64));
                median.* = times[times.len / 2] / 1000;
            }
            const mb = @as(f64, @floatFromInt(len * 4)) / 1e6;
            try w.print("readback {d}x{d} ({d:.1} MB): pageable {d} us ({d:.1} GB/s), pinned {d} us ({d:.1} GB/s)\n", .{
                size[0], size[1], mb, us[0], mb * 1e3 / @as(f64, @floatFromInt(us[0])), us[1], mb * 1e3 / @as(f64, @floatFromInt(us[1])),
            });
            try w.flush();
        },
    }
}
