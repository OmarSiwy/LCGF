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
    L.prepare(&t);
    L.fit(&t, .x);
    K.coefs(&t, &k, .x);
    var best: [4]u64 = @splat(std.math.maxInt(u64));
    for (0..4000) |_| {
        inline for (.{ 0, 8, 16, 32 }, 0..) |dist, v| {
            const t0 = now();
            res(&t, &k, dist);
            best[v] = @min(best[v], now() - t0);
        }
    }
    K.resolveK(&t, &k, .x, 1280);
    L.fit(&t, .y);
    K.coefs(&t, &k, .y);
    K.resolveK(&t, &k, .y, 8000);
    K.placeRows(&t, &k);
    var pb: [4]u64 = @splat(std.math.maxInt(u64));
    for (0..4000) |_| {
        inline for (.{ 0, 8, 16, 32 }, 0..) |dist, v| {
            @memset(t.c.cursor, 0);
            const t0 = now();
            pl(&t, &k, dist);
            pb[v] = @min(pb[v], now() - t0);
        }
    }
    std.debug.print("placeK no prefetch {d:.1} | d8 {d:.1} | d16 {d:.1} | d32 {d:.1} us\n", .{ us(pb[0]), us(pb[1]), us(pb[2]), us(pb[3]) });
    std.debug.print("resolveK no prefetch {d:.1} | d8 {d:.1} | d16 {d:.1} | d32 {d:.1} us\n", .{ us(best[0]), us(best[1]), us(best[2]), us(best[3]) });
}
fn us(x: u64) f64 {
    return @as(f64, @floatFromInt(x)) / 1000;
}
noinline fn res(t: *Tree, k: *const K.Coefs, comptime dist: usize) void {
    const size = t.c.size[0];
    const used = t.c.used[0];
    const child = k.c.child[0];
    const parent_row = k.c.parent[0];
    size[0] = 1280;
    for (child[1..t.len], 1..) |r, i| {
        if (dist > 0) {
            // child has padded rows: i + dist may pass len but stays inside cap + lanes? clamp
            const q = child[@min(i + dist, t.len - 1)].parent;
            @prefetch(&parent_row[q], .{});
            @prefetch(&size[q], .{});
            @prefetch(&used[q], .{ .rw = .write });
        }
        const p = r.parent;
        const pr = parent_row[p];
        const inner = @max(size[p] - pr.pad, 0);
        var s = r.k0 + r.k1 * inner + r.k2 * @max(inner - pr.taken, 0);
        s -= @max(s - @max(inner - r.room, 0), 0);
        s = @min(@max(s, r.min), r.max);
        size[i] = s;
        used[p] += s * r.flow;
    }
}

noinline fn pl(t: *Tree, k: *const K.Coefs, comptime dist: usize) void {
    const parent = t.c.parent;
    const pos = t.c.pos;
    const size = t.c.size;
    const offset = t.c.offset;
    const cursor = t.c.cursor;
    const flow = t.c.flow;
    const rows = k.c.place;
    pos[0][0] = 0;
    pos[1][0] = 0;
    for (1..t.len) |i| {
        if (dist > 0) {
            const q = parent[@min(i + dist, t.len - 1)];
            @prefetch(&rows[q], .{});
            @prefetch(&pos[0][q], .{});
            @prefetch(&pos[1][q], .{});
            @prefetch(&cursor[q], .{ .rw = .write });
        }
        const p = parent[i];
        const r = rows[p];
        const fl = flow[i];
        const along = cursor[p];
        inline for (0..2) |a| {
            const across = @max(r.inner[a] - size[a][i], 0) * r.align_cross;
            const in_flow = across + r.main[a] * (r.lead[a] + along - across);
            pos[a][i] = pos[a][p] + r.origin[a] + fl * in_flow + offset[a][i];
        }
        const step = size[0][i] * r.main[0] + size[1][i] * r.main[1];
        cursor[p] += (step + r.gap) * fl;
    }
}
