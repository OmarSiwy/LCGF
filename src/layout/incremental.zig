//! incremental: lay out again only what a change can reach. The caller changes a node's inputs
//! in place (a size, padding, gap, alignment...), marks it dirty on the axes it touched, and
//! calls `update` instead of `layout.run`; the columns come out as a full run would leave them.
//! Structure (push, flow) must not change between frames; a new tree needs `layout.run`.
//! Tier 0: the table is carved from the caller's buffer like `Tree`.

const std = @import("std");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const layout = @import("layout.zig");
const Axis = types.Axis;

pub const Dirty = struct {
    cap: u32,
    c: Columns,

    pub const Columns = struct {
        /// 1 when the node's own inputs on that axis changed since the last update.
        mark: [2][]u8,
        /// 1 when the node is a relayout boundary on that axis (`boundaries`).
        bound: [2][]u8,
        /// 1 when the node's subtree has to be laid out again on that axis (`propagate`).
        span: [2][]u8,
    };

    pub fn init(carver: *mem.Carver, cap: u32) Dirty {
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }

    /// Records that node `i`'s inputs on `axis` changed. Inputs that are not per-axis (gap,
    /// alignment, direction, shrink) touch both axes.
    pub fn mark(d: *Dirty, i: u32, axis: Axis) void {
        d.c.mark[@backingInt(axis)][i] = 1;
    }
};

/// SIMD. Marks relayout boundaries: nodes whose natural size on an axis cannot depend on their
/// content, because `min >= max` clamps it to `max` (a px size, or a max below the min). A
/// change inside such a node changes the sizes and positions of its descendants only: its own
/// `nat`, and so its parent's fit and its siblings, stay as they were. The root is a boundary on
/// both axes, since the viewport sets its size.
pub fn boundaries(t: *const Tree, d: *Dirty) void {
    std.debug.assert(t.len <= d.cap);
    const n = simd.padded(t.len);
    const one: simd.Bytes = @splat(1);
    const zero: simd.Bytes = @splat(0);
    var i: usize = 0;
    while (i < n) : (i += simd.lanes) {
        inline for (0..2) |a| {
            const fixed = simd.loadF(t.c.min[a], i) >= simd.loadF(t.c.max[a], i);
            d.c.bound[a][i..][0..simd.lanes].* = @select(u8, fixed, one, zero);
        }
    }
    inline for (0..2) |a| d.c.bound[a][0] = 1;
}

/// Moves every mark to the relayout boundary above it: a marked node can change its parent's
/// fit, so it can change everything up to the first boundary ancestor of its parent, and nothing
/// outside that ancestor's subtree. Sets `span` on those ancestors and clears the marks. Call
/// after `boundaries`. Marks are few, so the scan skips whole vectors of unmarked rows and walks
/// up from each mark; the walk is O(depth).
pub fn propagate(t: *const Tree, d: *Dirty) void {
    std.debug.assert(t.len <= d.cap);
    const n = simd.padded(t.len);
    const parent = t.c.parent;
    inline for (0..2) |a| {
        const marks = d.c.mark[a];
        const bound = d.c.bound[a];
        const span = d.c.span[a];
        var i: usize = 0;
        while (i < n) : (i += simd.lanes) {
            const v: simd.Bytes = marks[i..][0..simd.lanes].*;
            if (@reduce(.Or, v) == 0) continue;
            for (i..@min(i + simd.lanes, t.len)) |j| {
                if (marks[j] == 0) continue;
                // The root's parent is itself, and the root is a boundary, so the walk ends.
                var up = parent[j];
                while (bound[up] == 0) up = parent[up];
                span[up] = 1;
            }
            marks[i..][0..simd.lanes].* = @splat(0);
        }
    }
}

/// The first span root at or after row `from` on one axis, or `t.len`. Skips whole vectors
/// without one.
fn nextSpan(t: *const Tree, span: []const u8, from: u32) u32 {
    var i: usize = from;
    while (i < t.len) {
        const base = std.mem.alignBackward(usize, i, simd.lanes);
        const v: simd.Bytes = span[base..][0..simd.lanes].*;
        if (@reduce(.Or, v) == 0) {
            i = base + simd.lanes;
            continue;
        }
        if (span[i] != 0) return @intCast(i);
        i += 1;
    }
    return t.len;
}

/// Natural sizes again for the subtree [root, end[root]) on one axis: clear its fit scratch,
/// apply the text extents of its runs, recompute its gap totals, fit it.
pub fn refit(t: *Tree, tx: *const Texts, axis: Axis, root: u32) void {
    const a = @backingInt(axis);
    const c = &t.c;
    const last = c.end[root];
    @memset(c.fit[a][root..last], 0);
    @memset(c.grow_sum[a][root..last], 0);
    // A changed gap changes gap_total; nkids is structure and stays.
    for (c.gap_total[root..last], c.gap[root..last], c.nkids[root..last]) |*g, gap, kids| {
        g.* = gap * @max(kids - 1, 0);
    }
    // Every run is written; runs outside the subtree write back what they read.
    const extents = [2][]const f32{ tx.c.w, tx.c.h };
    const dst = c.fit[a];
    for (tx.c.node[0..tx.len], extents[a][0..tx.len]) |node, extent| {
        dst[node] = simd.selF(simd.andB(node >= root, node < last), extent, dst[node]);
    }
    layout.fitSpan(t, axis, root, last);
}

/// Lays out what the marks reach and clears them: per axis, each outermost span is fitted and
/// resolved again; then every outermost span of either axis is placed and finalized. With no
/// marks the columns are left as they are: an idle frame does no layout work. Text must be
/// settled, as for `layout.run`. A new viewport marks the root. `t` must have been laid out
/// in full once (`layout.run`) since its structure last changed.
pub fn update(t: *Tree, tx: *Texts, d: *Dirty, viewport: [2]f32) void {
    std.debug.assert(t.len <= d.cap);
    if (t.len == 0) return;
    const n = simd.padded(t.len);
    const c = &t.c;
    // Once per frame, not per row: the root's size is the viewport.
    inline for (0..2) |a| d.c.mark[a][0] |= @intFromBool(c.size[a][0] != viewport[a]);
    var any: simd.Bytes = @splat(0);
    var i: usize = 0;
    while (i < n) : (i += simd.lanes) {
        inline for (0..2) |a| any |= d.c.mark[a][i..][0..simd.lanes].*;
    }
    if (@reduce(.Or, any) == 0) return;
    boundaries(t, d);
    propagate(t, d);
    inline for (0..2) |a| {
        const axis: Axis = @fromBackingInt(@intCast(a));
        c.size[a][0] = viewport[a];
        var r = nextSpan(t, d.c.span[a], 0);
        while (r < t.len) : (r = nextSpan(t, d.c.span[a], c.end[r])) {
            refit(t, tx, axis, r);
            @memset(c.used[a][r..c.end[r]], 0);
            layout.resolveSpan(t, axis, r, c.end[r]);
        }
        // Runs outside the spans get the width they already had.
        if (a == 0) layout.textAvail(t, tx);
    }
    // A span on either axis moves positions on both: place reads both axes' sizes.
    var r = @min(nextSpan(t, d.c.span[0], 0), nextSpan(t, d.c.span[1], 0));
    while (r < t.len) {
        const last = c.end[r];
        @memset(c.cursor[r..last], 0);
        layout.placeSpan(t, r, last);
        layout.finalizeSpan(t, r, last);
        r = @min(nextSpan(t, d.c.span[0], last), nextSpan(t, d.c.span[1], last));
    }
    inline for (0..2) |a| @memset(d.c.span[a][0..n], 0);
}

// ---- kept subtrees ------------------------------------------------------------------------
//
// A kept subtree is one whose rows, layout columns included, were copied unchanged from a tree
// laid out in full (`Frame.reuse`). Its root must be a relayout boundary on both axes (see
// `keepable`): then the root's size cannot change, so nothing inside it can either, and the
// passes below lay out the rest of the tree around it. Each pass is the full pass in pieces:
// the gaps between kept interiors, through layout.zig's span forms, so every row outside the
// interiors gets exactly the arithmetic a full pass gives it. `kept` lists root rows in
// ascending order, disjoint. With `kept` empty every pass is its full form.

/// Whether row `r` may be kept: a boundary on both axes with at least one descendant. A
/// select, no branch.
pub fn keepable(t: *const Tree, r: u32) bool {
    const c = &t.c;
    const fixed = simd.andB(c.min[0][r] >= c.max[0][r], c.min[1][r] >= c.max[1][r]);
    return simd.andB(fixed, c.end[r] > r + 1);
}

fn checkKept(t: *const Tree, kept: []const u32) void {
    var from: u32 = 1;
    for (kept) |r| {
        std.debug.assert(r >= from and r < t.len and keepable(t, r));
        from = t.c.end[r];
    }
}

/// `layout.prepare` that leaves the kept rows' scratch (fit, grow_sum, used, cursor) alone: the
/// passes below do not visit their interiors, so those keep the values they were copied with.
/// The kept roots keep them too, since they are sums over their interior. `gap_total` is
/// derived everywhere (SIMD), as `prepare` does.
pub fn prepareKept(t: *Tree, kept: []const u32) void {
    checkKept(t, kept);
    const c = &t.c;
    const n = simd.padded(t.len);
    const zero = simd.f(0);
    var i: usize = 0;
    while (i < n) : (i += simd.lanes) {
        const gaps = @max(simd.loadF(c.nkids, i) - simd.f(1), zero);
        simd.storeF(c.gap_total, i, simd.loadF(c.gap, i) * gaps);
    }
    var from: usize = 0;
    for (kept) |r| {
        clearScratch(t, from, r);
        from = c.end[r];
    }
    clearScratch(t, from, n);
}

fn clearScratch(t: *Tree, from: usize, to: usize) void {
    inline for (0..2) |a| {
        @memset(t.c.fit[a][from..to], 0);
        @memset(t.c.grow_sum[a][from..to], 0);
        @memset(t.c.used[a][from..to], 0);
    }
    @memset(t.c.cursor[from..to], 0);
}

/// `layout.applyText` for the runs outside the kept subtrees (roots included: a root's fit is
/// its copied total). Runs are in node order, so each gap's runs are one range.
pub fn applyTextKept(t: *Tree, tx: *const Texts, axis: Axis, kept: []const u32) void {
    const extents = [2][]const f32{ tx.c.w, tx.c.h };
    const src = extents[@backingInt(axis)];
    const dst = t.c.fit[@backingInt(axis)];
    var k: u32 = 0;
    for (kept) |r| {
        const k1 = simd.rank(tx.c.node, tx.len, r);
        for (tx.c.node[k..k1], src[k..k1]) |node, extent| dst[node] = extent;
        k = simd.rank(tx.c.node, tx.len, t.c.end[r]);
    }
    for (tx.c.node[k..tx.len], src[k..tx.len]) |node, extent| dst[node] = extent;
}

/// `layout.fit` that does not visit kept interiors: bottom-up, gap by gap. A gap [x, y) after
/// a kept root is `fitSpan(x - 1, y)`; its first row `x - 1` is the last row of that kept
/// interior, whose natural size the span recomputes from its copied fit, to the same value.
pub fn fitKept(t: *Tree, axis: Axis, kept: []const u32) void {
    if (t.len == 0) return;
    var hi = t.len;
    var j = kept.len;
    while (j > 0) {
        j -= 1;
        const e = t.c.end[kept[j]];
        if (e < hi) layout.fitSpan(t, axis, e - 1, hi);
        hi = kept[j] + 1;
    }
    layout.fitSpan(t, axis, 0, hi);
}

/// `layout.resolve` that does not visit kept interiors: top-down, gap by gap. A kept root's
/// size is fixed, so its interior's sizes are the copied ones.
pub fn resolveKept(t: *Tree, axis: Axis, viewport: f32, kept: []const u32) void {
    if (t.len == 0) return;
    t.c.size[@backingInt(axis)][0] = viewport;
    var first: u32 = 0;
    for (kept) |r| {
        layout.resolveSpan(t, axis, first, r + 1);
        first = t.c.end[r] - 1;
    }
    if (first + 1 < t.len) layout.resolveSpan(t, axis, first, t.len);
}

/// `layout.place` that does not visit the interior of a kept root that did not move. One that
/// moved is placed again (`placeSpan` over its subtree) rather than shifted: adding the move to
/// each copied position would round differently from placing it, and the result has to be
/// what a full pass gives. The one branch per kept subtree is that choice.
pub fn placeKept(t: *Tree, kept: []const u32) void {
    if (t.len == 0) return;
    const c = &t.c;
    c.pos[0][0] = 0;
    c.pos[1][0] = 0;
    var first: u32 = 0;
    for (kept) |r| {
        const was = [2]f32{ c.pos[0][r], c.pos[1][r] };
        layout.placeSpan(t, first, r + 1);
        const e = c.end[r];
        if (c.pos[0][r] != was[0] or c.pos[1][r] != was[1]) {
            @memset(c.cursor[r..e], 0);
            layout.placeSpan(t, r, e);
        }
        first = e - 1;
    }
    if (first + 1 < t.len) layout.placeSpan(t, first, t.len);
}

/// `layout.run` with kept subtrees: every pass in order, each skipping the kept interiors.
/// `finalize` runs over everything, since clips come down from ancestors.
pub fn runKept(t: *Tree, tx: *Texts, viewport: [2]f32, kept: []const u32) void {
    prepareKept(t, kept);
    applyTextKept(t, tx, .x, kept);
    fitKept(t, .x, kept);
    resolveKept(t, .x, viewport[0], kept);
    layout.textAvail(t, tx);
    applyTextKept(t, tx, .y, kept);
    fitKept(t, .y, kept);
    resolveKept(t, .y, viewport[1], kept);
    placeKept(t, kept);
    layout.finalize(t);
}

const testing = std.testing;
const check = @import("check.zig");
const inf = types.inf;

/// One random change to a node's inputs, applied the same way to two identical trees.
const Change = struct {
    node: u32,
    axis: u1,
    kind: u4,
    v: f32,

    fn random(r: std.Random, len: u32) Change {
        return .{
            .node = r.uintLessThan(u32, len),
            .axis = r.int(u1),
            .kind = r.uintLessThan(u4, 10),
            .v = @floatFromInt(r.uintLessThan(u32, 120)),
        };
    }

    /// Writes the change into `t` and marks what it touched, if `d` is given.
    fn apply(ch: Change, t: *Tree, d: ?*Dirty) void {
        const c = &t.c;
        const i = ch.node;
        const a = ch.axis;
        var both = false;
        switch (ch.kind) {
            0 => { // px
                c.min[a][i] = ch.v;
                c.max[a][i] = ch.v;
                c.grow[a][i] = 0;
                c.pct[a][i] = 0;
            },
            1 => { // fit
                c.min[a][i] = 0;
                c.max[a][i] = inf;
                c.grow[a][i] = 0;
                c.pct[a][i] = 0;
            },
            2 => { // grow
                c.min[a][i] = 0;
                c.max[a][i] = inf;
                c.grow[a][i] = 1 + @mod(ch.v, 3);
                c.pct[a][i] = 0;
            },
            3 => c.pct[a][i] = ch.v / 120,
            4 => c.pad_lo[a][i] = @mod(ch.v, 8),
            5 => c.offset[a][i] = ch.v,
            6 => c.scroll[a][i] = @mod(ch.v, 5),
            7 => {
                c.gap[i] = @mod(ch.v, 7);
                both = true;
            },
            8 => {
                c.align_main[i] = @mod(ch.v, 3) / 2;
                c.align_cross[i] = @mod(ch.v + 1, 3) / 2;
                c.shrink[i] = 1 - c.shrink[i];
                both = true;
            },
            else => {
                std.mem.swap(f32, &c.main[0][i], &c.main[1][i]);
                both = true;
            },
        }
        const dd = d orelse return;
        dd.mark(i, @fromBackingInt(@intCast(a)));
        if (both) dd.mark(i, @fromBackingInt(@intCast(1 - a)));
    }
};

/// Every layout output and scratch column a later pass or the host reads, rows [0, len).
fn expectSameLayout(want: *const Tree, got: *const Tree) !void {
    const n = want.len;
    try testing.expectEqual(n, got.len);
    const w = &want.c;
    const g = &got.c;
    inline for (0..2) |a| {
        try testing.expectEqualSlices(f32, w.size[a][0..n], g.size[a][0..n]);
        try testing.expectEqualSlices(f32, w.pos[a][0..n], g.pos[a][0..n]);
        try testing.expectEqualSlices(f32, w.nat[a][0..n], g.nat[a][0..n]);
        try testing.expectEqualSlices(f32, w.fit[a][0..n], g.fit[a][0..n]);
        try testing.expectEqualSlices(f32, w.used[a][0..n], g.used[a][0..n]);
        try testing.expectEqualSlices(f32, w.grow_inv[a][0..n], g.grow_inv[a][0..n]);
    }
    inline for (0..4) |k| {
        try testing.expectEqualSlices(f32, w.rect[k][0..n], g.rect[k][0..n]);
        try testing.expectEqualSlices(f32, w.vis[k][0..n], g.vis[k][0..n]);
    }
    try testing.expectEqualSlices(f32, w.gap_total[0..n], g.gap_total[0..n]);
    try testing.expectEqualSlices(f32, w.cursor[0..n], g.cursor[0..n]);
    try testing.expectEqualSlices([4]f32, w.child_clip[0..n], g.child_clip[0..n]);
    try testing.expectEqualSlices(u8, w.visible[0..n], g.visible[0..n]);
}

/// Two identical random trees, laid out in full. Frame after frame the same random changes go
/// into both, and now and then a new viewport; `full` is laid out from scratch, `inc` through
/// `update`. They must agree bit for bit. With `texts`, about a third of the leaves carry a
/// measured text run, and changes also give runs new extents.
fn randomFrames(seed: u64, trees: u32, frames: u32, changes: u32, texts: bool) !void {
    var raw: [2][1024 * 1024]u8 align(mem.column_align) = undefined;
    var c0: mem.Carver = .{ .buf = &raw[0] };
    var c1: mem.Carver = .{ .buf = &raw[1] };
    var full = Tree.init(&c0, 600);
    var inc = Tree.init(&c1, 600);
    var full_tx = Texts.init(&c0, 600);
    var inc_tx = Texts.init(&c1, 600);
    var d = Dirty.init(&c1, 600);
    var vp: [2]f32 = .{ 1280, 800 };
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    for (0..trees) |_| {
        const tree_seed = r.int(u64);
        const n = 1 + r.uintLessThan(u32, full.cap);
        var a: std.Random.DefaultPrng = .init(tree_seed);
        var b: std.Random.DefaultPrng = .init(tree_seed);
        check.randomTree(&full, a.random(), n);
        check.randomTree(&inc, b.random(), n);
        full_tx.reset();
        inc_tx.reset();
        for (0..n) |i| {
            if (!texts or full.c.end[i] != i + 1 or r.uintLessThan(u32, 3) != 0) continue;
            const node: u32 = @intCast(i);
            for ([2]*Texts{ &full_tx, &inc_tx }, [2]*Tree{ &full, &inc }) |tx, t| {
                t.c.text[node] = tx.push(node, .{}, &.{});
            }
            const w: f32 = @floatFromInt(r.uintLessThan(u32, 300));
            const h: f32 = @floatFromInt(r.uintLessThan(u32, 40));
            full_tx.c.w[full_tx.len - 1] = w;
            full_tx.c.h[full_tx.len - 1] = h;
            inc_tx.c.w[inc_tx.len - 1] = w;
            inc_tx.c.h[inc_tx.len - 1] = h;
        }
        layout.run(&full, &full_tx, vp);
        layout.run(&inc, &inc_tx, vp);
        for (0..frames) |_| {
            for (0..r.uintAtMost(u32, changes)) |_| {
                const ch = Change.random(r, n);
                ch.apply(&full, null);
                ch.apply(&inc, &d);
                if (full_tx.len == 0 or r.boolean()) continue;
                // A run measured again: new extents, both axes of its node.
                const k = r.uintLessThan(u32, full_tx.len);
                const w: f32 = @floatFromInt(r.uintLessThan(u32, 300));
                full_tx.c.w[k] = w;
                inc_tx.c.w[k] = w;
                full_tx.c.h[k] = w / 10;
                inc_tx.c.h[k] = w / 10;
                d.mark(inc_tx.c.node[k], .x);
                d.mark(inc_tx.c.node[k], .y);
            }
            if (r.uintLessThan(u32, 8) == 0) vp[r.int(u1)] = @floatFromInt(400 + r.uintLessThan(u32, 1200));
            layout.run(&full, &full_tx, vp);
            update(&inc, &inc_tx, &d, vp);
            try expectSameLayout(&full, &inc);
            try testing.expectEqualSlices(f32, full_tx.c.avail[0..full_tx.len], inc_tx.c.avail[0..inc_tx.len]);
        }
    }
}

test "update: equals a full layout after random changes to random trees" {
    try randomFrames(0x111, 40, 8, 3, false);
}

test "update: equals a full layout with text runs, many changes per frame and many seeds" {
    // One change per frame, the common case, then bursts of up to 40.
    for (0..4) |s| try randomFrames(0x1160 + s, 30, 10, 1, true);
    for (0..4) |s| try randomFrames(0x1170 + s, 20, 6, 40, true);
}

test "boundaries: px sizes and the root, not fit, grow or pct" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 8);
    var d = Dirty.init(&carver, 8);
    const root = t.push(0, .none, &.{});
    // Rows 1..3: px(40) x fit, fill x 50%, and a max below its min across x.
    _ = t.push(root, .none, &.{ .size = .{ .px(40), .fit } });
    _ = t.push(root, .none, &.{ .size = .{ .fill, .pct(0.5) } });
    _ = t.push(root, .none, &.{ .min = .{ 30, 0 }, .max = .{ 20, inf } });
    t.seal(root);
    boundaries(&t, &d);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 0, 1 }, d.c.bound[0][0..4]);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, d.c.bound[1][0..4]);
}

test "boundaries: changes inside a boundary leave its natural size, and all outside it, alone" {
    var raw: [2][1024 * 1024]u8 align(mem.column_align) = undefined;
    var c0: mem.Carver = .{ .buf = &raw[0] };
    var c1: mem.Carver = .{ .buf = &raw[1] };
    var before = Tree.init(&c0, 600);
    var after = Tree.init(&c1, 600);
    var tx = Texts.init(&c0, 1);
    var d = Dirty.init(&c0, 600);
    var prng: std.Random.DefaultPrng = .init(0x112);
    const r = prng.random();
    var tried: u32 = 0;
    while (tried < 200) {
        const seed = r.int(u64);
        const n = 2 + r.uintLessThan(u32, before.cap - 1);
        var a: std.Random.DefaultPrng = .init(seed);
        var b: std.Random.DefaultPrng = .init(seed);
        check.randomTree(&before, a.random(), n);
        check.randomTree(&after, b.random(), n);
        boundaries(&before, &d);
        // A boundary other than the root, with something inside it to change.
        const k = 1 + r.uintLessThan(u32, n - 1);
        const ax = r.int(u1);
        if (d.c.bound[ax][k] == 0 or before.c.end[k] == k + 1) continue;
        tried += 1;
        const inside = k + 1 + r.uintLessThan(u32, before.c.end[k] - k - 1);
        var ch = Change.random(r, n);
        ch.node = inside;
        ch.axis = ax;
        if (ch.kind >= 7) ch.kind = 0; // keep the change on this axis
        ch.apply(&after, null);
        layout.run(&before, &tx, .{ 1280, 800 });
        layout.run(&after, &tx, .{ 1280, 800 });
        try testing.expectEqual(before.c.nat[ax][k], after.c.nat[ax][k]);
        // Outside the subtree nothing on that axis moved.
        const outside = [2][2]u32{ .{ 0, k + 1 }, .{ before.c.end[k], n } };
        for (outside) |o| {
            try testing.expectEqualSlices(f32, before.c.size[ax][o[0]..o[1]], after.c.size[ax][o[0]..o[1]]);
            try testing.expectEqualSlices(f32, before.c.pos[ax][o[0]..o[1]], after.c.pos[ax][o[0]..o[1]]);
        }
    }
}

test "propagate: outside the marked spans a change moves nothing on that axis" {
    var raw: [2][1024 * 1024]u8 align(mem.column_align) = undefined;
    var c0: mem.Carver = .{ .buf = &raw[0] };
    var c1: mem.Carver = .{ .buf = &raw[1] };
    var before = Tree.init(&c0, 600);
    var after = Tree.init(&c1, 600);
    var tx = Texts.init(&c0, 1);
    var d = Dirty.init(&c1, 600);
    var prng: std.Random.DefaultPrng = .init(0x113);
    const r = prng.random();
    var narrowed: u32 = 0;
    for (0..300) |_| {
        const seed = r.int(u64);
        const n = 1 + r.uintLessThan(u32, before.cap);
        var a: std.Random.DefaultPrng = .init(seed);
        var b: std.Random.DefaultPrng = .init(seed);
        check.randomTree(&before, a.random(), n);
        check.randomTree(&after, b.random(), n);
        layout.run(&before, &tx, .{ 1280, 800 });
        for (0..1 + r.uintLessThan(u32, 3)) |_| Change.random(r, n).apply(&after, &d);
        layout.run(&after, &tx, .{ 1280, 800 });
        boundaries(&after, &d);
        propagate(&after, &d);
        inline for (0..2) |ax| {
            const zeros: [600]u8 = @splat(0);
            try testing.expectEqualSlices(u8, zeros[0..n], d.c.mark[ax][0..n]);
            var covered: [600]bool = @splat(false);
            for (0..n) |i| if (d.c.span[ax][i] != 0) @memset(covered[i..after.c.end[i]], true);
            for (0..n) |i| {
                if (covered[i]) continue;
                try testing.expectEqual(before.c.size[ax][i], after.c.size[ax][i]);
                try testing.expectEqual(before.c.pos[ax][i], after.c.pos[ax][i]);
                try testing.expectEqual(before.c.nat[ax][i], after.c.nat[ax][i]);
                try testing.expectEqual(before.c.fit[ax][i], after.c.fit[ax][i]);
            }
            narrowed += @intFromBool(!covered[0]);
            @memset(d.c.span[ax], 0);
        }
    }
    // Most changes stop below the root, or the test would not show anything.
    try testing.expect(narrowed > 300);
}

test "update: a new viewport lays out the root's subtree again" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 8);
    var tx = Texts.init(&carver, 1);
    var d = Dirty.init(&carver, 8);
    const root = t.push(0, .none, &.{});
    const fill = t.push(root, .none, &.{ .size = .{ .fill, .fill } });
    t.seal(root);
    layout.run(&t, &tx, .{ 100, 50 });
    update(&t, &tx, &d, .{ 300, 70 });
    try testing.expectEqual(types.Rect{ .x0 = 0, .y0 = 0, .x1 = 300, .y1 = 70 }, t.rect(fill));
}

test "update: a change inside a px panel leaves the rows outside it untouched" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 8);
    var tx = Texts.init(&carver, 1);
    var d = Dirty.init(&carver, 8);
    const root = t.push(0, .none, &.{ .dir = .x });
    const left = t.push(root, .none, &.{ .size = .{ .px(100), .px(100) } });
    const a = t.push(left, .none, &.{ .size = .{ .px(10), .px(10) } });
    t.seal(left);
    const right = t.push(root, .none, &.{ .size = .{ .px(100), .px(100) } });
    const b = t.push(right, .none, &.{ .size = .{ .px(10), .px(10) } });
    const c = t.push(right, .none, &.{ .size = .{ .px(10), .px(10) } });
    t.seal(right);
    t.seal(root);
    layout.run(&t, &tx, .{ 400, 300 });
    // Stale values the update must not reach. (Not `rect`: its SIMD snap rewrites whole
    // vectors around a span, with the values the rows already hold.)
    inline for (.{ root, left, a, right }) |k| t.c.vis[2][k] = -1;
    t.c.min[1][b] = 30;
    t.c.max[1][b] = 30;
    d.mark(b, .y);
    update(&t, &tx, &d, .{ 400, 300 });
    // b grew to 30, so c moves down by 20; right is px, so nothing above it moves.
    try testing.expectEqual(types.Rect{ .x0 = 100, .y0 = 0, .x1 = 110, .y1 = 30 }, t.rect(b));
    try testing.expectEqual(types.Rect{ .x0 = 100, .y0 = 30, .x1 = 110, .y1 = 40 }, t.rect(c));
    inline for (.{ root, left, a }) |k| try testing.expectEqual(-1, t.c.vis[2][k]);
    // right is the span root: finalized again, so its stale value is gone.
    try testing.expectEqual(200, t.c.vis[2][right]);
}

test "update: no marks, no work" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 8);
    var tx = Texts.init(&carver, 1);
    var d = Dirty.init(&carver, 8);
    _ = t.push(0, .none, &.{ .size = .{ .px(100), .px(50) } });
    t.seal(0);
    layout.run(&t, &tx, .{ 100, 50 });
    t.c.rect[2][0] = -1; // a stale output stays stale: nothing ran
    update(&t, &tx, &d, .{ 100, 50 });
    try testing.expectEqual(-1, t.c.rect[2][0]);
    d.mark(0, .x);
    update(&t, &tx, &d, .{ 100, 50 });
    try testing.expectEqual(100, t.c.rect[2][0]);
    try testing.expectEqual(0, d.c.mark[0][0]);
}

/// Random trees laid out in full, then a "next frame": a copy of the laid-out columns in which
/// some keepable subtrees are kept, random changes land outside them (and sometimes a new
/// viewport), and `runKept` lays the copy out. `layout.run` over the same changes is the
/// reference; every column must agree bit for bit. Returns how many kept roots were placed
/// again because they moved, and how many stayed put, so the caller can see both paths ran.
fn keptFrames(seed: u64, trees: u32, changes: u32) ![2]u32 {
    var raw: [2][1024 * 1024]u8 align(mem.column_align) = undefined;
    var c0: mem.Carver = .{ .buf = &raw[0] };
    var c1: mem.Carver = .{ .buf = &raw[1] };
    var full = Tree.init(&c0, 600);
    var kept_tree = Tree.init(&c1, 600);
    var full_tx = Texts.init(&c0, 600);
    var kept_tx = Texts.init(&c1, 600);
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    var counts: [2]u32 = .{ 0, 0 };
    var kept_buf: [600]u32 = undefined;
    for (0..trees) |_| {
        const n = 2 + r.uintLessThan(u32, full.cap - 1);
        check.randomTree(&full, r, n);
        // More boundaries than random styles give: some nodes px on both axes.
        for (1..n) |i| {
            if (r.uintLessThan(u32, 4) != 0) continue;
            inline for (0..2) |a| {
                const v: f32 = @floatFromInt(20 + r.uintLessThan(u32, 200));
                full.c.min[a][i] = v;
                full.c.max[a][i] = v;
            }
        }
        full_tx.reset();
        for (0..n) |i| {
            if (full.c.end[i] != i + 1 or r.uintLessThan(u32, 3) != 0) continue;
            const node: u32 = @intCast(i);
            full.c.text[node] = full_tx.push(node, .{}, &.{});
            full_tx.c.w[full_tx.len - 1] = @floatFromInt(r.uintLessThan(u32, 300));
            full_tx.c.h[full_tx.len - 1] = @floatFromInt(r.uintLessThan(u32, 40));
        }
        var vp: [2]f32 = .{ 1280, 800 };
        layout.run(&full, &full_tx, vp);

        // Last frame's result, copied whole: what Frame.reuse copies row by row.
        kept_tree.len = full.len;
        mem.copyRows(Tree.Columns, &kept_tree.c, 0, &full.c, 0, simd.rows(full.cap));
        kept_tx.len = full_tx.len;
        mem.copyRows(Texts.Columns, &kept_tx.c, 0, &full_tx.c, 0, simd.rows(full_tx.cap));

        var kept_len: usize = 0;
        var i: u32 = 1;
        while (i < n) {
            if (keepable(&full, i) and r.boolean()) {
                kept_buf[kept_len] = i;
                kept_len += 1;
                i = full.c.end[i];
            } else i += 1;
        }
        const kept = kept_buf[0..kept_len];
        var inside: [600]bool = @splat(false);
        for (kept) |k| @memset(inside[k..full.c.end[k]], true);

        for (0..r.uintAtMost(u32, changes)) |_| {
            var ch = Change.random(r, n);
            if (inside[ch.node]) continue;
            ch.apply(&full, null);
            ch.apply(&kept_tree, null);
            if (full_tx.len == 0) continue;
            const k = r.uintLessThan(u32, full_tx.len);
            if (inside[full_tx.c.node[k]]) continue;
            const w: f32 = @floatFromInt(r.uintLessThan(u32, 300));
            full_tx.c.w[k] = w;
            kept_tx.c.w[k] = w;
        }
        if (r.uintLessThan(u32, 4) == 0) vp[r.int(u1)] = @floatFromInt(400 + r.uintLessThan(u32, 1200));

        var was: [600][2]f32 = undefined;
        for (kept, 0..) |k, j| was[j] = .{ kept_tree.c.pos[0][k], kept_tree.c.pos[1][k] };
        layout.run(&full, &full_tx, vp);
        runKept(&kept_tree, &kept_tx, vp, kept);
        try expectSameLayout(&full, &kept_tree);
        try testing.expectEqualSlices(f32, full_tx.c.avail[0..full_tx.len], kept_tx.c.avail[0..kept_tx.len]);
        inline for (0..2) |a| try testing.expectEqualSlices(f32, full.c.grow_sum[a][0..n], kept_tree.c.grow_sum[a][0..n]);
        for (kept, 0..) |k, j| {
            const moved = was[j][0] != full.c.pos[0][k] or was[j][1] != full.c.pos[1][k];
            counts[@intFromBool(moved)] += 1;
        }
    }
    return counts;
}

test "runKept: kept subtrees, moved or not, give the columns of a full layout" {
    var still: u32 = 0;
    var moved: u32 = 0;
    for (0..6) |s| {
        const c = try keptFrames(0x2490 + s, 40, 12);
        still += c[0];
        moved += c[1];
    }
    // Both paths of placeKept ran, many times (209 and 53 with these seeds).
    try testing.expect(still > 100 and moved > 40);
}

test "runKept: with nothing kept it is layout.run" {
    var raw: [2][256 * 1024]u8 align(mem.column_align) = undefined;
    var c0: mem.Carver = .{ .buf = &raw[0] };
    var c1: mem.Carver = .{ .buf = &raw[1] };
    var a = Tree.init(&c0, 100);
    var b = Tree.init(&c1, 100);
    var tx = Texts.init(&c0, 1);
    var prng0: std.Random.DefaultPrng = .init(0x2499);
    var prng1: std.Random.DefaultPrng = .init(0x2499);
    check.randomTree(&a, prng0.random(), 100);
    check.randomTree(&b, prng1.random(), 100);
    layout.run(&a, &tx, .{ 640, 480 });
    runKept(&b, &tx, .{ 640, 480 }, &.{});
    try expectSameLayout(&a, &b);
}
