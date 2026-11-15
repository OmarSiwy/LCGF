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
    const n = t.len;
    var best: [4]u64 = @splat(std.math.maxInt(u64));
    const reps = 4000;
    for (0..reps) |_| {
        // 0: resolveK, DFS order
        var t0 = now();
        K.resolveK(&t, &k, .x, 1280);
        best[0] = @min(best[0], now() - t0);
        // 1: build level order (depth, counting sort, permuted SoA)
        t0 = now();
        const levels = permute(&t, &k);
        best[1] = @min(best[1], now() - t0);
        best_struct = @min(best_struct, structure_ns - t0);
        // 2: level-order resolve, SIMD per level, used by scalar scatter
        t0 = now();
        levelResolve(levels, true);
        best[2] = @min(best[2], now() - t0);
        t0 = now();
        levelResolve(levels, false);
        best[3] = @min(best[3], now() - t0);
    }
    // same sizes?
    var worst: f32 = 0;
    for (0..n) |j| worst = @max(worst, @abs(lsize[j] - t.c.size[0][order[j]]));
    std.debug.print("n={d} levels={d} resolveK {d:.1} us | permute {d:.1} us | level resolve {d:.1} us (no used: {d:.1}) | structure part {d:.1} us | maxdiff {d}\n", .{ n, nlev, us(best[0]), us(best[1]), us(best[2]), us(best[3]), us(best_struct), worst });
}
fn us(x: u64) f64 {
    return @as(f64, @floatFromInt(x)) / 1000;
}
const W = lcgr.simd.lanes;
const F = lcgr.simd.F;
const N = 4096 + 64;
var depth: [N]u32 = undefined;
var order: [N]u32 = undefined; // new -> old
var rank: [N]u32 = undefined; // old -> new
var count: [64]u32 = undefined;
var start: [65]u32 = undefined;
var nlev: u32 = 0;
var structure_ns: u64 = 0;
var best_struct: u64 = std.math.maxInt(u64);
var lpar: [N]u32 align(64) = undefined;
var lk0: [N]f32 align(64) = undefined;
var lk1: [N]f32 align(64) = undefined;
var lk2: [N]f32 align(64) = undefined;
var lroom: [N]f32 align(64) = undefined;
var lmin: [N]f32 align(64) = undefined;
var lmax: [N]f32 align(64) = undefined;
var lfl: [N]f32 align(64) = undefined;
var lpad: [N]f32 align(64) = undefined;
var ltaken: [N]f32 align(64) = undefined;
var lsize: [N]f32 align(64) = undefined;
var lused: [N]f32 align(64) = undefined;
fn permute(t: *const Tree, k: *const K.Coefs) u32 {
    const n = t.len;
    @memset(&count, 0);
    depth[0] = 0;
    count[0] = 1;
    for (1..n) |i| {
        depth[i] = depth[t.c.parent[i]] + 1;
        count[depth[i]] += 1;
    }
    var d: u32 = 0;
    start[0] = 0;
    while (count[d] != 0) : (d += 1) start[d + 1] = start[d] + count[d];
    nlev = d;
    var fill: [64]u32 = undefined;
    @memcpy(fill[0..d], start[0..d]);
    for (0..n) |i| {
        const j = fill[depth[i]];
        fill[depth[i]] += 1;
        order[j] = @intCast(i);
        rank[i] = j;
    }
    structure_ns = now();
    const ch = k.c.child[0];
    const pr = k.c.parent[0];
    for (0..n) |j| {
        const o = order[j];
        const r = ch[o];
        lpar[j] = rank[r.parent];
        lk0[j] = r.k0;
        lk1[j] = r.k1;
        lk2[j] = r.k2;
        lroom[j] = r.room;
        lmin[j] = r.min;
        lmax[j] = r.max;
        lfl[j] = r.flow;
        lpad[j] = pr[o].pad;
        ltaken[j] = pr[o].taken;
    }
    return n;
}
inline fn gather(col: []const f32, idx: lcgr.simd.U) F {
    var v: F = undefined;
    inline for (0..W) |l| v[l] = col[idx[l]];
    return v;
}
noinline fn levelResolve(n: u32, comptime with_used: bool) void {
    _ = n;
    lsize[0] = 1280;
    @memset(&lused, 0);
    const zero: F = @splat(0);
    for (1..nlev) |d| {
        var j: usize = start[d];
        const end = start[d + 1];
        while (j < end) : (j += W) {
            // the last vector of a level runs into the next level; its lanes are rewritten later
            const p: lcgr.simd.U = lpar[j..][0..W].*;
            const ps = gather(&lsize, p);
            const inner = @max(ps - gather(&lpad, p), zero);
            const k0: F = lk0[j..][0..W].*;
            const k1: F = lk1[j..][0..W].*;
            const k2: F = lk2[j..][0..W].*;
            var s = k0 + k1 * inner + k2 * @max(inner - gather(&ltaken, p), zero);
            const room: F = lroom[j..][0..W].*;
            s -= @max(s - @max(inner - room, zero), zero);
            s = @min(@max(s, @as(F, lmin[j..][0..W].*)), @as(F, lmax[j..][0..W].*));
            lsize[j..][0..W].* = s;
            if (with_used) {
                const fl: F = lfl[j..][0..W].*;
                const u = s * fl;
                inline for (0..W) |l| {
                    if (j + l < end) lused[p[l]] += u[l];
                }
            }
        }
    }
}
