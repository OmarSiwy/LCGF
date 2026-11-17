//! C0805: the three parent-ordered sweeps of src/draw/inherit.zig (opacity, transform, clip) on
//! the bench scene's tree shape (330 rows of 12 nodes, 3,961 rows), laid out once. Median of
//! 4,000 reps each. Build as docs/perf/build/push.zig, against the tree to measure.
const std = @import("std");
const lcgf = @import("lcgf");
const linux = std.os.linux;
fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
var raw: [8 << 20]u8 align(64) = undefined;

pub fn main() !void {
    var carver: lcgf.mem.Carver = .{ .buf = &raw };
    var t = lcgf.tree.Tree.init(&carver, 4096);
    var tx = lcgf.texts.Texts.init(&carver, 16);
    const root = t.push(0, .none, &.{ .size = .{ .px(1280), .px(8000) } });
    for (0..330) |_| {
        const row = t.push(root, .none, &.{ .dir = .x, .size = .{ .fill, .fit }, .gap = 6, .pad = @splat(2), .cross = .center });
        _ = t.push(row, .none, &.{ .size = .{ .px(80), .px(16) } });
        for (0..2) |_| {
            const b = t.push(row, .none, &.{ .pad = @splat(4), .clip = true, .radius = 4 });
            _ = t.push(b, .none, &.{ .size = .{ .px(40), .px(16) }, .opacity = 0.5 });
            t.seal(b);
        }
        const cb = t.push(row, .none, &.{ .dir = .x, .gap = 4 });
        _ = t.push(cb, .none, &.{ .size = .{ .px(16), .px(16) } });
        _ = t.push(cb, .none, &.{ .size = .{ .px(50), .px(16) } });
        t.seal(cb);
        const sl = t.push(row, .none, &.{ .size = .{ .px(120), .px(16) } });
        _ = t.push(sl, .none, &.{ .size = .{ .fill, .px(4) }, .transform = .{ 1, 0, 0, 1, 2, 0 } });
        t.seal(sl);
        _ = t.push(row, .none, &.{ .size = .{ .px(12), .px(12) } });
        t.seal(row);
    }
    t.seal(root);
    lcgf.layout.run(&t, &tx, .{ 1280, 8000 });
    const reps = 4000;
    var s: [3][reps]u64 = undefined;
    for (0..reps) |k| {
        inline for (0..3) |v| {
            const t0 = now();
            switch (v) {
                0 => lcgf.inherit.opacity(&t),
                1 => lcgf.inherit.transform(&t),
                else => lcgf.inherit.clip(&t),
            }
            s[v][k] = now() - t0;
        }
    }
    var sum: f32 = 0;
    for (0..t.len) |i| sum += t.c.alpha[i] + t.c.world[i][4] + t.c.clip_radii[i][0];
    for (&s, [_][]const u8{ "opacity", "transform", "clip" }) |*x, name| {
        std.mem.sort(u64, x, {}, std.sort.asc(u64));
        std.debug.print("{s:<10} median {d:.2} us\n", .{ name, @as(f64, @floatFromInt(x[reps / 2])) / 1000 });
    }
    std.debug.print("check {d}\n", .{sum});
}
