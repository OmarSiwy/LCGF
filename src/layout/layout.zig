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
//!   finalize           SIMD + forward   pixel snap, clip, visibility
//!
//! The passes take the tree as `anytype`: a `*Tree`, or any value with the same `len`, `c` and
//! `x` fields whose columns index like slices (the comptime front end passes pointers to arrays,
//! read-only tables for the columns a pass only reads; src/comptime/layout.zig).

const std = @import("std");
const builtin = @import("builtin");
const simd = @import("../core/simd.zig");
const geometry = @import("../draw/geometry.zig");
const inherit = @import("../draw/inherit.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Flex = @import("flex.zig").Flex;
const wrap = @import("wrap.zig");
const baseline = @import("baseline.zig");
const FlexOptions = @import("flex.zig").FlexOptions;
const rounding = @import("rounding.zig");
const runs = @import("runs.zig");
const Axis = types.Axis;

const W = simd.lanes;
const b01 = simd.b2f;
const inf = types.inf;

/// SIMD. Clears per-frame scratch and derives `gap_total`.
/// How the frame's passes are called from code that knows its tree at compile time (the comptime
/// static pipeline): inlined into that instantiation, so its constant columns and axis fold
/// (docs/research/static-ports, about 16-49% fewer instructions per frame), except in builds
/// optimized for size, where one shared copy keeps microcontroller flash down (C0165).
pub const pass_call: std.builtin.CallModifier = if (inline_passes) .always_inline else .auto;
// Measured: routing a size build's calls through `@call(.auto, …)` here still grew the rv32
// demo by 3 KB, so size builds keep plain calls below.
const inline_passes = builtin.mode != .small;

pub fn prepare(t: anytype) void {
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
        const gaps = simd.maxF(simd.loadF(c.nkids, i) - simd.f(1), zero);
        simd.storeF(c.gap_total, i, simd.loadF(c.gap, i) * gaps);
    }
}

/// Scatters measured text extents into their leaf nodes for one axis.
pub fn applyText(t: anytype, tx: *const Texts, axis: Axis) void {
    const a = @backingInt(axis);
    const extents = [2][]const f32{ tx.c.w, tx.c.h };
    const src = extents[a];
    const dst = t.c.fit[a];
    for (tx.c.node[0..tx.len], src[0..tx.len]) |node, extent| dst[node] = extent;
}

/// Bottom-up: natural size of every node on one axis. One reverse sweep.
pub fn fit(t: anytype, axis: Axis) void {
    if (t.len == 0) return;
    fitOf(t, {}, axis, 0, t.len, .{});
}

/// `fit` with the extra sizing rules of `fx` (flex.zig).
pub fn fitFlex(t: *Tree, fx: *const Flex, axis: Axis) void {
    fitFlexOpts(t, fx, axis, .{});
}

/// `fitFlex` with the features of `opts` compiled in.
pub fn fitFlexOpts(t: *Tree, fx: *const Flex, axis: Axis, comptime opts: FlexOptions) void {
    if (t.len == 0) return;
    fitOf(t, fx, axis, 0, t.len, opts);
}

/// `fit` over rows [first, last), any `first < last <= len`. Rows after `first` fold into their
/// parents as in `fit`, last row first; row `first` gets its natural size and is not folded
/// into its own parent. `fit` and `grow_sum` of the rows must be cleared and their text extents
/// applied first, as `prepare` and `applyText` do for the whole tree.
///
/// What the range must satisfy: every descendant at or past `last` of a row in (first, last)
/// is already folded, and no row is folded twice in a frame. Two callers meet that:
/// incremental layout passes a whole subtree, `last = end[first]`; grid.zig sweeps the tree in
/// pieces from the end, [node, to) then [.., node + 1), so a piece's `first` is folded by the
/// next piece. `grow_inv` is rewritten over the whole vectors around [first, last); a row's
/// value there is final once all its children are folded, and is rewritten again by any later
/// call whose vectors cover it. The test "fitSpan, resolveSpan: pieces from any cut rows equal
/// the whole pass" pins this.
pub fn fitSpan(t: anytype, axis: Axis, first: u32, last: u32) void {
    fitOf(t, {}, axis, first, last, .{});
}

/// `fitSpan` with the extra sizing rules of `fx` (flex.zig), for grids on a flex page.
/// The rows past `last` that `fitOf` clears with whole vectors were folded by an earlier piece
/// (grid.zig), so their sums are kept around it. `opts` as `fitFlexOpts`.
// ponytail: saved and restored rather than an exact clear in fitOf, which moved stack slots in
// every page's frame (markup-zero-cost).
pub fn fitSpanFlex(t: *Tree, fx: *const Flex, axis: Axis, first: u32, last: u32, comptime opts: FlexOptions) void {
    const a = @backingInt(axis);
    const tail = simd.padded(last) - last;
    var keep: [3][W]f32 = undefined;
    inline for (.{ fx.c.shrink_sum[a], fx.c.base_kids, fx.c.below_kids }, 0..) |col, k| @memcpy(keep[k][0..tail], col[last..][0..tail]);
    fitOf(t, fx, axis, first, last, opts);
    inline for (.{ fx.c.shrink_sum[a], fx.c.base_kids, fx.c.below_kids }, 0..) |col, k| @memcpy(col[last..][0..tail], keep[k][0..tail]);
}

/// One body for every form: with `fx` void every flex term is compiled out, so `fit` keeps the
/// prototype's code; `first`/`last` select a subtree for incremental layout.
inline fn fitOf(t: anytype, fx: anytype, axis: Axis, first: u32, last: u32, comptime opts: FlexOptions) void {
    const flexed = @TypeOf(fx) != void;
    const a = @backingInt(axis);
    std.debug.assert(first < last and last <= t.len);
    if (flexed) @memset(fx.c.shrink_sum[a][first..simd.padded(last)], 0);
    if (flexed) @memset(fx.c.base_kids[first..simd.padded(last)], 0);
    if (flexed) @memset(fx.c.below_kids[first..simd.padded(last)], 0);
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

    // No flex rules, and a tree whose rows are slices: the fold takes a run of siblings at a
    // time (runs.zig), the same sums in the same order.
    const by_runs = comptime !flexed and @TypeOf(t) == *Tree and inline_passes;
    if (by_runs) runs.fit(t, a, first, last);
    var i: u32 = if (by_runs) first + 1 else last;
    while (i > first + 1) {
        i -= 1;
        // All descendants have larger rows, so fit_[i] is complete here.
        var content = fit_[i] + main[i] * gap_total[i];
        if (flexed) content += wrap.linesGap(t, fx, a, i);
        if (flexed) content = baseline.content(t, fx, a, i, content);
        var nat = content + lo[i] + hi[i];
        if (flexed) nat = fx.aspectNat(t, a, i, nat);
        nat = simd.minF(simd.maxF(nat, min[i]), max[i]);
        nat_[i] = nat;
        if (flexed) baseline.settle(t, fx, i, nat);
        // Fold into the parent: a sum along its main axis, a max across it.
        const p = parent[i];
        var contrib = nat * flow[i];
        if (flexed) contrib += fx.margin(a, i) * flow[i];
        // fit_[p] is the loop-carried value (every sibling folds into it): sum and max side by
        // side, then a select by the stacking direction, rather than max, sub, mul, add in a row.
        // `<` and a select is one maxss; @max would add a NaN fix-up (docs/perf/chains.md).
        const fp = fit_[p];
        const sum = fp + contrib;
        const mx = simd.selF(fp < contrib, contrib, fp);
        var folded = simd.selF(main[p] != 0, sum, mx);
        if (flexed) folded = wrap.foldLine(t, fx, a, i, p, contrib, folded, opts);
        fit_[p] = folded;
        grow_sum[p] += grow[i] * flow[i];
        if (flexed) fx.c.shrink_sum[a][p] += fx.scaledShrink(t, i, nat);
        if (flexed) baseline.fold(t, fx, i, p);
    }
    // The root (of the span) has no parent to fold into.
    var content = fit_[first] + main[first] * gap_total[first];
    if (flexed) content += wrap.linesGap(t, fx, a, first);
    if (flexed) content = baseline.content(t, fx, a, first, content);
    var nat = content + lo[first] + hi[first];
    if (flexed) nat = fx.aspectNat(t, a, first, nat);
    nat_[first] = simd.minF(simd.maxF(nat, min[first]), max[first]);
    if (flexed) baseline.settle(t, fx, first, nat_[first]);

    // SIMD: one reciprocal per node, so the top-down sweep has no division
    // on its parent-to-child dependency chain. Whole vectors around the span: grow_inv is a
    // function of grow_sum alone, so neighbouring rows get the value they already hold.
    const grow_inv = t.c.grow_inv[a];
    const n = simd.padded(last);
    var j: usize = std.mem.alignBackward(usize, first, W);
    while (j < n) : (j += W) {
        simd.storeF(grow_inv, j, simd.f(1) / simd.maxF(simd.loadF(grow_sum, j), simd.f(1e-6)));
    }
}

/// Top-down: final size of every node on one axis. One forward sweep.
/// Free space is shared out once by `grow` weight; a child stopped by its
/// `max` leaves its remainder unused instead of triggering another round.
pub fn resolve(t: anytype, axis: Axis, viewport: f32) void {
    if (t.len == 0) return;
    t.c.size[@backingInt(axis)][0] = viewport;
    resolveOf(t, {}, axis, 0, t.len);
}

/// `resolve` with the extra sizing rules of `fx` (flex.zig).
pub fn resolveFlex(t: *Tree, fx: *const Flex, axis: Axis, viewport: f32) void {
    if (t.len == 0) return;
    t.c.size[@backingInt(axis)][0] = viewport;
    resolveOf(t, fx, axis, 0, t.len);
}

/// `resolve` over rows [first, last), any `first < last <= len`: every row after `first` from
/// its parent, in row order, with `first`'s own size taken as given and only read. `used` of
/// the rows' parents must be cleared first, as `prepare` does for the whole tree.
///
/// What the range must satisfy: the parent of every row in (first, last) is already sized
/// (it is `first`, an earlier row of the range, or sized by an earlier call), and no row is
/// resolved twice in a frame, since each adds to its parent's `used`. Incremental layout
/// passes a whole subtree, `last = end[first]`; grid.zig resolves consecutive pieces
/// [from - 1, to) from the top. Same test as `fitSpan`.
pub fn resolveSpan(t: anytype, axis: Axis, first: u32, last: u32) void {
    resolveOf(t, {}, axis, first, last);
}

/// `resolveSpan` with the extra sizing rules of `fx` (flex.zig), for grids on a flex page.
pub fn resolveSpanFlex(t: *Tree, fx: *const Flex, axis: Axis, first: u32, last: u32) void {
    resolveOf(t, fx, axis, first, last);
}

inline fn resolveOf(t: anytype, fx: anytype, axis: Axis, first: u32, last: u32) void {
    const flexed = @TypeOf(fx) != void;
    const a = @backingInt(axis);
    std.debug.assert(first < last and last <= t.len);
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

    if (flexed) {
        fx.secondRound(t, a, first);
        fx.lineShares(t, first);
    }
    for (first + 1..last) |i| {
        const p = parent[i];
        const nat = nat_[i];
        const main = main_[p];
        const taken = fit_[p] + gap_total[p];
        const fl = flow[i];
        // Every sizing mode is linear in the parent's inner size and its free space:
        //   s = k0 + k1 * inner + k2 * max(inner - taken, 0)
        // Along the parent's main axis: natural size plus a `grow` share of the free space.
        // Across it: natural size, or all of `inner` when the node grows. A percentage of
        // `inner` replaces both; a floating node takes its natural size or its percentage.
        // None of k0..k2 depends on the parent's size, so only the three terms below sit on
        // the parent-to-child dependency chain.
        const has_pct = b01(pct[i] >= 0);
        const keep = 1 - has_pct;
        const across = (1 - main) * b01(grow[i] > 0);
        const k0 = nat * keep * (1 - fl * across);
        const k1 = has_pct * pct[i] + keep * fl * across;
        const k2 = keep * fl * main * grow[i] * grow_inv[p];
        const inner = simd.maxF(size[p] - lo[p] - hi[p], 0);
        var s = k0 + k1 * inner + k2 * simd.maxF(inner - taken, 0);
        // Flex only: margins are outside the node, so a stretched node fills `inner` less its
        // own; a grower may get a second-round share; a stretched child of a wrapping row fills
        // its line.
        const m = if (flexed) fx.margin(a, i) else 0;
        if (flexed) {
            const first_round = nat + grow[i] * grow_inv[p] * simd.maxF(inner - taken, 0);
            const line = wrap.lineCross(t, fx, a, i, p, inner);
            s += keep * fl * (main * fx.secondShare(t, a, i, p, first_round) + across * (line - m));
        }
        // Shrinkable nodes give way when the parent has no room for them.
        const room = simd.maxF(inner - main * (taken - nat) - (1 - main) * m, 0);
        var cut = shrink[i] * fl * simd.maxF(s - room, 0);
        if (flexed) cut += main * (fx.mainShrinkCut(t, a, i, p, taken - inner) - cut);
        // A wrapping row breaks a line instead of shrinking along it.
        if (flexed) cut *= 1 - fx.c.wrap[p] * main;
        s -= cut;
        if (flexed) s = fx.aspectSize(t, a, i, s);
        s = simd.minF(simd.maxF(s, min[i]), max[i]);
        size[i] = s;
        used[p] += (s + m) * fl;
        if (flexed) {
            fx.secondRound(t, a, i);
            fx.lineShares(t, i);
        }
    }
}

/// Gathers the width layout gave each text run. Call after `resolve(.x)`;
/// the caller then rewrites `h` for runs that wrap.
pub fn textAvail(t: anytype, tx: *Texts) void {
    const c = &t.c;
    for (tx.c.node[0..tx.len], tx.c.avail[0..tx.len]) |node, *avail| {
        avail.* = c.size[0][node] - c.pad_lo[0][node] - c.pad_hi[0][node];
    }
}

/// Top-down: position of every node on both axes. One forward sweep.
pub fn place(t: anytype) void {
    if (t.len == 0) return;
    t.c.pos[0][0] = 0;
    t.c.pos[1][0] = 0;
    if (inline_passes) @call(.always_inline, placeOf, .{ t, {}, 0, t.len, FlexOptions{} }) else placeOf(t, {}, 0, t.len, .{});
}

/// `place` with the extra placement rules of `fx` (flex.zig).
pub fn placeFlex(t: *Tree, fx: *const Flex) void {
    placeFlexOpts(t, fx, .{});
}

/// `placeFlex` with the features of `opts` compiled in.
pub fn placeFlexOpts(t: *Tree, fx: *const Flex, comptime opts: FlexOptions) void {
    if (t.len == 0) return;
    t.c.pos[0][0] = 0;
    t.c.pos[1][0] = 0;
    if (inline_passes) @call(.always_inline, placeOf, .{ t, fx, 0, t.len, opts }) else placeOf(t, fx, 0, t.len, opts);
}

/// `place` over the subtree [first, last), `last = end[first]` (incremental layout): every row
/// after `first` from its parent, with `first`'s own position taken as given. `cursor` of the
/// rows must be cleared first, as `prepare` does for the whole tree.
pub fn placeSpan(t: anytype, first: u32, last: u32) void {
    if (inline_passes) @call(.always_inline, placeOf, .{ t, {}, first, last, FlexOptions{} }) else placeOf(t, {}, first, last, .{});
}

fn placeOf(t: anytype, fx: anytype, first: u32, last: u32, comptime opts: FlexOptions) void {
    const flexed = @TypeOf(fx) != void;
    std.debug.assert(first < last and last <= t.len);
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

    for (first + 1..last) |i| {
        const p = parent[i];
        const fl = flow[i];
        if (flexed) wrap.openLine(t, fx, i, p);
        var free_main: f32 = 0;
        // Flex: the parent's lead factor holds its Style.main factor or its space share.
        const lead_k = if (flexed) fx.c.space_lead[p] else align_main[p];
        inline for (0..2) |a| {
            const inner = size[a][p] - lo[a][p] - hi[a][p];
            const free = simd.maxF(inner - used[a][p] - gap_total[p], 0);
            const lead = free * lead_k;
            if (flexed) free_main += free * main[a][p];
            var cross = align_cross[p];
            if (flexed) cross = fx.selfCross(i, cross);
            const m_lo = if (flexed) fx.c.margin_lo[a][i] else 0;
            const m = if (flexed) fx.margin(a, i) else 0;
            var across = simd.maxF(inner - size[a][i] - m, 0) * cross + m_lo;
            if (flexed and a == 1) across = baseline.across(t, fx, i, p, across);
            const along = lead + cursor[p] + m_lo;
            var in_flow = across + main[a][p] * (along - across);
            if (flexed) in_flow = wrap.inLine(t, fx, a, i, p, inner, cross, in_flow, opts);
            pos[a][i] = pos[a][p] + lo[a][p] - scroll[a][p] + fl * in_flow + offset[a][i];
        }
        // Advance along whichever axis is the parent's main one.
        var step = size[0][i] * main[0][p] + size[1][i] * main[1][p];
        if (flexed) step += fx.margin(0, i) * main[0][p] + fx.margin(1, i) * main[1][p];
        var advance = step + gap[p];
        if (flexed) advance = wrap.advance(t, fx, i, p, advance + free_main * fx.c.space_step[p]);
        cursor[p] += advance * fl;
    }
}

/// Legacy whole-pixel finalization. Use finalizeWith for a device grid or fractional layout.
pub fn finalize(t: anytype) void {
    finalizeWith(t, .{}) catch unreachable;
}

/// Snap cumulative endpoints on the selected device grid, then derive exact transforms,
/// ancestor clips and hit visibility. The uniform policy dispatch occurs outside the SIMD loop.
/// Invalid options leave geometry unchanged.
pub fn finalizeWith(t: anytype, options: rounding.Options) error{InvalidScale}!void {
    try options.validate();
    if (t.len == 0) return;
    if (inline_passes) try @call(.always_inline, finalizeSpanWith, .{ t, 0, t.len, options }) else try finalizeSpanWith(t, 0, t.len, options);
    @memset(t.c.sense[t.len..simd.padded(t.len)], 0);
}

/// Legacy finalization over an incremental subtree. Neighbouring SIMD lanes are recomputed
/// from their original positions, so shared endpoints use the same grid.
pub fn finalizeSpan(t: anytype, first: u32, last: u32) void {
    finalizeSpanWith(t, first, last, .{}) catch unreachable;
}

/// Puts the subtree under `node` on the pixel grid from `node`'s snapped origin instead of the
/// window's, after `finalize`: its descendants move by the distance `node` snapped, and are
/// finalized again. A comptime page snaps a hosted region's rect and then lays its content out
/// on a grid from that corner (`ct_interop.compose`), so a runtime page that builds the same
/// content in place calls this on the region's node to round its edges the same way.
pub fn snapSubtree(t: anytype, node: u32) void {
    const c = &t.c;
    const first = node + 1;
    const last = c.end[node];
    if (first >= last) return;
    inline for (0..2) |a| {
        const d = c.rect[a][node] - c.pos[a][node];
        for (c.pos[a][first..last]) |*p| p.* += d;
    }
    finalizeSpan(t, first, last);
}

pub fn finalizeSpanWith(t: anytype, first: u32, last: u32, options: rounding.Options) error{InvalidScale}!void {
    try options.validate();
    switch (options.mode) {
        inline else => |mode| if (inline_passes) @call(.always_inline, finalizeSpanMode, .{ t, first, last, mode, options }) else finalizeSpanMode(t, first, last, mode, options),
    }
}

fn finalizeSpanMode(t: anytype, first: u32, last: u32, comptime mode: rounding.Mode, options: rounding.Options) void {
    std.debug.assert(first < last and last <= t.len);
    const c = &t.c;
    const n = simd.padded(last);
    var j: usize = std.mem.alignBackward(usize, first, W);
    while (j < n) : (j += W) {
        const x = simd.loadF(c.pos[0], j);
        const y = simd.loadF(c.pos[1], j);
        simd.storeF(c.rect[0], j, rounding.vector(mode, x, options.scale, options.origin[0]));
        simd.storeF(c.rect[1], j, rounding.vector(mode, y, options.scale, options.origin[1]));
        simd.storeF(c.rect[2], j, rounding.vector(mode, x + simd.loadF(c.size[0], j), options.scale, options.origin[0]));
        simd.storeF(c.rect[3], j, rounding.vector(mode, y + simd.loadF(c.size[1], j), options.scale, options.origin[1]));
    }
    if (comptime @TypeOf(t) == *Tree) inherit.all(t);
    clipSpan(t, first, last, comptime @TypeOf(t) == *Tree and inline_passes);
}

/// The columns the clip half of finalize touches for each row, read into locals once so its
/// loops index them directly instead of reloading each slice from the struct.
inline fn clipCols(t: anytype) ClipCols(@TypeOf(t)) {
    return .{
        .rect = t.c.rect,
        .vis = t.c.vis,
        .child_clip = t.c.child_clip,
        .clips = t.c.clips,
        .visible = t.c.visible,
        .extra = t.c.extra,
        .xrow = t.x.row,
    };
}

/// `T`, or what it points at.
fn Pointee(comptime T: type) type {
    return if (@typeInfo(T) == .pointer) @typeInfo(T).pointer.child else T;
}

fn ClipCols(comptime T: type) type {
    const C = Pointee(@FieldType(Pointee(T), "c"));
    const X = Pointee(@FieldType(Pointee(T), "x"));
    return struct {
        rect: @FieldType(C, "rect"),
        vis: @FieldType(C, "vis"),
        child_clip: @FieldType(C, "child_clip"),
        clips: @FieldType(C, "clips"),
        visible: @FieldType(C, "visible"),
        extra: @FieldType(C, "extra"),
        xrow: @FieldType(X, "row"),
    };
}

/// The clip half of finalize over rows [first, last): each row's rect cut to its parent's clip.
/// `by_runs` takes a run of siblings at a time (`clipRuns`), `*Tree` only; the same columns
/// either way.
fn clipSpan(t: anytype, first: u32, last: u32, comptime by_runs: bool) void {
    std.debug.assert(first < last);
    std.debug.assert(last <= t.len);
    // The root is its own parent: it reads its own row before writing it, so that row starts as
    // "no clip". This replaces a per-row `i == 0` select on the chain below.
    if (first == 0) t.c.child_clip[0] = @splat(-inf);
    if (by_runs) return clipRuns(t, first, last);
    const k = clipCols(t);
    const parent = t.c.parent;
    for (first..last) |i| clipRow(t, k, i, k.child_clip[parent[i]]);
}

/// `clipSpan` run by run (runs.zig): a run's rows all take their parent's clip, so it is read
/// once. The root goes first and alone: its children share its parent row and read what it
/// writes.
fn clipRuns(t: *Tree, first: u32, last: u32) void {
    std.debug.assert(first < last);
    std.debug.assert(last <= t.len);
    const k = clipCols(t);
    const parent = t.c.parent;
    var i: usize = first;
    if (first == 0) {
        clipRow(t, k, 0, k.child_clip[0]);
        i = 1;
    }
    // Ends when every row is done: each turn does at least row `i`.
    while (i < last) {
        const p = parent[i];
        const wide = W > 1 and i + W <= last and parent[i + W - 1] == p and parent[i + 1] == p;
        if (wide) i = clipWide(t, i, last, p);
        const inherited: Edges = k.child_clip[p];
        while (i < last and parent[i] == p) : (i += 1) clipRow(t, k, i, inherited);
    }
}

/// A rect's four edges, or a clip's, as one value.
const Edges = @Vector(4, f32); // tidy: allow(fixed-vector-width) a rect's four values, not lanes

/// Row `i`'s screen rect cut to `inherited`, its parent's clip: `vis`, `visible`, and the clip
/// it hands its own children.
// tidy: allow-fn(inline-always-large) the pass's row body, shared by its two loops
// tidy: allow-fn(large-generic-function) one copy per tree type, as the loop it came from
inline fn clipRow(t: anytype, k: anytype, i: usize, inherited: Edges) void {
    const transformed = comptime @TypeOf(t) == *Tree or
        (@hasDecl(@TypeOf(t.*), "has_transforms") and @TypeOf(t.*).has_transforms);
    const sign: Edges = .{ 1, 1, -1, -1 };
    const everything: Edges = @splat(-inf);
    const c = &t.c;
    std.debug.assert(i < t.len);
    const local: [4]f32 = .{ k.rect[0][i], k.rect[1][i], k.rect[2][i], k.rect[3][i] };
    const inset = geometry.expand(local, @splat(-k.xrow[k.extra[i]].border));
    var screen = local;
    var inner_rect = inset;
    // A row whose scope is 0 inherits the defaults: it takes hits and nothing moves it, so
    // there is no participation to mask by and no matrix to load and test. One jump on
    // that (nearly every row: well predicted). A size build asks every row, as do the
    // comptime front end's views, whose scopes are tables.
    const scoped = !inline_passes or @TypeOf(t) != *Tree or c.scope[i] != 0;
    if (scoped) {
        @branchHint(.unlikely);
        c.sense[i] &= 0 -% @as(u8, @intFromBool(t.x.row[c.scope[i]].active_participation.hit));
        if (comptime transformed) {
            const world = geometry.worldAt(t, i);
            if (!inline_passes or !geometry.isIdentity(world)) {
                screen = geometry.transformRect(local, world);
                inner_rect = geometry.transformRect(inset, world);
            }
        }
    } else if (std.debug.runtime_safety) {
        std.debug.assert(t.x.row[0].active_participation.hit);
        std.debug.assert(geometry.isIdentity(t.x.row[0].world));
    }
    const r = @as(Edges, screen) * sign;
    // child_clip[i] feeds the next row whose parent is i, so the path from this load to
    // that store is the pass's latency chain: keep it to one max. The clip-or-not select
    // is on the other operand, off the chain (docs/perf/chains.md).
    const v = simd.maxF(r, inherited);
    // Children are clipped to the area inside the border. In the
    // (min, -max) form, insetting all four edges is one add.
    const clips: @Vector(4, bool) = @splat(k.clips[i] != 0);
    const inner = @select(f32, clips, @as(Edges, inner_rect) * sign, everything);
    k.child_clip[i] = simd.maxF(inherited, inner);
    const out = v * sign;
    k.vis[0][i] = out[0];
    k.vis[1][i] = out[1];
    k.vis[2][i] = out[2];
    k.vis[3][i] = out[3];
    k.visible[i] = @intFromBool(out[0] < out[2]) & @intFromBool(out[1] < out[3]);
}

/// `clipRow` for the whole vectors of a run: rows from `first` while each next `W` are all
/// children of `p` and none has an extras row, its own or inherited (nearly every row: no
/// border to inset by, nothing that moves it). Returns the row after; `clipRow` takes the rest
/// of the run. Out of line, so a short run pays for none of it.
noinline fn clipWide(t: *Tree, first: usize, last: usize, p: u32) usize {
    std.debug.assert(first + W <= last);
    std.debug.assert(p < first);
    const c = &t.c;
    const k = clipCols(t);
    const parent = c.parent;
    const scope = c.scope;
    const inherited: [4]f32 = k.child_clip[p];
    // Row 0 of the extras is the defaults, the row `clipRow` reads for each of these.
    const amount = simd.f(-t.x.row[0].border);
    const sign = [4]f32{ 1, 1, -1, -1 };
    const zero = simd.u(0);
    const no: simd.Bytes = @splat(0);
    const yes: simd.Bytes = @splat(1);
    var i = first;
    while (runs.whole(parent, i, last, p)) : (i += W) {
        const plain = (simd.loadU(k.extra, i) == zero) & (simd.loadU(scope, i) == zero);
        if (!@reduce(.And, plain)) break;
        var local: [4]simd.F = undefined;
        inline for (0..4) |e| local[e] = simd.loadF(k.rect[e], i);
        // geometry.expand by `amount` on every edge.
        var inset: [4]simd.F = undefined;
        inline for (0..2) |e| inset[e] = local[e] - amount;
        inline for (2..4) |e| inset[e] = local[e] + amount;
        const clips = @as(simd.Bytes, k.clips[i..][0..W].*) != no;
        var out: [4]simd.F = undefined;
        var handed: [4]simd.F = undefined;
        inline for (0..4) |e| {
            const edge = simd.f(inherited[e]);
            const flip = simd.f(sign[e]);
            out[e] = simd.maxF(local[e] * flip, edge) * flip;
            handed[e] = simd.maxF(edge, @select(f32, clips, inset[e] * flip, simd.f(-inf)));
            simd.storeF(k.vis[e], i, out[e]);
        }
        const shown = (out[0] < out[2]) & (out[1] < out[3]);
        k.visible[i..][0..W].* = @select(u8, shown, yes, no);
        // Each row's four edges side by side, as the column stores them.
        k.child_clip[i..][0..W].* = @bitCast(std.simd.interlace(handed));
    }
    return i;
}

/// Diagonal: every pass in order, for text that does not wrap (or whose
/// `w`/`h` the caller has already settled). `Frame.end` is this plus wrapping.
pub fn run(t: anytype, tx: *Texts, viewport: [2]f32) void {
    prepare(t);
    applyText(t, tx, .x);
    fit(t, .x);
    resolve(t, .x, viewport[0]);
    textAvail(t, tx);
    applyText(t, tx, .y);
    fit(t, .y);
    resolve(t, .y, viewport[1]);
    place(t);
    finalize(t);
}

/// `run` with the extra sizing rules of `fx` (flex.zig), and wrapping rows (wrap.zig). Text
/// baselines come from `baseline.apply`, which needs a per-run ascent column this call does not
/// have: call the passes one by one, as baseline.zig's tests do, to line text up.
pub fn runFlex(t: *Tree, fx: *const Flex, tx: *Texts, viewport: [2]f32) void {
    runFlexOpts(t, fx, tx, viewport, .{});
}

/// `runFlex` with the features of `opts` compiled in.
pub fn runFlexOpts(t: *Tree, fx: *const Flex, tx: *Texts, viewport: [2]f32, comptime opts: FlexOptions) void {
    prepare(t);
    applyText(t, tx, .x);
    fitFlexOpts(t, fx, .x, opts);
    resolveFlex(t, fx, .x, viewport[0]);
    wrap.wrapOpts(t, fx, opts);
    textAvail(t, tx);
    applyText(t, tx, .y);
    fitFlexOpts(t, fx, .y, opts);
    resolveFlex(t, fx, .y, viewport[1]);
    placeFlexOpts(t, fx, opts);
    finalize(t);
}

const testing = std.testing;
const mem = @import("../core/mem.zig");
const check = @import("check.zig");
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

test "finalize: snapped rects, clipped to the parent chain, with visibility" {
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    var s = Scene.init(&raw);
    const c = &s.t.c;
    sized(&s);
    place(&s.t);
    @memset(c.sense, 0xff); // stale padding rows
    finalize(&s.t);
    try expectCol(&.{ 0, 10, 10, 114, 10, 10, 10 }, c.rect[0]);
    try expectCol(&.{ 0, 10, 10, 10, 55, 55, 84 }, c.rect[1]);
    try expectCol(&.{ 400, 390, 110, 390, 110, 110, 390 }, c.rect[2]);
    try expectCol(&.{ 300, 50, 50, 50, 79, 79, 290 }, c.rect[3]);
    // Everything is inside root, so the clip changes nothing.
    inline for (0..4) |k| try expectCol(c.rect[k][0..s.t.len], c.vis[k]);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 1, 1, 1 }, c.visible[0..s.t.len]);
    // root clips with no border: its children inherit its rect, in (x0, y0, -x1, -y1) form.
    for (c.child_clip[0..s.t.len]) |cc| try testing.expectEqual([4]f32{ 0, 0, -400, -300 }, cc);
    const n = simd.padded(s.t.len);
    for (c.sense[s.t.len..n]) |v| try testing.expectEqual(0, v);
}

test "finalize: a clipping parent insets by its border and hides what lies outside" {
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    var s = Scene.init(&raw);
    const c = &s.t.c;
    sized(&s);
    c.clips[Scene.col] = 1;
    s.t.x.row[1].border = 2; // col's own extras row
    c.extra[Scene.col] = 1;
    c.offset[0][Scene.para] = 150; // para's 100 px start past col's right edge
    place(&s.t);
    c.pos[0][Scene.body] += 0.4; // sub-pixel positions round to whole pixels
    finalize(&s.t);
    try testing.expectEqual(10, c.rect[0][Scene.body]);
    try testing.expectEqual([4]f32{ 12, 57, -108, -77 }, c.child_clip[Scene.col]);
    try testing.expectEqual([4]f32{ 12, 57, -108, -77 }, c.child_clip[Scene.para]);
    try testing.expectEqual(160, c.rect[0][Scene.para]);
    try testing.expectEqual(160, c.vis[0][Scene.para]);
    try testing.expectEqual(108, c.vis[2][Scene.para]);
    try testing.expectEqual(0, c.visible[Scene.para]);
    try testing.expectEqual(1, c.visible[Scene.col]);
}

test "finalize: run by run and row by row give the same columns, on random trees with runs" {
    var raw: [1024 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 1000);
    var prng: std.Random.DefaultPrng = .init(0xc11b);
    var want_vis: [4][1000]f32 = undefined;
    var want_clip: [1000][4]f32 = undefined;
    var want_visible: [1000]u8 = undefined;
    var want_sense: [1000]u8 = undefined;
    for (0..200) |_| {
        check.randomRuns(&t, prng.random(), 1 + prng.random().uintLessThan(u32, t.cap));
        const n = t.len;
        prepare(&t);
        for ([2]Axis{ .x, .y }, [2]f32{ 1280, 800 }) |axis, viewport| {
            fit(&t, axis);
            resolve(&t, axis, viewport);
        }
        place(&t);
        finalize(&t);
        for (0..4) |e| @memcpy(want_vis[e][0..n], t.c.vis[e][0..n]);
        @memcpy(want_clip[0..n], t.c.child_clip[0..n]);
        @memcpy(want_visible[0..n], t.c.visible[0..n]);
        @memcpy(want_sense[0..n], t.c.sense[0..n]);
        // Reference: row by row over the same rects.
        for (0..4) |e| @memset(t.c.vis[e], std.math.nan(f32));
        @memset(t.c.visible, 0xff);
        clipSpan(&t, 0, n, false);
        for (0..4) |e| {
            const got: []const u32 = @ptrCast(t.c.vis[e][0..n]);
            try testing.expectEqualSlices(u32, @ptrCast(want_vis[e][0..n]), got);
        }
        const got_clip: []const u32 = @ptrCast(t.c.child_clip[0..n]);
        try testing.expectEqualSlices(u32, @ptrCast(want_clip[0..n]), got_clip);
        try testing.expectEqualSlices(u8, want_visible[0..n], t.c.visible[0..n]);
        try testing.expectEqualSlices(u8, want_sense[0..n], t.c.sense[0..n]);
    }
}

test "snapSubtree: a subtree rounds from its root's snapped corner, not the window's" {
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    var s = Scene.init(&raw);
    const c = &s.t.c;
    sized(&s);
    place(&s.t);
    // col at 55.5, which snaps to 56; para 0.75 below it, at 56.25, snaps to 56 from the
    // window's grid but to 56 + 1 from col's.
    for (c.pos[1][Scene.col..c.end[Scene.col]]) |*p| p.* += 0.5;
    c.pos[1][Scene.para] += 0.75;
    finalize(&s.t);
    try testing.expectEqual(56, c.rect[1][Scene.col]);
    try testing.expectEqual(56, c.rect[1][Scene.para]);
    const col_y = c.rect[1][Scene.col];
    const local = c.pos[1][Scene.para] - c.pos[1][Scene.col];
    snapSubtree(&s.t, Scene.col);
    // From col's snapped corner: its own rect stays, para lies at that corner plus round(local).
    try testing.expectEqual(col_y, c.rect[1][Scene.col]);
    try testing.expectEqual(col_y + @round(local), c.rect[1][Scene.para]);
    try testing.expectEqual(57, c.rect[1][Scene.para]);
    try testing.expectEqual(57, c.vis[1][Scene.para]);
}

test "run: the passes in order; with settled text it gives the tier-0 rects" {
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    var s = Scene.init(&raw);
    // The caller already knows the run's wrapped extent.
    s.tx.c.w[0] = 100;
    s.tx.c.h[0] = 24;
    run(&s.t, &s.tx, .{ 400, 300 });
    try testing.expectEqual(types.Rect{ .x0 = 10, .y0 = 10, .x1 = 390, .y1 = 50 }, s.t.rect(Scene.bar));
    try testing.expectEqual(types.Rect{ .x0 = 10, .y0 = 10, .x1 = 110, .y1 = 50 }, s.t.rect(Scene.a));
    try testing.expectEqual(types.Rect{ .x0 = 114, .y0 = 10, .x1 = 390, .y1 = 50 }, s.t.rect(Scene.b));
    try testing.expectEqual(types.Rect{ .x0 = 10, .y0 = 55, .x1 = 110, .y1 = 79 }, s.t.rect(Scene.para));
    try testing.expectEqual(types.Rect{ .x0 = 10, .y0 = 84, .x1 = 390, .y1 = 290 }, s.t.rect(Scene.body));
    try expectCol(&.{100}, s.tx.c.avail);
}

test "run: equals the tier-0 calls it is shorthand for" {
    var raw_a: [256 * 1024]u8 align(mem.column_align) = undefined;
    var raw_b: [256 * 1024]u8 align(mem.column_align) = undefined;
    var short = Scene.init(&raw_a);
    var long = Scene.init(&raw_b);
    run(&short.t, &short.tx, .{ 400, 300 });
    prepare(&long.t);
    applyText(&long.t, &long.tx, .x);
    fit(&long.t, .x);
    resolve(&long.t, .x, 400);
    textAvail(&long.t, &long.tx);
    applyText(&long.t, &long.tx, .y);
    fit(&long.t, .y);
    resolve(&long.t, .y, 300);
    place(&long.t);
    finalize(&long.t);
    const n = long.t.len;
    inline for (0..4) |k| {
        try expectCol(long.t.c.rect[k][0..n], short.t.c.rect[k]);
        try expectCol(long.t.c.vis[k][0..n], short.t.c.vis[k]);
    }
    // Unwrapped, the 120 px run is one 12 px line, so para is 12 high.
    try testing.expectEqual(12, short.t.rect(Scene.para).h());
}

// Ported from prototype/example.zig, including its last three lines, which check `hit.at` on the
// same columns.
test "tier 0 alone: no Context, caller sequences the passes" {
    const Mono = @import("../text/protocol.zig").Mono;
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 64);
    var tx = Texts.init(&carver, 8);
    var strings: Strings = .{ .buf = carver.slice(u8, 256) };

    const root = t.push(0, Id.from("ui.root"), &.{ .size = .{ .px(400), .px(300) }, .pad = @splat(10), .gap = 5, .clip = true });
    const bar = t.push(root, .none, &.{ .dir = .x, .size = .{ .fill, .px(40) }, .gap = 4 });
    const a = t.push(bar, Id.from("a"), &.{ .size = .{ .px(100), .fill } });
    const b = t.push(bar, Id.from("b"), &.{ .size = .{ .fill, .fill } });
    t.seal(bar);
    // A wrapping paragraph in a 100 px column.
    const col = t.push(root, .none, &.{ .size = .{ .px(100), .fit } });
    const para = t.push(col, .none, &.{ .shrink = true });
    const words = "twenty-four characters!!";
    t.c.text[para] = tx.push(para, strings.add(words), &.{ .px = 10, .wrap = true });
    t.seal(col);
    const body = t.push(root, Id.from("body"), &.{ .size = .{ .fill, .fill } });
    t.seal(root);
    t.c.sense[a] = @bitCast(types.Sense.button);
    t.c.sense[body] = @bitCast(types.Sense.button);

    // The same sequence Frame.end runs, spelled out.
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    font.measure(&tx);
    prepare(&t);
    applyText(&t, &tx, .x);
    fit(&t, .x);
    resolve(&t, .x, 400);
    textAvail(&t, &tx);
    font.wrap(&tx); // 24 bytes * 5 px = 120 px into 100 px: two lines
    applyText(&t, &tx, .y);
    fit(&t, .y);
    resolve(&t, .y, 300);
    place(&t);
    finalize(&t);

    try testing.expectEqual(types.Rect{ .x0 = 10, .y0 = 10, .x1 = 390, .y1 = 50 }, t.rect(bar));
    try testing.expectEqual(types.Rect{ .x0 = 10, .y0 = 10, .x1 = 110, .y1 = 50 }, t.rect(a));
    try testing.expectEqual(types.Rect{ .x0 = 114, .y0 = 10, .x1 = 390, .y1 = 50 }, t.rect(b));
    try testing.expectEqual(types.Rect{ .x0 = 10, .y0 = 55, .x1 = 110, .y1 = 79 }, t.rect(para));
    try testing.expectEqual(types.Rect{ .x0 = 10, .y0 = 84, .x1 = 390, .y1 = 290 }, t.rect(body));

    // Hit testing reads the same columns.
    const hit = @import("../interact/hit.zig");
    try testing.expectEqual(a, hit.at(&t, 50, 20, .any));
    try testing.expectEqual(body, hit.at(&t, 50, 100, .any));
    try testing.expectEqual(types.none, hit.at(&t, 200, 20, .any));
}

test "fitSpan, resolveSpan: pieces from any cut rows equal the whole pass" {
    // Every set of cut rows in 1..6 of the tier-0 scene: fit in pieces from the end as grid
    // does, [cut, to) then [.., cut + 1); resolve in pieces from the top, [from - 1, to).
    var raw_a: [256 * 1024]u8 align(mem.column_align) = undefined;
    var raw_b: [256 * 1024]u8 align(mem.column_align) = undefined;
    var whole = Scene.init(&raw_a);
    sized(&whole);
    const n = whole.t.len;
    for (0..64) |mask| {
        var parts = Scene.init(&raw_b);
        const t = &parts.t;
        prepare(t);
        inline for (.{ Axis.x, Axis.y }, .{ 400, 300 }) |axis, viewport| {
            const a = @backingInt(axis);
            if (axis == .y) {
                textAvail(t, &parts.tx);
                parts.tx.c.w[0] = 100;
                parts.tx.c.h[0] = 24;
            }
            applyText(t, &parts.tx, axis);
            var to: u32 = n;
            var row: u32 = n - 1;
            while (row >= 1) : (row -= 1) {
                if ((mask >> @intCast(row - 1)) & 1 == 0) continue;
                fitSpan(t, axis, row, to);
                to = row + 1;
            }
            fitSpan(t, axis, 0, to);
            try expectCol(whole.t.c.fit[a][0..n], t.c.fit[a]);
            try expectCol(whole.t.c.nat[a][0..n], t.c.nat[a]);
            try expectCol(whole.t.c.grow_inv[a][0..simd.padded(n)], t.c.grow_inv[a]);

            t.c.size[a][0] = viewport;
            var from: u32 = 1;
            for (1..n) |cut| {
                if ((mask >> @intCast(cut - 1)) & 1 == 0) continue;
                resolveSpan(t, axis, from - 1, @intCast(cut));
                from = @intCast(cut);
            }
            resolveSpan(t, axis, from - 1, n);
            try expectCol(whole.t.c.size[a][0..n], t.c.size[a]);
            try expectCol(whole.t.c.used[a][0..n], t.c.used[a]);
        }
    }
}

test "resolve: pct(0) is zero of the parent, not the content's size" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 8);
    var tx = Texts.init(&carver, 1);
    const root = t.push(0, .none, &.{ .dir = .x });
    const pane = t.push(root, .none, &.{ .size = .{ .pct(0), .pct(0) } });
    _ = t.push(pane, .none, &.{ .size = .{ .px(30), .px(20) } });
    t.seal(pane);
    t.seal(root);
    run(&t, &tx, .{ 200, 100 });
    try testing.expectEqual(types.Rect{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 }, t.rect(pane));
}
