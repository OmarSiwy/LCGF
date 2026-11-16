//! Times layout of each example comptime UI three ways: the runtime tree rebuilt every frame
//! (`Tree.push`, then `layout.run`), the runtime tree's `layout.run` alone, and the comptime front
//! end (`ct_layout.Layout.run` over read-only tables, which needs no rebuild).
//! `zig build ct-layout-bench` (ReleaseFast). Its own module root, importing the package as `lcgr`.
//! Prints the median of 15 batches, each the mean of 2,000 frames, in nanoseconds per frame.

const std = @import("std");
const lcgr = @import("lcgr");
const examples = lcgr.ct_examples;

const batches = 15;
const frames = 2000;

fn pushAll(t: anytype, comptime s: lcgr.spec.Spec, parent: u32) void {
    const id: lcgr.types.Id = if (s.id) |name| .hash(name) else .none;
    const i = t.push(parent, id, &s.style);
    inline for (s.children) |c| pushAll(t, c, i);
    t.seal(i);
}

fn median(xs: *[batches]u64) u64 {
    std.mem.sort(u64, xs, {}, std.sort.asc(u64));
    return xs[batches / 2];
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &out.interface;
    try w.print("{s:<10} {s:>5} {s:>14} {s:>14} {s:>12}\n", .{ "example", "nodes", "push+layout ns", "rt layout ns", "comptime ns" });
    const buf = try init.gpa.alignedAlloc(u8, .fromByteUnits(lcgr.mem.column_align), 1 << 20);
    defer init.gpa.free(buf);
    inline for (examples.all) |e| if (comptime !std.mem.eql(u8, e.name, "custom")) {
        const L = lcgr.ct_layout.Layout(e.spec, e.options);
        const n = L.Cols.node_count;
        // A run-time viewport, so the optimizer cannot fold a layout whose inputs are all
        // compile-time constants.
        var vp: [2]f32 = e.options.viewport orelse .{ 800, 600 };
        std.mem.doNotOptimizeAway(&vp);
        var rt: [batches]u64 = undefined;
        var lo: [batches]u64 = undefined;
        var ct: [batches]u64 = undefined;
        var carver: lcgr.mem.Carver = .{ .buf = buf };
        var t = lcgr.tree.Tree.init(&carver, n);
        var tx = lcgr.texts.Texts.init(&carver, 1);
        var scratch: L.Scratch = undefined;
        var ram: L.Cols.Dynamic = undefined;
        for (&rt, &lo, &ct) |*r, *l, *c| {
            const t0 = std.Io.Timestamp.now(io, .awake);
            for (0..frames) |_| {
                t.reset();
                pushAll(&t, e.spec, 0);
                lcgr.layout.run(&t, &tx, vp);
                std.mem.doNotOptimizeAway(&t);
            }
            const t1 = std.Io.Timestamp.now(io, .awake);
            for (0..frames) |_| {
                L.run(&scratch, &ram, vp);
                std.mem.doNotOptimizeAway(&ram);
            }
            const t2 = std.Io.Timestamp.now(io, .awake);
            for (0..frames) |_| {
                lcgr.layout.run(&t, &tx, vp);
                std.mem.doNotOptimizeAway(&t);
            }
            const t3 = std.Io.Timestamp.now(io, .awake);
            r.* = @intCast(@divTrunc(t0.durationTo(t1).toNanoseconds(), frames));
            c.* = @intCast(@divTrunc(t1.durationTo(t2).toNanoseconds(), frames));
            l.* = @intCast(@divTrunc(t2.durationTo(t3).toNanoseconds(), frames));
        }
        try w.print("{s:<10} {d:>5} {d:>14} {d:>14} {d:>12}\n", .{ e.name, n, median(&rt), median(&lo), median(&ct) });
    };
    try w.flush();
}
