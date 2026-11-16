//! Layout benchmark for static UIs. Times each example comptime UI, and two longer static lists,
//! three ways, every label showing 12 bytes measured with `Mono`: the runtime tree rebuilt every
//! frame (`Tree.push`, then measure and `layout.run`), the runtime tree's measure and
//! `layout.run` alone, and the comptime front end (`ct_layout.Layout.run` over read-only tables,
//! which needs no rebuild).
//! `zig build ct-layout-bench` (ReleaseFast). Its own module root, importing the package as `lcgr`.
//! Prints the median of 15 batches, each the mean of 2,000 frames, in nanoseconds per frame.

const std = @import("std");
const lcgr = @import("lcgr");
const examples = lcgr.ct_examples;

const batches = 15;
const frames = 2000;

/// Every label shows 12 bytes of text.
const label_bytes = 12;
const font: lcgr.protocol.Mono = .{};

/// `Tree.push` per node and `Texts.push` per label, as `Frame.text` does.
fn pushAll(t: anytype, tx: *lcgr.texts.Texts, comptime s: lcgr.spec.Spec, parent: u32) void {
    const id: lcgr.types.Id = if (s.id) |name| .hash(name) else .none;
    const i = t.push(parent, id, &s.style);
    if (s.kind == .label) t.c.text[i] = tx.push(i, .{ .start = 0, .bytes = label_bytes }, &.{});
    inline for (s.children) |c| pushAll(t, tx, c, i);
    t.seal(i);
}

/// A static list: a column of `k` rows, each a label and a bar: 3k + 1 nodes, fixed-height rows
/// that fill the width.
fn list(comptime k: usize) lcgr.spec.Spec {
    @setEvalBranchQuota(1000 + 200 * k);
    const s = lcgr.spec;
    var kids: [k]s.Spec = undefined;
    for (&kids) |*r| r.* = s.row(.{ .gap = 4, .size = .{ .fill, .px(20) } }, .{ s.label(.x), s.col(.{ .size = .{ .fill, .px(8) } }, .{}) });
    return s.col(.{ .pad = @splat(4), .gap = 2 }, kids);
}

/// `list` without text: each row two bars. 3k + 1 nodes, no labels.
fn bars(comptime k: usize) lcgr.spec.Spec {
    @setEvalBranchQuota(1000 + 200 * k);
    const s = lcgr.spec;
    var kids: [k]s.Spec = undefined;
    for (&kids) |*r| r.* = s.row(.{ .gap = 4, .size = .{ .fill, .px(20) } }, .{ s.col(.{ .size = .{ .px(40), .px(8) } }, .{}), s.col(.{ .size = .{ .fill, .px(8) } }, .{}) });
    return s.col(.{ .pad = @splat(4), .gap = 2 }, kids);
}

const List = struct { x: f32 = 0 };
/// The examples, then two longer static lists.
const uis = examples.all ++ [_]examples.Example{
    .{ .name = "list-49", .State = List, .spec = list(16) },
    .{ .name = "list-193", .State = List, .spec = list(64) },
    .{ .name = "bars-49", .State = List, .spec = bars(16) },
};

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
    const buf = try init.gpa.alignedAlloc(u8, .fromByteUnits(lcgr.mem.column_align), 1 << 21);
    defer init.gpa.free(buf);
    inline for (uis) |e| if (comptime !std.mem.eql(u8, e.name, "custom")) {
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
        var tx = lcgr.texts.Texts.init(&carver, @max(L.label_count, 1));
        const spans: [L.label_count]lcgr.strings.Span = @splat(.{ .start = 0, .bytes = label_bytes });
        var scratch: L.Scratch = undefined;
        var ram: L.Cols.Dynamic = undefined;
        for (&rt, &lo, &ct) |*r, *l, *c| {
            const t0 = std.Io.Timestamp.now(io, .awake);
            for (0..frames) |_| {
                t.reset();
                tx.reset();
                pushAll(&t, &tx, e.spec, 0);
                font.measure(&tx);
                lcgr.layout.run(&t, &tx, vp);
                std.mem.doNotOptimizeAway(&t);
            }
            const t1 = std.Io.Timestamp.now(io, .awake);
            for (0..frames) |_| {
                L.run(&scratch, &ram, vp, &spans, font);
                std.mem.doNotOptimizeAway(&ram);
            }
            const t2 = std.Io.Timestamp.now(io, .awake);
            for (0..frames) |_| {
                font.measure(&tx);
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
    // Partial routines (C0164): the dashboard after one tile's text changes, laid out in full
    // against the routine for that field's dirty mask, and against the routine for the title
    // (above every fixed-size box: the whole tree).
    {
        const P = lcgr.ct_layout.Plain(examples.dash, .{});
        var vp: [2]f32 = .{ 400, 200 };
        std.mem.doNotOptimizeAway(&vp);
        const spans: [P.label_count]lcgr.strings.Span = @splat(.{ .start = 0, .bytes = label_bytes });
        var scratch: P.Scratch = undefined;
        var ram: P.Cols.Dynamic = undefined;
        P.run(&scratch, &ram, vp, &spans, font);
        var full: [batches]u64 = undefined;
        var tile: [batches]u64 = undefined;
        var title: [batches]u64 = undefined;
        for (&full, &tile, &title) |*f, *t, *h| {
            const t0 = std.Io.Timestamp.now(io, .awake);
            for (0..frames) |_| {
                P.run(&scratch, &ram, vp, &spans, font);
                std.mem.doNotOptimizeAway(&ram);
            }
            const t1 = std.Io.Timestamp.now(io, .awake);
            for (0..frames) |_| {
                P.relayout("a", &scratch, &ram, &spans, font);
                std.mem.doNotOptimizeAway(&ram);
            }
            const t2 = std.Io.Timestamp.now(io, .awake);
            for (0..frames) |_| {
                P.relayout("title", &scratch, &ram, &spans, font);
                std.mem.doNotOptimizeAway(&ram);
            }
            const t3 = std.Io.Timestamp.now(io, .awake);
            f.* = @intCast(@divTrunc(t0.durationTo(t1).toNanoseconds(), frames));
            t.* = @intCast(@divTrunc(t1.durationTo(t2).toNanoseconds(), frames));
            h.* = @intCast(@divTrunc(t2.durationTo(t3).toNanoseconds(), frames));
        }
        try w.print("dash ({d} nodes) partial relayout ns: full {d}, tile a {d}, title {d}\n", .{ P.Cols.node_count, median(&full), median(&tile), median(&title) });
    }
    try w.flush();
}
