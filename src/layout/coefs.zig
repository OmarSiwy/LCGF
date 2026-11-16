//! coefs: what the two top-down sweeps read, regrouped by a SIMD pass into one row per node, so
//! each sweep follows the parent link into two rows instead of a dozen columns (fewer streams
//! per loop: Andrew Kelley, Practical Data-Oriented Design). Tier 0: the table is carved from the
//! caller's buffer like `Tree`.
//!
//!   fit(axis)          reverse  natural sizes (layout.zig)
//!   coefs(axis)        SIMD     a Child and a Parent row per node for one axis
//!   resolveK(axis)     forward  s = k0 + k1 * inner + k2 * max(inner - taken, 0), shrink, clamp
//!   placeRows          SIMD     a Place row per node, from resolve's sizes
//!   placeK             forward  positions on both axes
//!
//! Level order (C0121, measured, not adopted as storage). Rows stay in depth-first order: the
//! subtree ranges [i, end[i]) that hit testing, paint, reuse and incremental layout rely on
//! exist only in that order. Stored level by level instead (every node of depth d before any of
//! depth d+1), the children of one level are independent, so resolve becomes a SIMD sweep per
//! level with the parent's size, pad and taken gathered lane by lane. Measured on the
//! benchmark's tree shape (3,961 nodes, 4 levels; scratch program, ReleaseFast, 8 lanes, one P
//! core, min of 4,000 reps, sizes bit-identical to resolveK):
//!
//!   resolveK(.x), depth-first rows                          33.8 us
//!   level-order resolve, SIMD per level, used scattered     10.5 us   (6.1 us without used)
//!   building the order each frame: depth, counting sort     13.5 us
//!   ... plus copying Child/Parent rows into level order     27.1 us   (40.6 us in all)
//!
//! With the copy, one axis costs 51 us against 34; the copy disappears if `coefs` writes each
//! row at its level-order rank (it already stores row by row), leaving 13.5 us of order, shared
//! by both axes and place, plus 10.5 us per sweep and a gather back to depth-first order. That
//! derived index, leaving the tree in depth-first order, is src/layout/levels.zig (C0849); there
//! the sweep gathers straight from the tree's columns, which measured faster than storing rows at
//! their ranks.

const std = @import("std");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Axis = types.Axis;
const inf = types.inf;

const W = simd.lanes;
const F = simd.F;

/// What resolve reads about a node as a child, on one axis. 32 bytes, two per cache line.
pub const Child = extern struct {
    k0: f32,
    k1: f32,
    k2: f32,
    /// `main[p] * (taken[p] - nat)` for a node that shrinks: the room its siblings leave it is
    /// `inner - room`. -inf for a node that does not shrink, so the room is infinite.
    room: f32,
    min: f32,
    max: f32,
    flow: f32,
    parent: u32,
};

/// What resolve reads about a node as a parent, on one axis.
pub const Parent = extern struct {
    /// pad_lo + pad_hi
    pad: f32,
    /// fit + gap_total: what the children take along the main axis before growing.
    taken: f32,
};

/// What place reads about a node as a parent, both axes.
pub const Place = extern struct {
    /// pad_lo - scroll: where the content box starts, relative to the node.
    origin: [2]f32,
    /// size - pad_lo - pad_hi
    inner: [2]f32,
    /// Leftover space before the first child along the main axis (zero across it).
    lead: [2]f32,
    main: [2]f32,
    align_cross: f32,
    gap: f32,
};

pub const Coefs = struct {
    cap: u32,
    c: Columns,

    /// Both axes have their own rows, so the x rows survive until `resolveK(.x)` while the y
    /// rows are written after `fit(.y)`.
    pub const Columns = struct {
        child: [2][]Child,
        parent: [2][]Parent,
        place: []Place,
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
/// `layout.fit(t, axis)`, before `resolveK`. Padding rows point at parent 0 and are never used.
pub fn coefs(t: *const Tree, k: *Coefs, axis: Axis) void {
    std.debug.assert(t.len <= k.cap);
    const a = @backingInt(axis);
    const c = &t.c;
    const one = simd.f(1);
    const zero = simd.f(0);
    const n = simd.padded(t.len);
    const child = k.c.child[a];
    const parent_row = k.c.parent[a];
    var i: usize = 0;
    while (i < n) : (i += W) {
        // Padding rows hold stale parents; clamp them to a real row.
        const p = @min(simd.loadU(c.parent, i), simd.u(t.len -| 1));
        const main = gather(c.main[a], p);
        const grow_inv = gather(c.grow_inv[a], p);
        const taken = gather(c.fit[a], p) + gather(c.gap_total, p);
        const nat = simd.loadF(c.nat[a], i);
        const grow = simd.loadF(c.grow[a], i);
        const pct = simd.loadF(c.pct[a], i);
        const fl = simd.loadF(c.flow, i);
        // The same algebra as layout.resolve, one vector of children at a time.
        const has_pct = @select(f32, pct >= zero, one, zero);
        const keep = one - has_pct;
        const across = (one - main) * @select(f32, grow > zero, one, zero);
        const k0 = nat * keep * (one - fl * across);
        const k1 = has_pct * pct + keep * fl * across;
        const k2 = keep * fl * main * grow * grow_inv;
        const cut = (simd.loadF(c.shrink, i) * fl) > zero;
        const room = @select(f32, cut, main * (taken - nat), simd.f(-inf));
        const min = simd.loadF(c.min[a], i);
        const max = simd.loadF(c.max[a], i);
        const pad = simd.loadF(c.pad_lo[a], i) + simd.loadF(c.pad_hi[a], i);
        const own_taken = simd.loadF(c.fit[a], i) + simd.loadF(c.gap_total, i);
        // Columns to rows: a transpose, one row store per lane.
        inline for (0..W) |l| {
            child[i + l] = .{ .k0 = k0[l], .k1 = k1[l], .k2 = k2[l], .room = room[l], .min = min[l], .max = max[l], .flow = fl[l], .parent = p[l] };
            parent_row[i + l] = .{ .pad = pad[l], .taken = own_taken[l] };
        }
    }
}

/// Top-down: final size of every node on one axis, from the rows of `coefs`. One forward
/// sweep; the same sizes as `layout.resolve`.
pub fn resolveK(t: *Tree, k: *const Coefs, axis: Axis, viewport: f32) void {
    const a = @backingInt(axis);
    if (t.len == 0) return;
    const size = t.c.size[a];
    const used = t.c.used[a];
    const child = k.c.child[a];
    const parent_row = k.c.parent[a];

    size[0] = viewport;
    for (child[1..t.len], 1..) |r, i| {
        const p = r.parent;
        const pr = parent_row[p];
        const inner = @max(size[p] - pr.pad, 0);
        var s = r.k0 + r.k1 * inner + r.k2 * @max(inner - pr.taken, 0);
        // Shrinkable nodes give way when the parent has no room for them.
        s -= @max(s - @max(inner - r.room, 0), 0);
        s = @min(@max(s, r.min), r.max);
        size[i] = s;
        used[p] += s * r.flow;
    }
}

/// SIMD. One Place row per node from resolve's sizes. Call after both `resolveK` (or
/// `layout.resolve`) axes, before `placeK`.
pub fn placeRows(t: *const Tree, k: *Coefs) void {
    std.debug.assert(t.len <= k.cap);
    const c = &t.c;
    const zero = simd.f(0);
    const n = simd.padded(t.len);
    const rows = k.c.place;
    var i: usize = 0;
    while (i < n) : (i += W) {
        var origin: [2]F = undefined;
        var inner: [2]F = undefined;
        var lead: [2]F = undefined;
        var main: [2]F = undefined;
        const align_main = simd.loadF(c.align_main, i);
        const gap_total = simd.loadF(c.gap_total, i);
        inline for (0..2) |a| {
            const lo = simd.loadF(c.pad_lo[a], i);
            origin[a] = lo - simd.loadF(c.scroll[a], i);
            inner[a] = simd.loadF(c.size[a], i) - lo - simd.loadF(c.pad_hi[a], i);
            lead[a] = @max(inner[a] - simd.loadF(c.used[a], i) - gap_total, zero) * align_main;
            main[a] = simd.loadF(c.main[a], i);
        }
        const align_cross = simd.loadF(c.align_cross, i);
        const gap = simd.loadF(c.gap, i);
        inline for (0..W) |l| rows[i + l] = .{
            .origin = .{ origin[0][l], origin[1][l] },
            .inner = .{ inner[0][l], inner[1][l] },
            .lead = .{ lead[0][l], lead[1][l] },
            .main = .{ main[0][l], main[1][l] },
            .align_cross = align_cross[l],
            .gap = gap[l],
        };
    }
}

/// Top-down: position of every node on both axes, from the rows of `placeRows`. One forward
/// sweep; the same positions as `layout.place`.
pub fn placeK(t: *Tree, k: *const Coefs) void {
    if (t.len == 0) return;
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
        const p = parent[i];
        const r = rows[p];
        const fl = flow[i];
        const along = cursor[p];
        inline for (0..2) |a| {
            const across = @max(r.inner[a] - size[a][i], 0) * r.align_cross;
            const in_flow = across + r.main[a] * (r.lead[a] + along - across);
            pos[a][i] = pos[a][p] + r.origin[a] + fl * in_flow + offset[a][i];
        }
        // Advance along whichever axis is the parent's main one.
        const step = size[0][i] * r.main[0] + size[1][i] * r.main[1];
        cursor[p] += (step + r.gap) * fl;
    }
}

const testing = std.testing;
const layout = @import("layout.zig");
const check = @import("check.zig");

test "resolveK and placeK: the sizes and positions of the prototype's passes on random trees" {
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
        layout.place(&t);
        var want_pos: [2][1000]f32 = undefined;
        for (0..2) |a| @memcpy(want_pos[a][0..t.len], t.c.pos[a][0..t.len]);
        @memcpy(want[0..t.len], t.c.cursor[0..t.len]);
        @memset(t.c.cursor, 0);
        placeRows(&t, &k);
        placeK(&t, &k);
        for (0..2) |a| try testing.expect(check.maxDiff(want_pos[a][0..t.len], t.c.pos[a], t.len) <= check.tolerance);
        try testing.expect(check.maxDiff(want[0..t.len], t.c.cursor, t.len) <= check.tolerance);
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
    const x = k.c.child[0];
    try testing.expectEqual(Child{ .k0 = 40, .k1 = 0, .k2 = 0, .room = -inf, .min = 40, .max = 40, .flow = 1, .parent = root }, x[px]);
    try testing.expectEqual(1, x[fill].k2);
    try testing.expectEqual(0.5, x[half].k1);
    try testing.expectEqual(0, x[half].k0);
    // half shrinks: its siblings' natural 40 is what it cannot have.
    try testing.expectEqual(40, x[half].room);
    try testing.expectEqual(Parent{ .pad = 10, .taken = 40 }, k.c.parent[0][root]);
    resolveK(&t, &k, .x, 300);
    try testing.expectEqual(40, t.c.size[0][px]);
    try testing.expectEqual(290 - 40, t.c.size[0][fill]);
    try testing.expectEqual(145, t.c.size[0][half]);
    // Across a row, fill stretches to the inner height.
    layout.fit(&t, .y);
    coefs(&t, &k, .y);
    resolveK(&t, &k, .y, 50);
    try testing.expectEqual(50, t.c.size[1][fill]);
    // Along the row: px at the left padding, fill after it, half after fill.
    placeRows(&t, &k);
    placeK(&t, &k);
    try testing.expectEqual(5, t.c.pos[0][px]);
    try testing.expectEqual(45, t.c.pos[0][fill]);
    try testing.expectEqual(295, t.c.pos[0][half]);
}
