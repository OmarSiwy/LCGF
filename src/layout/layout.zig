//! layout: a fixed sequence of linear passes over the tree columns. No solver, no re-measure loop,
//! so the cost is the same every frame and proportional to the node count. Tier 0: no allocator,
//! no I/O. Ported from prototype/ui.zig ("layout").
//!
//!   prepare            SIMD     clear scratch, gap totals
//!   applyText(.x)      scatter  text widths into leaves
//!   fit(.x)            reverse  natural widths, bottom-up (+ SIMD reciprocals)
//!   resolve(.x)        forward  final widths, top-down
//!   textAvail          gather   widths for wrapping   (caller re-measures here)
//!   applyText/fit/resolve(.y)   the same three for heights
//!   place              forward  positions on both axes

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Axis = types.Axis;

const W = simd.lanes;
const b01 = simd.b2f;

/// SIMD. Clears per-frame scratch and derives `gap_total`.
pub fn prepare(t: *Tree) void {
    const c = &t.c;
    const n = simd.padded(t.len);
    const zero = simd.f(0);
    var i: usize = 0;
    while (i < n) : (i += W) {
        inline for (0..2) |a| {
            simd.storeF(c.fit[a], i, zero);
            simd.storeF(c.grow_sum[a], i, zero);
            simd.storeF(c.used[a], i, zero);
        }
        simd.storeF(c.cursor, i, zero);
        const gaps = @max(simd.loadF(c.nkids, i) - simd.f(1), zero);
        simd.storeF(c.gap_total, i, simd.loadF(c.gap, i) * gaps);
    }
}

/// Scatters measured text extents into their leaf nodes for one axis.
pub fn applyText(t: *Tree, tx: *const Texts, axis: Axis) void {
    const a = @backingInt(axis);
    const extents = [2][]const f32{ tx.c.w, tx.c.h };
    const src = extents[a];
    const dst = t.c.fit[a];
    for (tx.c.node[0..tx.len], src[0..tx.len]) |node, extent| dst[node] = extent;
}

/// Bottom-up: natural size of every node on one axis. One reverse sweep.
pub fn fit(t: *Tree, axis: Axis) void {
    const a = @backingInt(axis);
    if (t.len == 0) return;
    // Column slices are read into locals once, so the loop indexes them
    // directly instead of reloading each slice from the struct.
    const parent = t.c.parent;
    const fit_ = t.c.fit[a];
    const nat_ = t.c.nat[a];
    const main = t.c.main[a];
    const gap_total = t.c.gap_total;
    const lo = t.c.pad_lo[a];
    const hi = t.c.pad_hi[a];
    const min = t.c.min[a];
    const max = t.c.max[a];
    const flow = t.c.flow;
    const grow = t.c.grow[a];
    const grow_sum = t.c.grow_sum[a];

    var i: u32 = t.len;
    while (i > 1) {
        i -= 1;
        // All descendants have larger rows, so fit_[i] is complete here.
        const content = fit_[i] + main[i] * gap_total[i];
        const nat = @min(@max(content + lo[i] + hi[i], min[i]), max[i]);
        nat_[i] = nat;
        // Fold into the parent: a sum along its main axis, a max across it.
        const p = parent[i];
        const contrib = nat * flow[i];
        const sum = fit_[p] + contrib;
        const mx = @max(fit_[p], contrib);
        fit_[p] = mx + main[p] * (sum - mx);
        grow_sum[p] += grow[i] * flow[i];
    }
    // The root has no parent to fold into.
    const content = fit_[0] + main[0] * gap_total[0];
    nat_[0] = @min(@max(content + lo[0] + hi[0], min[0]), max[0]);

    // SIMD: one reciprocal per node, so the top-down sweep has no division
    // on its parent-to-child dependency chain.
    const grow_inv = t.c.grow_inv[a];
    const n = simd.padded(t.len);
    var j: usize = 0;
    while (j < n) : (j += W) {
        simd.storeF(grow_inv, j, simd.f(1) / @max(simd.loadF(grow_sum, j), simd.f(1e-6)));
    }
}

/// Top-down: final size of every node on one axis. One forward sweep.
/// Free space is shared out once by `grow` weight; a child stopped by its
/// `max` leaves its remainder unused instead of triggering another round.
pub fn resolve(t: *Tree, axis: Axis, viewport: f32) void {
    const a = @backingInt(axis);
    if (t.len == 0) return;
    const parent = t.c.parent;
    const size = t.c.size[a];
    const nat_ = t.c.nat[a];
    const fit_ = t.c.fit[a];
    const main_ = t.c.main[a];
    const gap_total = t.c.gap_total;
    const lo = t.c.pad_lo[a];
    const hi = t.c.pad_hi[a];
    const min = t.c.min[a];
    const max = t.c.max[a];
    const grow = t.c.grow[a];
    const grow_inv = t.c.grow_inv[a];
    const pct = t.c.pct[a];
    const flow = t.c.flow;
    const shrink = t.c.shrink;
    const used = t.c.used[a];

    size[0] = viewport;
    for (1..t.len) |i| {
        const p = parent[i];
        const nat = nat_[i];
        const inner = @max(size[p] - lo[p] - hi[p], 0);
        const main = main_[p];
        // Along the parent's main axis: natural size plus a share of what is left.
        const taken = fit_[p] + gap_total[p];
        const free = @max(inner - taken, 0);
        const share = free * grow[i] * grow_inv[p];
        // Across it: stretch when the node grows on this axis.
        const stretched = nat + b01(grow[i] > 0) * (inner - nat);
        const flowed = stretched + main * (nat + share - stretched);
        // A percentage replaces both.
        const has_pct = b01(pct[i] > 0);
        const of_parent = pct[i] * inner;
        const in_flow = flowed + has_pct * (of_parent - flowed);
        const floating = nat + has_pct * (of_parent - nat);
        const fl = flow[i];
        var s = floating + fl * (in_flow - floating);
        // Shrinkable nodes give way when the parent has no room for them.
        const room = @max(inner - main * (taken - nat), 0);
        s -= shrink[i] * fl * @max(s - room, 0);
        s = @min(@max(s, min[i]), max[i]);
        size[i] = s;
        used[p] += s * fl;
    }
}

/// Gathers the width layout gave each text run. Call after `resolve(.x)`;
/// the caller then rewrites `h` for runs that wrap.
pub fn textAvail(t: *const Tree, tx: *Texts) void {
    const c = &t.c;
    for (tx.c.node[0..tx.len], tx.c.avail[0..tx.len]) |node, *avail| {
        avail.* = c.size[0][node] - c.pad_lo[0][node] - c.pad_hi[0][node];
    }
}

/// Top-down: position of every node on both axes. One forward sweep.
pub fn place(t: *Tree) void {
    if (t.len == 0) return;
    const parent = t.c.parent;
    const pos = t.c.pos;
    const size = t.c.size;
    const lo = t.c.pad_lo;
    const hi = t.c.pad_hi;
    const used = t.c.used;
    const main = t.c.main;
    const scroll = t.c.scroll;
    const offset = t.c.offset;
    const gap = t.c.gap;
    const gap_total = t.c.gap_total;
    const cursor = t.c.cursor;
    const flow = t.c.flow;
    const align_main = t.c.align_main;
    const align_cross = t.c.align_cross;

    pos[0][0] = 0;
    pos[1][0] = 0;
    for (1..t.len) |i| {
        const p = parent[i];
        const fl = flow[i];
        inline for (0..2) |a| {
            const inner = size[a][p] - lo[a][p] - hi[a][p];
            const lead = @max(inner - used[a][p] - gap_total[p], 0) * align_main[p];
            const across = @max(inner - size[a][i], 0) * align_cross[p];
            const along = lead + cursor[p];
            const in_flow = across + main[a][p] * (along - across);
            pos[a][i] = pos[a][p] + lo[a][p] - scroll[a][p] + fl * in_flow + offset[a][i];
        }
        // Advance along whichever axis is the parent's main one.
        const step = size[0][i] * main[0][p] + size[1][i] * main[1][p];
        cursor[p] += (step + gap[p]) * fl;
    }
}

const testing = std.testing;
const mem = @import("../core/mem.zig");
const Strings = @import("../core/strings.zig").Strings;
const Id = types.Id;

/// The tree of the prototype's "tier 0 alone" test (prototype/example.zig), so every pass is
/// checked against the column values the prototype computes for it.
///
///   root  px(400) x px(300), pad 10, gap 5, clips
///   ├ bar   along x, fill x px(40), gap 4
///   │ ├ a   px(100) x fill
///   │ └ b   fill x fill
///   ├ col   px(100) x fit
///   │ └ para  shrinks; one text run of 24 bytes at 10 px that wraps
///   └ body  fill x fill
const Scene = struct {
    t: Tree,
    tx: Texts,

    const root = 0;
    const bar = 1;
    const a = 2;
    const b = 3;
    const col = 4;
    const para = 5;
    const body = 6;

    fn init(raw: []align(mem.column_align) u8) Scene {
        var carver: mem.Carver = .{ .buf = raw };
        var t = Tree.init(&carver, 64);
        var tx = Texts.init(&carver, 8);
        var strings: Strings = .{ .buf = carver.slice(u8, 256) };

        std.debug.assert(root == t.push(0, Id.from("ui.root"), &.{ .size = .{ .px(400), .px(300) }, .pad = @splat(10), .gap = 5, .clip = true }));
        std.debug.assert(bar == t.push(root, .none, &.{ .dir = .x, .size = .{ .fill, .px(40) }, .gap = 4 }));
        std.debug.assert(a == t.push(bar, Id.from("a"), &.{ .size = .{ .px(100), .fill } }));
        std.debug.assert(b == t.push(bar, Id.from("b"), &.{ .size = .{ .fill, .fill } }));
        t.seal(bar);
        std.debug.assert(col == t.push(root, .none, &.{ .size = .{ .px(100), .fit } }));
        std.debug.assert(para == t.push(col, .none, &.{ .shrink = true }));
        t.c.text[para] = tx.push(para, strings.add("twenty-four characters!!"), &.{ .px = 10, .wrap = true });
        t.seal(col);
        std.debug.assert(body == t.push(root, Id.from("body"), &.{ .size = .{ .fill, .fill } }));
        t.seal(root);
        // What fonts.Mono{ .advance = 0.5, .line = 1.2 }.measure writes: 24 bytes * 5 px, one
        // 12 px line. The font lane owns the measuring; layout only reads the extents.
        tx.c.w[0] = 120;
        tx.c.h[0] = 12;
        return .{ .t = t, .tx = tx };
    }
};

/// The sizing passes of the tier-0 example, with the caller's wrap step (two 12 px lines in the
/// 100 px textAvail gives the run) written in by hand.
fn sized(s: *Scene) void {
    prepare(&s.t);
    applyText(&s.t, &s.tx, .x);
    fit(&s.t, .x);
    resolve(&s.t, .x, 400);
    textAvail(&s.t, &s.tx);
    s.tx.c.w[0] = 100;
    s.tx.c.h[0] = 24;
    applyText(&s.t, &s.tx, .y);
    fit(&s.t, .y);
    resolve(&s.t, .y, 300);
}

fn expectCol(want: []const f32, col: []const f32) !void {
    try testing.expectEqualSlices(f32, want, col[0..want.len]);
}

test "prepare: zeroes the scratch columns and sets gap_total = gap * (in-flow children - 1)" {
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    var s = Scene.init(&raw);
    const c = &s.t.c;
    // Stale values from a previous frame, padding rows included.
    inline for (0..2) |ax| {
        @memset(c.fit[ax], 7);
        @memset(c.grow_sum[ax], 7);
        @memset(c.used[ax], 7);
    }
    @memset(c.cursor, 7);
    prepare(&s.t);
    const n = simd.padded(s.t.len);
    const zeros: [64]f32 = @splat(0);
    inline for (0..2) |ax| {
        try expectCol(zeros[0..n], c.fit[ax]);
        try expectCol(zeros[0..n], c.grow_sum[ax]);
        try expectCol(zeros[0..n], c.used[ax]);
    }
    try expectCol(zeros[0..n], c.cursor);
    // root: 3 children, gap 5; bar: 2 children, gap 4; col: one child; leaves: none.
    try expectCol(&.{ 10, 4, 0, 0, 0, 0, 0 }, c.gap_total);
}

test "applyText: writes each run's extent into its node's fit, on the axis asked for" {
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    var s = Scene.init(&raw);
    prepare(&s.t);
    applyText(&s.t, &s.tx, .x);
    try expectCol(&.{ 0, 0, 0, 0, 0, 120, 0 }, s.t.c.fit[0]);
    try expectCol(&.{ 0, 0, 0, 0, 0, 0, 0 }, s.t.c.fit[1]);
    applyText(&s.t, &s.tx, .y);
    try expectCol(&.{ 0, 0, 0, 0, 0, 12, 0 }, s.t.c.fit[1]);
}

test "fit: natural sizes bottom-up, summed along the main axis and maxed across it" {
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    var s = Scene.init(&raw);
    const c = &s.t.c;
    prepare(&s.t);
    applyText(&s.t, &s.tx, .x);
    fit(&s.t, .x);
    // bar lays a (100) and b (0) along x: 100 + gap 4 = 104 natural, while its fit is the sum 100.
    // col is px(100); para holds the 120 px run; root is px(400).
    try expectCol(&.{ 104, 100, 0, 0, 120, 120, 0 }, c.fit[0]);
    try expectCol(&.{ 400, 104, 100, 0, 100, 120, 0 }, c.nat[0]);
    // Grow weights of in-flow children: root has bar and body, bar has b.
    try expectCol(&.{ 2, 1, 0, 0, 0, 0, 0 }, c.grow_sum[0]);

    // Heights, with the run already wrapped to two 12 px lines.
    s.tx.c.h[0] = 24;
    applyText(&s.t, &s.tx, .y);
    fit(&s.t, .y);
    // root stacks along y: bar 40 + col 24 + body 0.
    try expectCol(&.{ 64, 0, 0, 0, 24, 24, 0 }, c.fit[1]);
    try expectCol(&.{ 300, 40, 0, 0, 24, 24, 0 }, c.nat[1]);
    try expectCol(&.{ 1, 2, 0, 0, 0, 0, 0 }, c.grow_sum[1]);
}

test "fit: grow_inv is 1 / grow_sum on every padded row, with 1e-6 as the floor" {
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    var s = Scene.init(&raw);
    const c = &s.t.c;
    prepare(&s.t);
    applyText(&s.t, &s.tx, .x);
    fit(&s.t, .x);
    // No growing children: 1 / 1e-6, finite, so resolve multiplies a zero share by it.
    try expectCol(&.{ 0.5, 1, 1e6, 1e6, 1e6, 1e6, 1e6 }, c.grow_inv[0]);
    const n = simd.padded(s.t.len);
    for (c.grow_inv[0][s.t.len..n]) |v| try testing.expectEqual(1e6, v);
    applyText(&s.t, &s.tx, .y);
    fit(&s.t, .y);
    try expectCol(&.{ 1, 0.5, 1e6, 1e6, 1e6, 1e6, 1e6 }, c.grow_inv[1]);
}

test "resolve: final sizes top-down; growers share free space, shrinkers give way" {
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    var s = Scene.init(&raw);
    const c = &s.t.c;
    prepare(&s.t);
    applyText(&s.t, &s.tx, .x);
    fit(&s.t, .x);
    resolve(&s.t, .x, 400);
    // Inside root's 380: bar and body stretch across; b takes 380 - 100 - 4; para shrinks from
    // its 120 px run to col's 100.
    try expectCol(&.{ 400, 380, 100, 276, 100, 100, 380 }, c.size[0]);
    try expectCol(&.{ 860, 376, 0, 0, 100, 0, 0 }, c.used[0]);

    s.tx.c.h[0] = 24; // wrapped to two lines in the 100 px it was given
    applyText(&s.t, &s.tx, .y);
    fit(&s.t, .y);
    resolve(&s.t, .y, 300);
    // body takes what root's 280 has left after bar 40, col 24 and two 5 px gaps.
    try expectCol(&.{ 300, 40, 40, 40, 24, 24, 206 }, c.size[1]);
    try expectCol(&.{ 270, 80, 0, 0, 24, 0, 0 }, c.used[1]);
}

test "textAvail: each run gets its node's resolved width inside the padding" {
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    var s = Scene.init(&raw);
    prepare(&s.t);
    applyText(&s.t, &s.tx, .x);
    fit(&s.t, .x);
    resolve(&s.t, .x, 400);
    textAvail(&s.t, &s.tx);
    // para shrank to 100, so its 120 px run has 100 px to wrap into.
    try expectCol(&.{100}, s.tx.c.avail);

    // Padding is taken off: give para 3 px on each side and gather again.
    s.t.c.pad_lo[0][Scene.para] = 3;
    s.t.c.pad_hi[0][Scene.para] = 3;
    textAvail(&s.t, &s.tx);
    try expectCol(&.{94}, s.tx.c.avail);
}

test "place: children follow the parent's cursor along its main axis, inside its padding" {
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    var s = Scene.init(&raw);
    const c = &s.t.c;
    sized(&s);
    place(&s.t);
    // a then b along bar's x with a 4 px gap; bar, col, body down root's y with 5 px gaps.
    try expectCol(&.{ 0, 10, 10, 114, 10, 10, 10 }, c.pos[0]);
    try expectCol(&.{ 0, 10, 10, 10, 55, 55, 84 }, c.pos[1]);
    try expectCol(&.{ 285, 384, 0, 0, 24, 0, 0 }, c.cursor);
}

test "place: floating nodes skip the cursor; offset and scroll move a node and its children" {
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    var s = Scene.init(&raw);
    const c = &s.t.c;
    sized(&s);
    c.flow[Scene.col] = 0; // col floats: placed at root's content origin, not after bar
    c.offset[0][Scene.col] = 7;
    c.scroll[1][Scene.col] = 3; // scrolls para up by 3
    place(&s.t);
    try testing.expectEqual(10 + 7, c.pos[0][Scene.col]);
    try testing.expectEqual(10, c.pos[1][Scene.col]);
    try testing.expectEqual(10 - 3, c.pos[1][Scene.para]);
    // body now follows bar directly: 10 + 40 + 5.
    try testing.expectEqual(55, c.pos[1][Scene.body]);
}
