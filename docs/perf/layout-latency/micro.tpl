const std = @import("std");
const lcgr = @import("lcgr");
const Tree = lcgr.tree.Tree;
const L = lcgr.layout;
const K = lcgr.coefs;
const linux = std.os.linux;
fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
var raw: [8 << 20]u8 align(64) = undefined;
pub fn main() !void {
    var carver: lcgr.mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 4096);
    var k = K.Coefs.init(&carver, 4096);
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
    var best: [2]u64 = .{ std.math.maxInt(u64), std.math.maxInt(u64) };
    var sum: [2]u64 = .{ 0, 0 };
    const reps = 4000;
    for (0..reps) |_| {
        inline for (0..2) |v| {
            L.prepare(&t);
            L.fit(&t, .x);
            L.fit(&t, .y);
            K.coefs(&t, &k, .x);
            const t0 = now();
            if (v == 0) {
                K.resolveK(&t, &k, .x, 1280);
            } else {
                variant(&t, &k);
            }
            const d = now() - t0;
            best[v] = @min(best[v], d);
            sum[v] += d;
        }
    }
    std.debug.print("nodes={d} old min {d:.1} us mean {d:.1} | new min {d:.1} us mean {d:.1}\n", .{ t.len, @as(f64, @floatFromInt(best[0])) / 1000, @as(f64, @floatFromInt(sum[0] / reps)) / 1000, @as(f64, @floatFromInt(best[1])) / 1000, @as(f64, @floatFromInt(sum[1] / reps)) / 1000 });
}

fn variant(t: *Tree, k: *const K.Coefs) void {
    const a = 0;
    const size = t.c.size[a];
    const used = t.c.used[a];
    const child = k.c.child[a];
    const parent_row = k.c.parent[a];
    size[0] = 1280;
    for (child[1..t.len], 1..) |r, i| {
        const p = r.parent;
        const pr = parent_row[p];
        const inner = @max(size[p] - pr.pad, 0);
        var s = r.k0 + r.k1 * inner + r.k2 * @max(inner - pr.taken, 0);
        s -= @max(s - @max(inner - r.room, 0), 0);
        s = @min(@max(s, r.min), r.max);
        size[i] = s;
        VARIANT
    }
}
