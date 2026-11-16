//! C0849: resolve (both axes) + place per frame on the benchmark's tree shape, three ways:
//!   start   the lane's start: layout.resolve and layout.place of src/ at 99d3b1e^ (module lcgr_old)
//!   coefs   coefs + resolveK per axis, placeRows + placeK (the depth-first K form)
//!   levels  levels.build once, levels.resolve per axis, placeRows + placeK
//! fit runs untimed before each axis, as in micro.zig. Min and mean of 4,000 reps.
const std = @import("std");
const lcgr = @import("lcgr");
const old = @import("lcgr_old");
const linux = std.os.linux;
fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
var raw: [8 << 20]u8 align(64) = undefined;
var raw_old: [8 << 20]u8 align(64) = undefined;

fn scene(t: anytype) void {
    // The bench scene's shape: 330 rows of 11 nodes under a column.
    const root = t.push(0, .none, &.{ .size = .{ .px(1280), .px(8000) } });
    for (0..330) |_| {
        const row = t.push(root, .none, &.{ .dir = .x, .size = .{ .fill, .fit }, .gap = 6, .pad = @splat(2), .cross = .center });
        _ = t.push(row, .none, &.{ .size = .{ .px(80), .px(16) } });
        for (0..2) |_| {
            const b = t.push(row, .none, &.{ .pad = @splat(4) });
            _ = t.push(b, .none, &.{ .size = .{ .px(40), .px(16) } });
            t.seal(b);
        }
        const cb = t.push(row, .none, &.{ .dir = .x, .gap = 4 });
        _ = t.push(cb, .none, &.{ .size = .{ .px(16), .px(16) } });
        _ = t.push(cb, .none, &.{ .size = .{ .px(50), .px(16) } });
        t.seal(cb);
        const sl = t.push(row, .none, &.{ .size = .{ .px(120), .px(16) } });
        _ = t.push(sl, .none, &.{ .size = .{ .fill, .px(4) } });
        t.seal(sl);
        _ = t.push(row, .none, &.{ .size = .{ .px(12), .px(12) } });
        t.seal(row);
    }
    t.seal(root);
}

pub fn main() !void {
    var carver: lcgr.mem.Carver = .{ .buf = &raw };
    var t = lcgr.tree.Tree.init(&carver, 4096);
    var k = lcgr.coefs.Coefs.init(&carver, 4096);
    var lv = lcgr.levels.Levels.init(&carver, 4096);
    var carver_old: old.mem.Carver = .{ .buf = &raw_old };
    var ot = old.tree.Tree.init(&carver_old, 4096);
    scene(&t);
    scene(&ot);
    const L = lcgr.layout;
    const K = lcgr.coefs;
    const V = lcgr.levels;
    const OL = old.layout;
    const reps = 4000;
    var best: [3]u64 = @splat(std.math.maxInt(u64));
    var sum: [3]u64 = @splat(0);
    var d: u64 = 0;
    for (0..reps) |_| {
        inline for (0..3) |v| {
            switch (v) {
                0 => {
                    OL.prepare(&ot);
                    OL.fit(&ot, .x);
                    var t0 = now();
                    OL.resolve(&ot, .x, 1280);
                    d = now() - t0;
                    OL.fit(&ot, .y);
                    t0 = now();
                    OL.resolve(&ot, .y, 8000);
                    OL.place(&ot);
                    d += now() - t0;
                },
                1 => {
                    L.prepare(&t);
                    L.fit(&t, .x);
                    var t0 = now();
                    K.coefs(&t, &k, .x);
                    K.resolveK(&t, &k, .x, 1280);
                    d = now() - t0;
                    L.fit(&t, .y);
                    t0 = now();
                    K.coefs(&t, &k, .y);
                    K.resolveK(&t, &k, .y, 8000);
                    K.placeRows(&t, &k);
                    K.placeK(&t, &k);
                    d += now() - t0;
                },
                else => {
                    L.prepare(&t);
                    L.fit(&t, .x);
                    var t0 = now();
                    V.build(&t, &lv);
                    V.resolve(&t, &lv, .x, 1280);
                    d = now() - t0;
                    L.fit(&t, .y);
                    t0 = now();
                    V.resolve(&t, &lv, .y, 8000);
                    K.placeRows(&t, &k);
                    K.placeK(&t, &k);
                    d += now() - t0;
                },
            }
            best[v] = @min(best[v], d);
            sum[v] += d;
        }
    }
    // Same results: the level-order positions against the lane start's.
    var worst: f32 = 0;
    for (0..2) |a| for (0..t.len) |i| {
        worst = @max(worst, @abs(t.c.pos[a][i] - ot.c.pos[a][i]), @abs(t.c.size[a][i] - ot.c.size[a][i]));
    };
    const names = [_][]const u8{ "start", "coefs", "levels" };
    for (names, best, sum) |name, b, s| std.debug.print("{s:<7} min {d:6.1} us  mean {d:6.1} us  speedup(min) {d:.2}x\n", .{ name, us(b), us(s / reps), us(best[0]) / us(b) });
    std.debug.print("nodes={d} levels={d} max |pos|,|size| diff vs start {d}\n", .{ t.len, lv.count, worst });
}
fn us(x: u64) f64 {
    return @as(f64, @floatFromInt(x)) / 1000;
}
