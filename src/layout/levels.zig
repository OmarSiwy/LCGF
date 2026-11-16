//! levels: a level-order index derived from the depth-first tree, so resolve sweeps one level
//! at a time with SIMD instead of following the parent link row by row. The tree stays in
//! depth-first order (subtree ranges [i, end[i]) need it); only the index is level-ordered, and
//! the sweep gathers from and scatters to the tree's own columns. Tier 0: the table is carved
//! from the caller's buffer like `Tree`. Same sizes and `used` as coefs.coefs + coefs.resolveK,
//! bit for bit.
//!
//!   build              forward  depth, counting sort by depth: the index, once per frame
//!   resolve(axis)      SIMD     per level: coefs.coefs and coefs.resolveK fused
//!
//! Children of one level are independent, so the loads of a vector overlap instead of waiting
//! on the parent chain (docs/CHECKS.md: resolve is latency-bound at about 9 ns per node).
//! Within a level, ranks keep depth-first order, so the children of one parent are adjacent and
//! `used` sums them in the order resolveK does.
//!
//! Place stays depth-first (coefs.placeRows, coefs.placeK): its cursor is a running sum over
//! siblings, and a level-order place (cursors in one forward sweep, then positions per level)
//! measured 25 us against placeK's 17 us on the benchmark's shape. Numbers:
//! docs/perf/layout-latency/micro4.zig and README.md.

const std = @import("std");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Axis = types.Axis;
const inf = types.inf;

const W = simd.lanes;
const F = simd.F;
const U = simd.U;

pub const Levels = struct {
    cap: u32,
    /// Levels in the last `build`: level d is ranks [start[d], start[d + 1]).
    count: u32 = 0,
    c: Columns,

    pub const Columns = struct {
        /// Rank -> row. Every node of depth d before any of depth d + 1, depth-first order within
        /// a level. Ranks from `len` to `len + lanes` hold row `len` (padding the tree owns), so
        /// a level's last vector may run past the level's end.
        order: []u32,
        /// Rank -> parent row of `order`. 0 for the root and the padding ranks.
        parent: []u32,
        /// Level -> first rank; `count + 1` entries.
        start: []u32,
        /// Row -> depth. Scratch of `build`.
        depth: []u32,
    };

    /// Carves every column for `cap` nodes, `simd.rows(cap)` rows each. With a counting carver
    /// this sizes the buffer instead.
    pub fn init(carver: *mem.Carver, cap: u32) Levels {
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }
};

/// Builds the level-order index of `t`. Call once per frame after the tree is built; resolve on
/// both axes shares it.
pub fn build(t: *const Tree, lv: *Levels) void {
    const n = t.len;
    std.debug.assert(n <= lv.cap);
    if (n == 0) return;
    const parent = t.c.parent;
    const depth = lv.c.depth;
    const start = lv.c.start;
    // Counting sort with the counts one slot up, so the scatter's cursors end as the starts:
    // count of depth d at start[d + 2], prefix sums, then start[d + 1] advances from the first
    // rank of level d to the first of level d + 1. rows(cap) >= n + 2 for every lane count.
    @memset(start[0 .. n + 2], 0);
    depth[0] = 0;
    start[2] = 1;
    var levels: u32 = 1;
    for (1..n) |i| {
        const d = depth[parent[i]] + 1;
        depth[i] = d;
        start[d + 2] += 1;
        levels = @max(levels, d + 1);
    }
    for (2..levels + 1) |d| start[d] += start[d - 1];
    const order = lv.c.order;
    const lparent = lv.c.parent;
    for (0..n) |i| {
        const j = start[depth[i] + 1];
        start[depth[i] + 1] = j + 1;
        order[j] = @intCast(i);
        lparent[j] = parent[i];
    }
    lparent[0] = 0;
    @memset(order[n..][0..W], n);
    @memset(lparent[n..][0..W], 0);
    lv.count = levels;
}

/// Gathers `col[idx[l]]` into a vector. Rows are independent, so the loads overlap.
inline fn gather(col: []const f32, idx: U) F {
    var v: F = undefined;
    inline for (0..W) |l| v[l] = col[idx[l]];
    return v;
}

inline fn scatter(col: []f32, idx: U, v: F) void {
    inline for (0..W) |l| col[idx[l]] = v[l];
}

/// SIMD per level. Final size of every node on one axis: coefs.coefs and coefs.resolveK in one
/// sweep, the same algebra in the same order. Call after `layout.fit(t, axis)` and `build`;
/// `used` must be zero (layout.prepare clears it).
pub fn resolve(t: *Tree, lv: *const Levels, axis: Axis, viewport: f32) void {
    const a = @backingInt(axis);
    if (t.len == 0) return;
    const c = &t.c;
    const one = simd.f(1);
    const zero = simd.f(0);
    const size = c.size[a];
    const used = c.used[a];
    size[0] = viewport;
    for (1..lv.count) |d| {
        const end = lv.c.start[d + 1];
        var j: usize = lv.c.start[d];
        // The last vector runs into the next level (or the padding ranks). Its extra lanes
        // write sizes that the next level rewrites, and add nothing to `used`.
        while (j < end) : (j += W) {
            const i = simd.loadU(lv.c.order, j);
            const p = simd.loadU(lv.c.parent, j);
            // Parent side, as coefs gathers it and resolveK reads its Parent row.
            const main = gather(c.main[a], p);
            const grow_inv = gather(c.grow_inv[a], p);
            const taken = gather(c.fit[a], p) + gather(c.gap_total, p);
            const pad = gather(c.pad_lo[a], p) + gather(c.pad_hi[a], p);
            // Child side: coefs' Child row.
            const nat = gather(c.nat[a], i);
            const grow = gather(c.grow[a], i);
            const pct = gather(c.pct[a], i);
            const fl = gather(c.flow, i);
            const has_pct = @select(f32, pct >= zero, one, zero);
            const keep = one - has_pct;
            const across = (one - main) * @select(f32, grow > zero, one, zero);
            const k0 = nat * keep * (one - fl * across);
            const k1 = has_pct * pct + keep * fl * across;
            const k2 = keep * fl * main * grow * grow_inv;
            const cut = (gather(c.shrink, i) * fl) > zero;
            const room = @select(f32, cut, main * (taken - nat), simd.f(-inf));
            // resolveK's step.
            const inner = @max(gather(size, p) - pad, zero);
            var s = k0 + k1 * inner + k2 * @max(inner - taken, zero);
            s -= @max(s - @max(inner - room, zero), zero);
            s = @min(@max(s, gather(c.min[a], i)), gather(c.max[a], i));
            scatter(size, i, s);
            const in_level = simd.iota + simd.u(@intCast(j)) < simd.u(end);
            const u = @select(f32, in_level, s * fl, zero);
            inline for (0..W) |l| used[p[l]] += u[l];
        }
    }
}

const testing = std.testing;
const layout = @import("layout.zig");
const check = @import("check.zig");
const coefs = @import("coefs.zig");

test "build: every node once, level by level, depth-first within a level" {
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 16);
    var lv = Levels.init(&carver, 16);
    // root(a(b, c(d)), e(f))
    const root = t.push(0, .none, &.{});
    const a = t.push(root, .none, &.{});
    _ = t.push(a, .none, &.{});
    const cc = t.push(a, .none, &.{});
    _ = t.push(cc, .none, &.{});
    t.seal(cc);
    t.seal(a);
    const e = t.push(root, .none, &.{});
    _ = t.push(e, .none, &.{});
    t.seal(e);
    t.seal(root);
    build(&t, &lv);
    try testing.expectEqual(4, lv.count);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 5, 2, 3, 6, 4 }, lv.c.order[0..7]);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 1, 1, 5, 3 }, lv.c.parent[0..7]);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 3, 6, 7 }, lv.c.start[0..5]);
}

test "resolve: coefs.resolveK's sizes and used, and so placeK's positions, bit for bit, on random trees" {
    var raw: [1024 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 1000);
    var k = coefs.Coefs.init(&carver, 1000);
    var lv = Levels.init(&carver, 1000);
    var prng: std.Random.DefaultPrng = .init(0x1e7e1);
    var want: [6][1000]f32 = undefined;
    for (0..200) |_| {
        check.randomTree(&t, prng.random(), 1 + prng.random().uintLessThan(u32, t.cap));
        const n = t.len;
        // Reference: the depth-first passes.
        layout.prepare(&t);
        for ([2]Axis{ .x, .y }, [2]f32{ 1280, 800 }) |axis, vp| {
            layout.fit(&t, axis);
            coefs.coefs(&t, &k, axis);
            coefs.resolveK(&t, &k, axis, vp);
        }
        coefs.placeRows(&t, &k);
        coefs.placeK(&t, &k);
        for (0..2) |a| {
            @memcpy(want[a][0..n], t.c.size[a][0..n]);
            @memcpy(want[2 + a][0..n], t.c.used[a][0..n]);
            @memcpy(want[4 + a][0..n], t.c.pos[a][0..n]);
        }
        var want_cursor: [1000]f32 = undefined;
        @memcpy(want_cursor[0..n], t.c.cursor[0..n]);
        // The level-order resolve from the same inputs.
        layout.prepare(&t);
        for (0..2) |a| {
            @memset(t.c.size[a], std.math.nan(f32));
            @memset(t.c.pos[a], std.math.nan(f32));
        }
        build(&t, &lv);
        for ([2]Axis{ .x, .y }, [2]f32{ 1280, 800 }) |axis, vp| {
            layout.fit(&t, axis);
            resolve(&t, &lv, axis, vp);
        }
        coefs.placeRows(&t, &k);
        coefs.placeK(&t, &k);
        for (0..2) |a| {
            try testing.expectEqualSlices(u32, @ptrCast(want[a][0..n]), @ptrCast(t.c.size[a][0..n]));
            try testing.expectEqualSlices(u32, @ptrCast(want[2 + a][0..n]), @ptrCast(t.c.used[a][0..n]));
            try testing.expectEqualSlices(u32, @ptrCast(want[4 + a][0..n]), @ptrCast(t.c.pos[a][0..n]));
        }
        try testing.expectEqualSlices(u32, @ptrCast(want_cursor[0..n]), @ptrCast(t.c.cursor[0..n]));
    }
}
