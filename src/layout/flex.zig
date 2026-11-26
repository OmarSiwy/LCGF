//! Flex: sizing rules beyond the prototype's fit / px / grow / pct, as extra per-node columns the
//! caller carves next to the tree and passes to `layout.fitFlex`, `resolveFlex` and `runFlex`.
//! The plain passes never read them. Also the rule-by-rule tests of the min, max and percent rules
//! every node already has. Tier 0.
//!
//! The columns live here rather than in `Tree.Columns` because the tree and `Style` belong to
//! another lane; a front end writes them with `set` after each `Tree.push`.

const std = @import("std");
const layout = @import("layout.zig");
const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const b01 = simd.b2f;

pub const Flex = struct {
    c: Columns,

    /// One row per tree node, `simd.rows(cap)` rows each.
    pub const Columns = struct {
        // ---- inputs, written by `set`
        /// Width over height; 0 for none.
        aspect: []f32,
        /// Shrink weight (CSS `flex-shrink`) of a node whose `Style.shrink` is set.
        shrink: []f32,
        /// 1.0 when the node shares out free space a second time; 0.0 for the prototype's one round.
        regrow: []f32,
        /// Cross-axis alignment factor (`Align.factor`) that replaces the parent's for this
        /// node; -1 to use the parent's.
        self_cross: []f32,
        /// Space outside the node before and after it on each axis (left, top / right, bottom).
        margin_lo: [2][]f32,
        margin_hi: [2][]f32,
        /// 1.0 for a row (main axis x) whose in-flow children wrap onto further lines.
        wrap: []f32,
        /// Where a wrapping row's lines sit across it when they leave space (`Align.factor`).
        align_lines: []f32,
        /// 1.0 for a row that lines its children up by their first baselines.
        align_base: []f32,
        /// How the node shares its free main-axis space between its children (`Space`).
        space: []u32,
        /// How a wrapping row shares the height its lines leave (`LineSpace`).
        line_space: []u32,

        // ---- scratch, rewritten by the passes every frame
        /// What placeFlex multiplies a node's free main-axis space by for the lead before its
        /// first child (its `Style.main` factor, or its `space` share) and for the step after
        /// each child (`wrap`, from `nkids`).
        space_lead: []f32,
        space_step: []f32,
        /// A wrapping row's spare height shares (`resolveFlex` on the row, from `nlines`):
        /// before its first line, after each line, and added to each line's height.
        line_lead: []f32,
        line_step: []f32,
        line_extra: []f32,
        /// Sum over in-flow children of shrink flag * weight * natural size, per axis (`fitFlex`).
        shrink_sum: [2][]f32,
        /// Free space per unit of grow weight that the second round hands to each child that its
        /// max did not stop (`resolveFlex`, rewritten per axis).
        grow_extra: []f32,

        // ---- wrapping (wrap.zig). A line is a row of these columns, indexed by line number,
        //      not by node: a frame has at most `len` lines, so the same row count holds them.
        //      Every node gets a line: the in-flow children of a wrapping row the line `wrap`
        //      put them on, every other node `sink`, a spare row past `cap` that collects the
        //      writes of nodes outside any wrapping row so no pass has to branch on "wraps?".
        /// Line of the node in its parent; `sink` when the parent does not wrap.
        line: []u32,
        /// 1.0 when the node is the first of its line.
        head: []f32,
        /// Line a wrapping row is filling while `wrap` walks its children.
        open: []u32,
        /// Number of lines of a wrapping row, as f32 because it only feeds arithmetic.
        nlines: []f32,
        /// Per line: main-axis length of the line's children, margins and gaps.
        line_main: []f32,
        /// Per line: children on the line.
        line_count: []f32,
        /// Per line: cross size, the largest cross extent of its children (`fitFlex`, y).
        line_cross: []f32,
        /// Per line: cross offset inside the row's content box (`placeFlex`).
        line_off: []f32,
        /// Per line: main-axis cursor (`placeFlex`).
        line_cursor: []f32,

        // ---- baselines (baseline.zig)
        /// Distance from the top of the node's text run to its first baseline, scattered from
        /// the caller's per-run column by `baseline.apply`; read when `text_has` is 1.
        text_base: []f32,
        /// 1.0 when the node carries a text run this frame (`baseline.apply`).
        text_has: []f32,
        /// Distance from the node's top edge to its first baseline (`fitFlex`, y).
        base: []f32,
        /// What the node's in-flow children give it as a baseline, inside its padding: the
        /// first child's in a column, the lowest in a row (`fitFlex`, y).
        base_kids: []f32,
        /// The largest extent of an in-flow child below its baseline, bottom margin included
        /// (`fitFlex`, y): with `base_kids` the height a baseline-aligned row needs.
        below_kids: []f32,
    };

    /// The row that collects the line writes of nodes outside any wrapping row: one past the
    /// last line a tree of `cap` nodes can have, inside the padding `simd.rows` adds.
    pub fn sink(fx: *const Flex) u32 {
        return @intCast(fx.c.line.len - 1);
    }

    /// What `set` writes for one node. The defaults change nothing.
    pub const Style = struct {
        /// Width over height (CSS `aspect-ratio`); 0 for none. The height follows the resolved
        /// width, replacing content, grow, stretch and percent on y; a fit-sized width follows a
        /// px height. min and max still clamp the result.
        aspect: f32 = 0,
        /// When the children of a parent overflow its main axis, each shrinkable child gives up
        /// a part of the overflow in proportion to weight * natural size, as CSS does. Only
        /// nodes with `Style.shrink` shrink; across the main axis the prototype's rule stays (a
        /// shrinkable node narrows to the parent's inner size). One round: a node stopped by its
        /// min leaves the rest of its part overflowing.
        shrink: f32 = 1,
        /// Share free space along the main axis in two rounds instead of one: what growers
        /// stopped by their max leave in the first round goes to the other growers by weight.
        /// Bounded to two; a grower stopped in the second round leaves its rest unused.
        regrow: bool = false,
        /// Where this node sits across its parent's main axis, instead of the parent's
        /// `Style.cross` (CSS `align-self`). null keeps the parent's.
        cross: ?types.Align = null,
        /// left, top, right, bottom: space kept outside the node. In flow it adds to what the
        /// node takes from its parent (natural size, used space, the cursor step) and is taken
        /// off the room it may stretch or shrink into; the node sits past its leading margin. A
        /// floating node ignores it. Margins do not collapse.
        margin: [4]f32 = @splat(0),
        /// For a row (`Style.dir = .x`): children that do not fit on the current line start a
        /// new one below it, as CSS `flex-wrap: wrap` (wrap.zig). Ignored on a column.
        wrap: bool = false,
        /// Where a wrapping row's lines sit across it when they leave space (CSS
        /// `align-content`, without stretch).
        lines: types.Align = .start,
        /// For a row that does not wrap: its in-flow children sit so that their first baselines
        /// (baseline.zig) are on one line, as CSS `align-items: baseline`, and the row is as
        /// tall as the highest part above that line plus the deepest below it. A child with its
        /// own `cross` is placed by that instead (it still counts toward the row's baseline and
        /// height, unlike CSS). Ignored on a column and on a wrapping row.
        baseline: bool = false,
        /// Free space along the main axis between this node's in-flow children instead of
        /// before them (CSS `justify-content: space-*`), in place of `Style.main`. Ignored on
        /// a wrapping row.
        space: Space = .none,
        /// For a wrapping row: the height its lines leave goes between them or into them (CSS
        /// `align-content: space-*` and `stretch`), in place of `lines`.
        line_space: LineSpace = .none,
    };

    /// `Style.line_space`: where a wrapping row's spare height goes, for `n` lines. The
    /// tables are `Space`'s, plus `stretch`, which adds an equal share to every line's height.
    pub const LineSpace = enum(u8) {
        none,
        between,
        around,
        evenly,
        stretch,

        pub const lines_k = [5]f32{ 1, 0, 0, 0, 0 };
        pub const lead_k = [5]f32{ 0, 0, 0.5, 1, 0 };
        pub const step_k = [5]f32{ 0, 1, 1, 1, 0 };
        pub const stretch_k = [5]f32{ 0, 0, 0, 0, 1 };
        pub const per_n = [5]f32{ 1, -1, 0, 1, 0 };
    };

    /// `Style.space`: where free main-axis space goes, for `n` in-flow children.
    pub const Space = enum(u8) {
        none,
        /// Between the children only (`space-between`); one child sits at the start.
        between,
        /// Half a share before the first and after the last, one between (`space-around`).
        around,
        /// `n + 1` equal shares, at the ends and between (`space-evenly`).
        evenly,

        /// Free space before the first child: `free * lead_k / max(n + per_n, 1)`; between
        /// two children: `free * step_k / max(n + per_n, 1)`. One divide per container.
        /// Indexed by the tag.
        const main_k = [4]f32{ 1, 0, 0, 0 };
        const lead_k = [4]f32{ 0, 0, 0.5, 1 };
        const step_k = [4]f32{ 0, 1, 1, 1 };
        const per_n = [4]f32{ 1, -1, 0, 1 };
    };

    /// Carves the columns from `carver` for a tree of `cap` nodes, every row `Style{}`.
    pub fn init(carver: *mem.Carver, cap: u32) Flex {
        var fx: Flex = .{ .c = carver.columns(Columns, simd.rows(cap)) };
        for (0..fx.c.aspect.len) |i| fx.set(@intCast(i), &.{});
        return fx;
    }

    /// Writes node `i`'s row.
    pub fn set(fx: *Flex, i: u32, s: *const Style) void {
        fx.c.aspect[i] = s.aspect;
        fx.c.shrink[i] = s.shrink;
        fx.c.regrow[i] = b01(s.regrow);
        inline for (0..2) |a| {
            fx.c.margin_lo[a][i] = s.margin[a];
            fx.c.margin_hi[a][i] = s.margin[a + 2];
        }
        fx.c.wrap[i] = b01(s.wrap);
        fx.c.align_lines[i] = types.Align.factor[@backingInt(s.lines)];
        fx.c.align_base[i] = b01(s.baseline);
        fx.c.self_cross[i] = if (s.cross) |c| types.Align.factor[@backingInt(c)] else -1;
        fx.c.space[i] = @backingInt(s.space);
        fx.c.line_space[i] = @backingInt(s.line_space);
    }

    /// wrap, once per node: node `i`'s lead and step factors over its in-flow children
    /// (`Style.space`, or its `Style.main` factor without one). Table lookups, no branch, so
    /// placeFlex adds one multiply per child for them.
    pub inline fn spaceShares(fx: *const Flex, t: *const Tree, i: usize) void {
        const k = fx.c.space[i];
        const n = t.c.nkids[i];
        const per = 1 / @max(n + Space.per_n[k], 1);
        fx.c.space_lead[i] = t.c.align_main[i] * Space.main_k[k] + Space.lead_k[k] * per;
        fx.c.space_step[i] = Space.step_k[k] * per;
    }

    /// resolve, once node `i` has its size: how a wrapping row shares the height its lines
    /// leave (`Style.lines` and `line_space`), for placeFlex and its children's resolve.
    pub inline fn lineShares(fx: *const Flex, t: *const Tree, i: usize) void {
        const c = &t.c;
        const f = &fx.c;
        const S = LineSpace;
        const k = f.line_space[i];
        const lines_gap = f.wrap[i] * c.main[0][i] * @max(f.nlines[i] - 1, 0) * c.gap[i];
        const spare = @max(c.size[1][i] - c.pad_lo[1][i] - c.pad_hi[1][i] - c.fit[1][i] - lines_gap, 0);
        const per = spare / @max(f.nlines[i] + S.per_n[k], 1);
        f.line_lead[i] = spare * f.align_lines[i] * S.lines_k[k] + S.lead_k[k] * per;
        f.line_step[i] = S.step_k[k] * per;
        f.line_extra[i] = S.stretch_k[k] * per;
    }

    /// resolve, once node `p` has its size: the first round's leftover per unit of weight that
    /// is still free to grow, for `secondShare`. The walk over p's children runs only when p
    /// opted in (its bound is p + 1 otherwise), so the loop is loop control, not a branch per
    /// row, and costs nothing for the prototype's one round.
    pub inline fn secondRound(fx: *const Flex, t: *const Tree, a: u1, p: usize) void {
        const c = &t.c;
        const inner = @max(c.size[a][p] - c.pad_lo[a][p] - c.pad_hi[a][p], 0);
        const free = @max(inner - c.fit[a][p] - c.gap_total[p], 0);
        const per_weight = free * c.grow_inv[a][p];
        const opted = fx.c.regrow[p] * c.main[a][p];
        // `opted` is exactly 0 or 1, so the bound is a product with no compare: 0.18 compiles a
        // select on `opted > 0` into a jump around the load of end[p].
        const first_child: u32 = @intCast(p + 1);
        const stop = first_child + @as(u32, @intFromFloat(opted)) * (c.end[p] - first_child);
        var left: f32 = 0;
        var weight: f32 = 0;
        var j = first_child;
        while (j < stop) : (j = c.end[j]) {
            const g = c.grow[a][j] * c.flow[j] * b01(c.pct[a][j] < 0);
            const first = c.nat[a][j] + per_weight * g;
            left += @max(first - c.max[a][j], 0);
            weight += g * b01(first < c.max[a][j]);
        }
        fx.c.grow_extra[p] = opted * left / @max(weight, 1e-6);
    }

    /// resolve: node `i`'s second-round share, given its first-round size `first`.
    pub inline fn secondShare(fx: *const Flex, t: *const Tree, a: u1, i: usize, p: usize, first: f32) f32 {
        return t.c.grow[a][i] * fx.c.grow_extra[p] * b01(first < t.c.max[a][i]);
    }

    /// Both margins of node `i` on axis `a`: what it takes beyond its own size.
    pub inline fn margin(fx: *const Flex, a: u1, i: usize) f32 {
        return fx.c.margin_lo[a][i] + fx.c.margin_hi[a][i];
    }

    /// place: the cross-axis factor for node `i`, its own or the parent's `parent_factor`.
    pub inline fn selfCross(fx: *const Flex, i: usize, parent_factor: f32) f32 {
        const own = fx.c.self_cross[i];
        return parent_factor + b01(own >= 0) * (own - parent_factor);
    }

    /// fit: what node `i` adds to its parent's `shrink_sum`.
    pub inline fn scaledShrink(fx: *const Flex, t: *const Tree, i: usize, nat: f32) f32 {
        return t.c.shrink[i] * fx.c.shrink[i] * nat * t.c.flow[i];
    }

    /// resolve, along the parent's main axis: node `i`'s part of the parent's overflow
    /// (`over` = natural content minus inner size).
    pub inline fn mainShrinkCut(fx: *const Flex, t: *const Tree, a: u1, i: usize, p: usize, over: f32) f32 {
        const part = fx.scaledShrink(t, i, t.c.nat[a][i]) / @max(fx.c.shrink_sum[a][p], 1e-6);
        return @max(over, 0) * part;
    }

    /// fit: on y the height the resolved width gives; on x the width a px height gives (min and
    /// max equal on y) when the node has a ratio. Otherwise `nat`. A blend, not a select: 0.18
    /// turns a select here into a branch around the whole row (census). Both candidates are
    /// finite, so the zero coefficient cancels them.
    pub inline fn aspectNat(fx: *const Flex, t: *const Tree, a: u1, i: usize, nat: f32) f32 {
        const r = fx.c.aspect[i];
        const fixed_h = b01(t.c.min[1][i] == t.c.max[1][i]);
        const on_y: f32 = @floatFromInt(a);
        const want = t.c.min[1][i] * r + on_y * (t.c.size[0][i] / @max(r, 1e-6) - t.c.min[1][i] * r);
        const apply = b01(r > 0) * (fixed_h + on_y * (1 - fixed_h));
        return nat + apply * (want - nat);
    }

    /// resolve: on y the height the resolved width gives when the node has a ratio.
    pub inline fn aspectSize(fx: *const Flex, t: *const Tree, a: u1, i: usize, s: f32) f32 {
        const r = fx.c.aspect[i];
        const on_y: f32 = @floatFromInt(a);
        return s + on_y * b01(r > 0) * (t.c.size[0][i] / @max(r, 1e-6) - s);
    }
};

const testing = std.testing;

/// A small tree and an empty text list in one caller-owned buffer, for the rule tests.
const Scene = struct {
    raw: [96 * 1024]u8 align(mem.column_align) = undefined,
    t: Tree = undefined,
    tx: Texts = undefined,
    fx: Flex = undefined,

    fn init(s: *Scene) *Tree {
        var carver: mem.Carver = .{ .buf = &s.raw };
        s.t = Tree.init(&carver, 16);
        s.tx = Texts.init(&carver, 1);
        s.fx = Flex.init(&carver, 16);
        return &s.t;
    }
    fn run(s: *Scene, w: f32, h: f32) void {
        s.t.seal(0);
        layout.run(&s.t, &s.tx, .{ w, h });
    }
    fn runFlex(s: *Scene, w: f32, h: f32) void {
        s.t.seal(0);
        layout.runFlex(&s.t, &s.fx, &s.tx, .{ w, h });
    }
    fn size(s: *const Scene, i: u32) [2]f32 {
        return .{ s.t.c.size[0][i], s.t.c.size[1][i] };
    }
};

test "min: a node is never smaller than its min, even with no content" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(100) } });
    const a = t.push(root, .none, &.{ .min = .{ 50, 30 } });
    s.run(200, 100);
    try testing.expectEqual([2]f32{ 50, 30 }, s.size(a));
}

test "min: a fit parent's natural size includes its children's min" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(100) } });
    const box = t.push(root, .none, &.{ .pad = @splat(5) });
    _ = t.push(box, .none, &.{ .min = .{ 40, 20 } });
    t.seal(box);
    s.run(200, 100);
    try testing.expectEqual([2]f32{ 50, 30 }, s.size(box));
}

test "max: caps the natural size; the content overflows instead of growing the node" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(100) } });
    const box = t.push(root, .none, &.{ .max = .{ 40, 25 } });
    const big = t.push(box, .none, &.{ .size = .{ .px(100), .px(60) } });
    t.seal(box);
    s.run(200, 100);
    try testing.expectEqual([2]f32{ 40, 25 }, s.size(box));
    try testing.expectEqual([2]f32{ 100, 60 }, s.size(big));
}

test "max: caps a grower; its unused share is not handed to the others (one round)" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(200), .px(100) } });
    const a = t.push(root, .none, &.{ .size = .{ .fill, .fill }, .max = .{ 30, 50 } });
    const b = t.push(root, .none, &.{ .size = .{ .fill, .fill } });
    s.run(200, 100);
    try testing.expectEqual([2]f32{ 30, 50 }, s.size(a));
    try testing.expectEqual([2]f32{ 100, 100 }, s.size(b));
    try testing.expectEqual(130, t.c.used[0][root]);
}

test "min and max: when they disagree, max wins" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(100) } });
    const a = t.push(root, .none, &.{ .min = .{ 80, 80 }, .max = .{ 50, 60 } });
    s.run(200, 100);
    try testing.expectEqual([2]f32{ 50, 60 }, s.size(a));
}

test "percent: a fraction of the parent's inner size on both axes" {
    var s: Scene = .{};
    const t = s.init();
    // inner: 200 - 2 * 10 = 180 wide, 100 - 4 - 16 = 80 high.
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(200), .px(100) }, .pad = .{ 10, 4, 10, 16 } });
    const a = t.push(root, .none, &.{ .size = .{ .pct(0.5), .pct(0.25) } });
    const b = t.push(root, .none, &.{ .size = .{ .pct(0.25), .pct(1) } });
    s.run(200, 100);
    // Along the main axis (x) and across it (y) alike.
    try testing.expectEqual([2]f32{ 90, 20 }, s.size(a));
    try testing.expectEqual([2]f32{ 45, 80 }, s.size(b));
    try testing.expectEqual(10 + 90, t.c.pos[0][b]);
}

test "percent: replaces the grow share and is still clamped by min and max" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(200), .px(100) } });
    const a = t.push(root, .none, &.{ .size = .{ .pct(0.5), .pct(0.5) }, .max = .{ 60, types.inf }, .min = .{ 0, 70 } });
    const b = t.push(root, .none, &.{ .size = .{ .pct(0.1), .fit } });
    s.run(200, 100);
    try testing.expectEqual([2]f32{ 60, 70 }, s.size(a));
    try testing.expectEqual(20, s.size(b)[0]);
}

test "percent: a floating node takes its fraction of the same inner size" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(100) }, .pad = @splat(20) });
    const a = t.push(root, .none, &.{ .float = true, .size = .{ .pct(0.5), .pct(0.5) } });
    s.run(200, 100);
    try testing.expectEqual([2]f32{ 80, 30 }, s.size(a));
    try testing.expectEqual([2]f32{ 20, 20 }, [2]f32{ t.c.pos[0][a], t.c.pos[1][a] });
}

test "percent: in a fit parent it is taken of the size the other children gave the parent" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(100) } });
    const col = t.push(root, .none, &.{});
    _ = t.push(col, .none, &.{ .size = .{ .px(80), .px(10) } });
    const half = t.push(col, .none, &.{ .size = .{ .pct(0.5), .px(10) } });
    t.seal(col);
    s.run(200, 100);
    // The percentage contributes nothing to col's natural width, so col is 80 and half is 40.
    try testing.expectEqual(80, s.size(col)[0]);
    try testing.expectEqual(40, s.size(half)[0]);
}

test "aspect: the height follows the resolved width, over content, grow and stretch" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(300) } });
    // Stretched across root's x (fill), grows on y, has a tall child: the ratio still decides y.
    const a = t.push(root, .none, &.{ .size = .{ .fill, .fill } });
    _ = t.push(a, .none, &.{ .size = .{ .px(10), .px(250) } });
    t.seal(a);
    s.fx.set(a, &.{ .aspect = 2 });
    s.runFlex(200, 300);
    try testing.expectEqual([2]f32{ 200, 100 }, s.size(a));
}

test "aspect: a fit parent sums the derived height" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(300) } });
    const col = t.push(root, .none, &.{ .size = .{ .px(120), .fit } });
    const img = t.push(col, .none, &.{ .size = .{ .fill, .fit } });
    _ = t.push(col, .none, &.{ .size = .{ .fill, .px(10) } });
    t.seal(col);
    s.fx.set(img, &.{ .aspect = 4.0 / 3.0 });
    s.runFlex(200, 300);
    try testing.expectEqual([2]f32{ 120, 90 }, s.size(img));
    try testing.expectEqual(100, s.size(col)[1]);
}

test "aspect: a fit width follows a px height" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(200), .px(300) } });
    const a = t.push(root, .none, &.{ .size = .{ .fit, .px(40) } });
    const b = t.push(root, .none, &.{ .size = .{ .fit, .px(40) } });
    s.fx.set(a, &.{ .aspect = 1.5 });
    s.runFlex(200, 300);
    try testing.expectEqual([2]f32{ 60, 40 }, s.size(a));
    try testing.expectEqual(60, t.c.pos[0][b]);
}

test "aspect: min and max on y clamp the derived height" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(300) } });
    const a = t.push(root, .none, &.{ .size = .{ .px(100), .fit }, .max = .{ types.inf, 30 } });
    const b = t.push(root, .none, &.{ .size = .{ .px(100), .fit }, .min = .{ 0, 80 } });
    s.fx.set(a, &.{ .aspect = 1 });
    s.fx.set(b, &.{ .aspect = 2 });
    s.runFlex(200, 300);
    try testing.expectEqual([2]f32{ 100, 30 }, s.size(a));
    try testing.expectEqual([2]f32{ 100, 80 }, s.size(b));
}

test "aspect: rows without a ratio give runFlex the same rects as run" {
    var plain: Scene = .{};
    var flexed: Scene = .{};
    inline for (.{ &plain, &flexed }) |s| {
        const t = s.init();
        const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(300), .px(200) }, .pad = @splat(4), .gap = 3 });
        _ = t.push(root, .none, &.{ .size = .{ .fill, .pct(0.5) } });
        const mid = t.push(root, .none, &.{ .size = .{ .grow(2), .fit }, .pad = @splat(2) });
        _ = t.push(mid, .none, &.{ .size = .{ .px(30), .px(70) }, .shrink = true });
        t.seal(mid);
        _ = t.push(root, .none, &.{ .float = true, .offset = .{ 5, 6 }, .size = .{ .px(10), .px(10) } });
    }
    plain.run(300, 200);
    flexed.runFlex(300, 200);
    inline for (0..4) |k| try testing.expectEqualSlices(f32, plain.t.c.rect[k][0..plain.t.len], flexed.t.c.rect[k][0..flexed.t.len]);
}

test "shrink: the overflow is shared by weight times natural size" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(100), .px(50) } });
    // Contents of 60, 60 and 40 in 100: 60 px over.
    var k: [3]u32 = undefined;
    for (&k, [3]f32{ 60, 60, 40 }) |*row, w| {
        row.* = t.push(root, .none, &.{ .shrink = true });
        _ = t.push(row.*, .none, &.{ .size = .{ .px(w), .px(1) } });
        t.seal(row.*);
    }
    // Weights 1, 2, 1.5 scale to 60, 120, 60: parts of 15, 30 and 15.
    s.fx.set(k[1], &.{ .shrink = 2 });
    s.fx.set(k[2], &.{ .shrink = 1.5 });
    s.runFlex(100, 50);
    try testing.expectEqual(45, s.size(k[0])[0]);
    try testing.expectEqual(30, s.size(k[1])[0]);
    try testing.expectEqual(25, s.size(k[2])[0]);
    try testing.expectEqual(100, t.c.used[0][root]);
}

test "shrink: weight 0 and nodes without Style.shrink keep their size; gaps count as overflow" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(100), .px(50) }, .gap = 10 });
    const a = t.push(root, .none, &.{ .size = .{ .px(30), .fill } });
    const b = t.push(root, .none, &.{ .shrink = true });
    _ = t.push(b, .none, &.{ .size = .{ .px(50), .px(1) } });
    t.seal(b);
    const c = t.push(root, .none, &.{ .shrink = true });
    _ = t.push(c, .none, &.{ .size = .{ .px(50), .px(1) } });
    t.seal(c);
    s.fx.set(c, &.{ .shrink = 0 });
    s.runFlex(100, 50);
    // 30 + 50 + 50 + 2 * 10 = 150 in 100: b, the only weighted shrinker, gives up all 50.
    try testing.expectEqual(30, s.size(a)[0]);
    try testing.expectEqual(0, s.size(b)[0]);
    try testing.expectEqual(50, s.size(c)[0]);
}

test "shrink: a single shrinker gives the prototype's result; across the main axis it is unchanged" {
    var plain: Scene = .{};
    var flexed: Scene = .{};
    inline for (.{ &plain, &flexed }) |s| {
        const t = s.init();
        const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(100), .px(50) }, .gap = 4 });
        _ = t.push(root, .none, &.{ .size = .{ .px(40), .fill } });
        const w = t.push(root, .none, &.{ .shrink = true });
        _ = t.push(w, .none, &.{ .size = .{ .px(90), .px(80) } });
        t.seal(w);
        // Across: a y-stack whose shrinkable child is wider than it.
        const col = t.push(root, .none, &.{ .float = true, .size = .{ .px(30), .fit } });
        const n = t.push(col, .none, &.{ .shrink = true });
        _ = t.push(n, .none, &.{ .size = .{ .px(70), .px(5) } });
        t.seal(n);
        t.seal(col);
    }
    plain.run(100, 50);
    flexed.runFlex(100, 50);
    inline for (0..4) |k| try testing.expectEqualSlices(f32, plain.t.c.rect[k][0..plain.t.len], flexed.t.c.rect[k][0..flexed.t.len]);
    try testing.expectEqual(56, flexed.size(2)[0]); // 100 - 40 - 4
    try testing.expectEqual(30, flexed.size(5)[0]); // narrowed to col across its main axis
}

test "shrink: a node stopped by its min leaves the rest of its part overflowing (one round)" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(100), .px(50) } });
    const a = t.push(root, .none, &.{ .shrink = true });
    _ = t.push(a, .none, &.{ .size = .{ .px(100), .px(1) } });
    t.seal(a);
    const b = t.push(root, .none, &.{ .shrink = true, .min = .{ 90, 0 } });
    _ = t.push(b, .none, &.{ .size = .{ .px(100), .px(1) } });
    t.seal(b);
    s.runFlex(100, 50);
    // 100 over, 50 each: a is 50, b stops at its min 90; 40 px overflow remain.
    try testing.expectEqual(50, s.size(a)[0]);
    try testing.expectEqual(90, s.size(b)[0]);
}

test "regrow: what a capped grower leaves goes to the other growers by weight" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(300), .px(50) } });
    const a = t.push(root, .none, &.{ .size = .{ .fill, .fill }, .max = .{ 40, types.inf } });
    const b = t.push(root, .none, &.{ .size = .{ .fill, .fill } });
    const c = t.push(root, .none, &.{ .size = .{ .grow(2), .fill } });
    s.fx.set(root, &.{ .regrow = true });
    s.runFlex(300, 50);
    // Round one: 75, 75, 150; a stops at 40 and leaves 35, shared 1:2 by b and c.
    try testing.expectEqual(40, s.size(a)[0]);
    try testing.expectApproxEqAbs(75 + 35.0 / 3.0, s.size(b)[0], 1e-3);
    try testing.expectApproxEqAbs(150 + 70.0 / 3.0, s.size(c)[0], 1e-3);
    try testing.expectApproxEqAbs(300, t.c.used[0][root], 1e-3);
}

test "regrow: bounded to two rounds; a grower capped in the second leaves its rest unused" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(300), .px(50) } });
    const a = t.push(root, .none, &.{ .size = .{ .fill, .fill }, .max = .{ 20, types.inf } });
    const b = t.push(root, .none, &.{ .size = .{ .fill, .fill }, .max = .{ 120, types.inf } });
    const c = t.push(root, .none, &.{ .size = .{ .fill, .fill } });
    s.fx.set(root, &.{ .regrow = true });
    s.runFlex(300, 50);
    // Round one: 100 each; a stops at 20 (80 left). Round two: b and c get 40 each; b stops at
    // 120, and the 20 it cannot take is not handed out again.
    try testing.expectEqual(20, s.size(a)[0]);
    try testing.expectEqual(120, s.size(b)[0]);
    try testing.expectEqual(140, s.size(c)[0]);
}

test "regrow: only for the container that opts in, only along its main axis" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(300), .px(100) } });
    // Not opted in: the prototype's one round.
    const row = t.push(root, .none, &.{ .dir = .x, .size = .{ .fill, .px(50) } });
    const a = t.push(row, .none, &.{ .size = .{ .fill, .fill }, .max = .{ 40, 10 } });
    const b = t.push(row, .none, &.{ .size = .{ .fill, .fill } });
    t.seal(row);
    // Opted in, but across its main axis the growers stretch and nothing is shared.
    const col = t.push(root, .none, &.{ .dir = .x, .size = .{ .fill, .px(50) } });
    const p = t.push(col, .none, &.{ .size = .{ .px(10), .fill }, .max = .{ types.inf, 20 } });
    const q = t.push(col, .none, &.{ .size = .{ .px(10), .fill } });
    t.seal(col);
    s.fx.set(col, &.{ .regrow = true });
    s.runFlex(300, 100);
    try testing.expectEqual([2]f32{ 40, 10 }, s.size(a));
    try testing.expectEqual([2]f32{ 150, 50 }, s.size(b));
    try testing.expectEqual([2]f32{ 10, 20 }, s.size(p));
    try testing.expectEqual([2]f32{ 10, 50 }, s.size(q));
}

test "regrow: percent and floating children take no part in either round" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(300), .px(50) } });
    const a = t.push(root, .none, &.{ .size = .{ .fill, .fill }, .max = .{ 50, types.inf } });
    const b = t.push(root, .none, &.{ .size = .{ .pct(0.2), .fill } });
    const f = t.push(root, .none, &.{ .float = true, .size = .{ .fill, .fill } });
    const c = t.push(root, .none, &.{ .size = .{ .fill, .fill } });
    s.fx.set(root, &.{ .regrow = true });
    s.runFlex(300, 50);
    // grow_sum 2 (a, c): 150 each; a stops at 50, c takes 250; b is 60 regardless (a percentage
    // is not counted in the free space, as in the one-round pass), f keeps its natural 0.
    try testing.expectEqual(50, s.size(a)[0]);
    try testing.expectEqual(60, s.size(b)[0]);
    try testing.expectEqual(0, s.size(f)[0]);
    try testing.expectEqual(250, s.size(c)[0]);
}

test "cross: a child's own alignment replaces the parent's across the main axis" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(300), .px(100) }, .cross = .center });
    const a = t.push(root, .none, &.{ .size = .{ .px(10), .px(20) } });
    const b = t.push(root, .none, &.{ .size = .{ .px(10), .px(20) } });
    const c = t.push(root, .none, &.{ .size = .{ .px(10), .px(20) } });
    const d = t.push(root, .none, &.{ .size = .{ .px(10), .px(20) } });
    s.fx.set(b, &.{ .cross = .start });
    s.fx.set(c, &.{ .cross = .end });
    s.fx.set(d, &.{ .cross = .center });
    s.runFlex(300, 100);
    try testing.expectEqualSlices(f32, &.{ 40, 0, 80, 40 }, &.{ t.c.pos[1][a], t.c.pos[1][b], t.c.pos[1][c], t.c.pos[1][d] });
    // Along the main axis nothing moves.
    try testing.expectEqualSlices(f32, &.{ 0, 10, 20, 30 }, &.{ t.c.pos[0][a], t.c.pos[0][b], t.c.pos[0][c], t.c.pos[0][d] });
}

test "cross: the override works in a column too, inside the padding" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(100), .px(100) }, .pad = .{ 5, 0, 15, 0 } });
    const a = t.push(root, .none, &.{ .size = .{ .px(20), .px(10) } });
    const b = t.push(root, .none, &.{ .size = .{ .px(20), .px(10) } });
    s.fx.set(b, &.{ .cross = .end });
    s.runFlex(100, 100);
    try testing.expectEqual(5, t.c.pos[0][a]);
    try testing.expectEqual(5 + 80 - 20, t.c.pos[0][b]);
}

test "cross: a floating node ignores it, as it ignores the parent's" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(100), .px(100) } });
    const f = t.push(root, .none, &.{ .float = true, .size = .{ .px(20), .px(10) } });
    s.fx.set(f, &.{ .cross = .end });
    s.runFlex(100, 100);
    try testing.expectEqual(0, t.c.pos[1][f]);
}

test "margin: adds to the parent's natural size and to the cursor step; the node sits inside it" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(300), .px(300) } });
    const row = t.push(root, .none, &.{ .dir = .x, .gap = 2 });
    const a = t.push(row, .none, &.{ .size = .{ .px(10), .px(10) } });
    const b = t.push(row, .none, &.{ .size = .{ .px(10), .px(10) } });
    t.seal(row);
    s.fx.set(a, &.{ .margin = .{ 1, 2, 3, 4 } });
    s.runFlex(300, 300);
    // x: 1 + 10 + 3 + gap 2 + 10; y: the taller of 2 + 10 + 4 and 10.
    try testing.expectEqual([2]f32{ 26, 16 }, s.size(row));
    try testing.expectEqual([2]f32{ 1, 2 }, [2]f32{ t.c.pos[0][a], t.c.pos[1][a] });
    try testing.expectEqual(1 + 10 + 3 + 2, t.c.pos[0][b]);
    // used holds sizes and margins; gaps are counted apart (gap_total).
    try testing.expectEqual(24, t.c.used[0][row]);
}

test "margin: a stretched or grown node fills the room less its margins" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(100), .px(50) } });
    const a = t.push(root, .none, &.{ .size = .{ .fill, .fill } });
    const b = t.push(root, .none, &.{ .size = .{ .px(20), .fill } });
    s.fx.set(a, &.{ .margin = .{ 5, 5, 5, 5 } });
    s.fx.set(b, &.{ .margin = .{ 0, 10, 0, 0 } });
    s.runFlex(100, 50);
    try testing.expectEqual([2]f32{ 70, 40 }, s.size(a));
    try testing.expectEqual([2]f32{ 20, 40 }, s.size(b));
    try testing.expectEqual([2]f32{ 5, 5 }, [2]f32{ t.c.pos[0][a], t.c.pos[1][a] });
    try testing.expectEqual([2]f32{ 80, 10 }, [2]f32{ t.c.pos[0][b], t.c.pos[1][b] });
}

test "margin: alignment places the margin box; shrink makes room for it" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(100), .px(50) }, .main = .end, .cross = .end });
    const a = t.push(root, .none, &.{ .size = .{ .px(20), .px(20) } });
    s.fx.set(a, &.{ .margin = .{ 0, 0, 10, 5 } });
    const w = t.push(root, .none, &.{ .shrink = true });
    _ = t.push(w, .none, &.{ .size = .{ .px(90), .px(1) } });
    t.seal(w);
    s.runFlex(100, 50);
    // 20 + 10 + 90 = 120 in 100: w gives up 20. Everything fits, so main = end moves nothing.
    try testing.expectEqual(70, s.size(w)[0]);
    try testing.expectEqual(0, t.c.pos[0][a]);
    try testing.expectEqual(30, t.c.pos[0][w]);
    // Across: 50 - 20 - 5 = 25 before a.
    try testing.expectEqual(25, t.c.pos[1][a]);
}

test "margin: a floating node ignores it" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(100), .px(50) } });
    const f = t.push(root, .none, &.{ .float = true, .size = .{ .px(10), .px(10) } });
    s.fx.set(f, &.{ .margin = @splat(7) });
    s.runFlex(100, 50);
    try testing.expectEqual([2]f32{ 0, 0 }, [2]f32{ t.c.pos[0][f], t.c.pos[1][f] });
    try testing.expectEqual(0, t.c.fit[0][root]);
}

test "space: between, around and evenly share a row's free space; one child of between sits at the start" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(300), .px(300) } });
    var rows: [3]u32 = undefined;
    var kids: [3][3]u32 = undefined;
    for (&rows, &kids) |*r, *k| {
        r.* = t.push(root, .none, &.{ .dir = .x, .size = .{ .px(100), .px(10) }, .gap = 5, .main = .end });
        for (k) |*c| c.* = t.push(r.*, .none, &.{ .size = .{ .px(10), .px(10) } });
        t.seal(r.*);
    }
    const lone = t.push(root, .none, &.{ .dir = .x, .size = .{ .px(100), .px(10) } });
    const one = t.push(lone, .none, &.{ .size = .{ .px(10), .px(10) } });
    t.seal(lone);
    for (rows, [_]Flex.Space{ .between, .around, .evenly }) |r, sp| s.fx.set(r, &.{ .space = sp });
    s.fx.set(lone, &.{ .space = .between });
    s.runFlex(300, 300);
    // 100 - 3 * 10 - 2 * 5 = 60 free.
    const want = [3][3]f32{ .{ 0, 45, 90 }, .{ 10, 45, 80 }, .{ 15, 45, 75 } };
    for (kids, want) |k, xs| for (k, xs) |c, x| try testing.expectEqual(x, t.c.pos[0][c]);
    try testing.expectEqual(0, t.c.pos[0][one]);
}

test "space: a column shares along y; a grower leaves no free space" {
    var s: Scene = .{};
    const t = s.init();
    const col = t.push(0, .none, &.{ .size = .{ .px(50), .px(100) } });
    const a = t.push(col, .none, &.{ .size = .{ .px(10), .px(10) } });
    const b = t.push(col, .none, &.{ .size = .{ .px(10), .px(10) } });
    const row = t.push(col, .none, &.{ .dir = .x, .size = .{ .px(50), .px(10) } });
    const c = t.push(row, .none, &.{ .size = .{ .fill, .px(10) } });
    const d = t.push(row, .none, &.{ .size = .{ .px(10), .px(10) } });
    t.seal(row);
    s.fx.set(col, &.{ .space = .between });
    s.fx.set(row, &.{ .space = .between });
    s.runFlex(50, 100);
    try testing.expectEqual(0, t.c.pos[1][a]);
    try testing.expectEqual(45, t.c.pos[1][b]);
    try testing.expectEqual(90, t.c.pos[1][row]);
    try testing.expectEqual(40, s.size(c)[0]);
    try testing.expectEqual(40, t.c.pos[0][d]);
}
