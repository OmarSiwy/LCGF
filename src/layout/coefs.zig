//! coefs: resolve's per-node coefficients, precomputed in one SIMD pass so the top-down sweep
//! reads a few rows instead of fourteen columns. Tier 0: the table is carved from the caller's
//! buffer like `Tree`.
//!
//!   fit(axis)        reverse  natural sizes (layout.zig)
//!   coefs(axis)      SIMD     k0, k1, k2, room and the parent terms, from fit's results
//!   resolveK(axis)   forward  s = k0 + k1 * inner + k2 * max(inner - taken, 0), shrink, clamp

const std = @import("std");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Axis = types.Axis;

const W = simd.lanes;
const F = simd.F;

pub const Coefs = struct {
    cap: u32,
    c: Columns,

    /// Rewritten by `coefs` for one axis at a time; both axes have their own rows so the x
    /// values survive until `resolveK(.x)` and the y values are written after `fit(.y)`.
    pub const Columns = struct {
        k0: [2][]f32,
        k1: [2][]f32,
        k2: [2][]f32,
        /// `main[p] * (taken[p] - nat[i])`: what the parent's other children take, for shrink.
        room: [2][]f32,
        /// `shrink * flow`: 1 for a node that gives way, else 0. Same on both axes.
        cut: []f32,
        /// Parent terms, per node as a parent: `pad_lo + pad_hi` and `fit + gap_total`.
        pad: [2][]f32,
        taken: [2][]f32,
    };

    /// Carves every column for `cap` nodes, `simd.rows(cap)` rows each. With a counting carver
    /// this sizes the buffer instead.
    pub fn init(carver: *mem.Carver, cap: u32) Coefs {
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }
};

/// Gathers `col[idx[l]]` into a vector. Rows are independent, so the loads overlap.
inline fn gather(col: []const f32, idx: simd.U) F {
    var v: F = undefined;
    inline for (0..W) |l| v[l] = col[idx[l]];
    return v;
}

/// SIMD. Fills one axis of `k` from the tree's inputs and `fit`'s results. Call after
/// `layout.fit(t, axis)`, before `resolveK`. Padding rows read parent 0 and are never used.
pub fn coefs(t: *const Tree, k: *Coefs, axis: Axis) void {
    std.debug.assert(t.len <= k.cap);
    const a = @backingInt(axis);
    const c = &t.c;
    const one = simd.f(1);
    const zero = simd.f(0);
    const n = simd.padded(t.len);
    var i: usize = 0;
    // Parent terms first: the gathers below read them for any parent row.
    while (i < n) : (i += W) {
        simd.storeF(k.c.pad[a], i, simd.loadF(c.pad_lo[a], i) + simd.loadF(c.pad_hi[a], i));
        simd.storeF(k.c.taken[a], i, simd.loadF(c.fit[a], i) + simd.loadF(c.gap_total, i));
    }
    i = 0;
    while (i < n) : (i += W) {
        // Padding rows hold stale parents; clamp them to a real row.
        const p = @min(simd.loadU(c.parent, i), simd.u(t.len -| 1));
        const main = gather(c.main[a], p);
        const grow_inv = gather(c.grow_inv[a], p);
        const taken = gather(k.c.taken[a], p);
        const nat = simd.loadF(c.nat[a], i);
        const grow = simd.loadF(c.grow[a], i);
        const pct = simd.loadF(c.pct[a], i);
        const fl = simd.loadF(c.flow, i);
        // The same algebra as layout.resolve, one vector of children at a time.
        const has_pct = @select(f32, pct > zero, one, zero);
        const keep = one - has_pct;
        const across = (one - main) * @select(f32, grow > zero, one, zero);
        simd.storeF(k.c.k0[a], i, nat * keep * (one - fl * across));
        simd.storeF(k.c.k1[a], i, has_pct * pct + keep * fl * across);
        simd.storeF(k.c.k2[a], i, keep * fl * main * grow * grow_inv);
        simd.storeF(k.c.room[a], i, main * (taken - nat));
        simd.storeF(k.c.cut, i, simd.loadF(c.shrink, i) * fl);
    }
}

/// Top-down: final size of every node on one axis, from the coefficients of `coefs`. One
/// forward sweep; the same sizes as `layout.resolve`.
pub fn resolveK(t: *Tree, k: *const Coefs, axis: Axis, viewport: f32) void {
    const a = @backingInt(axis);
    if (t.len == 0) return;
    const parent = t.c.parent;
    const size = t.c.size[a];
    const used = t.c.used[a];
    const min = t.c.min[a];
    const max = t.c.max[a];
    const flow = t.c.flow;
    const k0 = k.c.k0[a];
    const k1 = k.c.k1[a];
    const k2 = k.c.k2[a];
    const room_ = k.c.room[a];
    const cut = k.c.cut;
    const pad = k.c.pad[a];
    const taken = k.c.taken[a];

    size[0] = viewport;
    for (1..t.len) |i| {
        const p = parent[i];
        const inner = @max(size[p] - pad[p], 0);
        var s = k0[i] + k1[i] * inner + k2[i] * @max(inner - taken[p], 0);
        const room = @max(inner - room_[i], 0);
        s -= cut[i] * @max(s - room, 0);
        s = @min(@max(s, min[i]), max[i]);
        size[i] = s;
        used[p] += s * flow[i];
    }
}

const testing = std.testing;
const layout = @import("layout.zig");
const check = @import("check.zig");

test "resolveK: the same sizes and used totals as the prototype's resolve on random trees" {
    var raw: [768 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 1000);
    var k = Coefs.init(&carver, 1000);
    var prng: std.Random.DefaultPrng = .init(0xc0ef);
    var want: [1000]f32 = undefined;
    var want_used: [1000]f32 = undefined;
    for (0..200) |_| {
        check.randomTree(&t, prng.random(), 1 + prng.random().uintLessThan(u32, t.cap));
        layout.prepare(&t);
        for ([2]Axis{ .x, .y }, [2]f32{ 1280, 800 }) |axis, vp| {
            const a = @backingInt(axis);
            layout.fit(&t, axis);
            check.resolveRef(&t, axis, vp);
            @memcpy(want[0..t.len], t.c.size[a][0..t.len]);
            @memcpy(want_used[0..t.len], t.c.used[a][0..t.len]);
            @memset(t.c.used[a], 0);
            coefs(&t, &k, axis);
            resolveK(&t, &k, axis, vp);
            try testing.expect(check.maxDiff(want[0..t.len], t.c.size[a], t.len) <= check.tolerance);
            try testing.expect(check.maxDiff(want_used[0..t.len], t.c.used[a], t.len) <= check.tolerance);
        }
    }
}

test "coefs: a px child, a filling child and a percentage child of one row" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 8);
    var k = Coefs.init(&carver, 8);
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(300), .px(50) }, .pad = .{ 5, 0, 5, 0 } });
    const px = t.push(root, .none, &.{ .size = .{ .px(40), .fit } });
    const fill = t.push(root, .none, &.{ .size = .{ .fill, .fill } });
    const half = t.push(root, .none, &.{ .size = .{ .pct(0.5), .fit }, .shrink = true });
    t.seal(root);
    layout.prepare(&t);
    layout.fit(&t, .x);
    coefs(&t, &k, .x);
    // px: its natural 40 and nothing else; fill: its share of the free space; half: half of inner.
    try testing.expectEqual(40, k.c.k0[0][px]);
    try testing.expectEqual(0, k.c.k1[0][px]);
    try testing.expectEqual(0, k.c.k2[0][px]);
    try testing.expectEqual(1, k.c.k2[0][fill]);
    try testing.expectEqual(0.5, k.c.k1[0][half]);
    try testing.expectEqual(0, k.c.k0[0][half]);
    try testing.expectEqual(1, k.c.cut[half]);
    try testing.expectEqual(10, k.c.pad[0][root]);
    resolveK(&t, &k, .x, 300);
    try testing.expectEqual(40, t.c.size[0][px]);
    try testing.expectEqual(290 - 40, t.c.size[0][fill]);
    try testing.expectEqual(145, t.c.size[0][half]);
    // Across a row, fill stretches to the inner height.
    layout.fit(&t, .y);
    coefs(&t, &k, .y);
    resolveK(&t, &k, .y, 50);
    try testing.expectEqual(50, t.c.size[1][fill]);
}
