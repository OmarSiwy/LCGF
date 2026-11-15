//! overlay: nodes that sit on top of other nodes instead of beside them. Tier 0: no allocator,
//! no I/O. Built on what the core passes already do with `Style.float` and `Style.offset`
//! (prototype/ui.zig): a floating node is placed at its parent's content origin plus `offset`
//! and takes no part in the parent's flow.
//!
//!   zstack     a container whose children all overlap, sized to the largest of them
//!   anchor     after `place`: moves anchored nodes (and their subtrees) to a point of a box
//!              and flips them to the other side when they would leave the viewport
//!   order      paint order by layer: popovers and tooltips above the rows after them
//!   lastRect   where a node was in the previous frame's tree, to anchor a popover to it

const std = @import("std");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Rect = types.Rect;
const b01 = simd.b2f;

/// Turns node `i` into a z-stack: its children overlap at its content origin, later rows on top,
/// and it is as large as its largest child on both axes. Call after `push`, before the passes.
///
/// No pass changes: the stacking direction is the coefficient pair `main`, and with both
/// coefficients 0 every axis is a cross axis. `fit` then takes the max of the children on both
/// axes, `resolve` stretches growing children to the inner size on both, and `place` puts each
/// child at `(inner - size) * align_cross` on both, so `Style.cross` aligns the children.
pub fn zstack(t: *Tree, i: u32) void {
    t.c.main[0][i] = 0;
    t.c.main[1][i] = 0;
}

/// A point of a box: an edge midpoint, a corner or the centre. Stored as two fractions of the
/// box's size (`fx`, `fy`), so placing by it is a multiply, not a switch.
pub const Anchor = enum(u8) {
    top_left,
    top,
    top_right,
    left,
    center,
    right,
    bottom_left,
    bottom,
    bottom_right,

    pub const fx = [9]f32{ 0, 0.5, 1, 0, 0.5, 1, 0, 0.5, 1 };
    pub const fy = [9]f32{ 0, 0, 0, 0.5, 0.5, 0.5, 1, 1, 1 };
};

/// The anchor side list: one row per anchored node, so the pass loops over anchors that exist
/// instead of testing every node.
pub const Anchors = struct {
    len: u32 = 0,
    cap: u32,
    /// `push` ran out of rows. The last row is overwritten; nothing is written out of bounds.
    overflow: bool = false,
    c: Columns,

    pub const Columns = struct {
        node: []u32,
        /// Point of the box the node is attached to, as fractions of the box's size.
        at: [2][]f32,
        /// Point of the node that is put there, as fractions of the node's size.
        pivot: [2][]f32,
        /// Added after anchoring, in pixels.
        offset: [2][]f32,
        /// 1.0: the box is the parent's content box. 0.0: the box is `box`.
        rel: []f32,
        /// x0, y0, x1, y1 of an absolute box, for rows with `rel` 0.
        box: [4][]f32,
        /// 1.0: on this axis, move to the opposite side when the node would leave the viewport.
        flip: [2][]f32,
    };

    /// Carves every column from `carver`, `simd.rows(cap)` rows each. With a counting carver
    /// this sizes the buffer instead.
    pub fn init(carver: *mem.Carver, cap: u32) Anchors {
        std.debug.assert(cap > 0);
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }
    pub fn reset(an: *Anchors) void {
        an.len = 0;
        an.overflow = false;
    }
    /// Puts point `pivot` of `node` on point `at` of its parent's content box, then moves it by
    /// `offset`. `.top_right, .top_right` keeps the node inside that corner; `.top_right,
    /// .center` centres it on the corner (a badge); `.bottom, .top` hangs it below the parent
    /// (a dropdown). Push anchors in row order: a nested anchor then sees its parent's final
    /// place. Returns the anchor's row.
    pub fn push(an: *Anchors, node: u32, at: Anchor, pivot: Anchor, offset: [2]f32) u32 {
        const k = an.row(node, at, pivot, offset);
        an.c.rel[k] = 1;
        inline for (0..4) |e| an.c.box[e][k] = 0;
        return k;
    }
    /// Like `push`, but the box is the absolute rect `box`: typically another node's rect from
    /// the previous frame (`lastRect`), for a tooltip or popover that belongs to one part of the
    /// tree and is drawn next to another. The node is usually floating under the root or a
    /// z-stack.
    pub fn pushRect(an: *Anchors, node: u32, box: Rect, at: Anchor, pivot: Anchor, offset: [2]f32) u32 {
        const k = an.row(node, at, pivot, offset);
        an.c.rel[k] = 0;
        inline for (0..4) |e| an.c.box[e][k] = box.array()[e];
        return k;
    }
    /// Lets anchor row `k` flip on the axes set in `axes`: when the node would cross an edge of
    /// the viewport and the mirrored placement would not, `at`, `pivot` and `offset` are taken
    /// from the other side (a menu hung below a button opens above it near the bottom of the
    /// window). Off by default.
    pub fn flip(an: *Anchors, k: u32, axes: [2]bool) void {
        inline for (0..2) |a| an.c.flip[a][k] = simd.b2f(axes[a]);
    }
    fn row(an: *Anchors, node: u32, at: Anchor, pivot: Anchor, offset: [2]f32) u32 {
        const k = @min(an.len, an.cap - 1);
        an.overflow = simd.orB(an.overflow, an.len >= an.cap);
        an.len = k + 1;
        const c = &an.c;
        c.node[k] = node;
        c.at[0][k] = Anchor.fx[@backingInt(at)];
        c.at[1][k] = Anchor.fy[@backingInt(at)];
        c.pivot[0][k] = Anchor.fx[@backingInt(pivot)];
        c.pivot[1][k] = Anchor.fy[@backingInt(pivot)];
        c.offset[0][k] = offset[0];
        c.offset[1][k] = offset[1];
        c.flip[0][k] = 0;
        c.flip[1][k] = 0;
        return k;
    }
};

/// Moves every anchored node, with its subtree, so that its pivot sits on its anchor point.
/// Run after `layout.place` and before `layout.finalize`: sizes and positions are final, and
/// the snap and clip of `finalize` then apply to the moved rects.
///
/// The box is the parent's content box as it appears (padding off, scroll not applied), so a
/// node anchored to a corner of a scroll container stays in that corner while the content
/// scrolls. Anchoring is meant for floating nodes; an in-flow node is moved too, but its slot in
/// the parent's flow stays where it was.
///
/// Rows pushed with `pushRect` use their absolute box instead of the parent's; the two cases are
/// one formula blended by the `rel` coefficient.
///
/// `viewport` is the area flipping rows must stay inside, usually the window: (0, 0, w, h). The
/// flip is one test per axis, not a search: if neither side fits, the first side is kept.
pub fn anchor(t: *Tree, an: *const Anchors, viewport: Rect) void {
    const vp = viewport.array();
    const pos = t.c.pos;
    const size = t.c.size;
    const lo = t.c.pad_lo;
    const hi = t.c.pad_hi;
    const parent = t.c.parent;
    const end = t.c.end;
    const c = &an.c;
    for (0..an.len) |k| {
        const n = c.node[k];
        const p = parent[n];
        const rel = c.rel[k];
        inline for (0..2) |a| {
            const inner = size[a][p] - lo[a][p] - hi[a][p];
            const b0 = c.box[a][k];
            const origin = b0 + rel * (pos[a][p] + lo[a][p] - b0);
            const span = c.box[a + 2][k] - b0;
            const extent = span + rel * (inner - span);
            const sz = size[a][n];
            const at = c.at[a][k];
            const pivot = c.pivot[a][k];
            const off = c.offset[a][k];
            const first = origin + at * extent - pivot * sz + off;
            const other = origin + (1 - at) * extent - (1 - pivot) * sz - off;
            const leaves_first = @max(b01(first < vp[a]), b01(first + sz > vp[a + 2]));
            const leaves_other = @max(b01(other < vp[a]), b01(other + sz > vp[a + 2]));
            const use_other = c.flip[a][k] * leaves_first * (1 - leaves_other);
            const want = first + use_other * (other - first);
            const delta = want - pos[a][n];
            for (pos[a][n..end[n]]) |*v| v.* += delta;
        }
    }
}

/// The layer column: which layer each node is painted in, and the paint order that follows.
/// Within a layer, later rows are on top, as in prototype/ui.zig (`hit.at`: "later rows are
/// drawn later, so the highest matching row wins"); a higher layer is on top of every row of
/// a lower one. A node is in its own layer or its parent's, whichever is higher, so a popover's
/// contents stay with it.
pub const Layers = struct {
    c: Columns,

    pub const Columns = struct {
        /// Set by the caller: the node's own layer, 0 unless raised.
        own: []u8,
        /// Written by `order`: max(own, the parent's layer).
        layer: []u8,
        /// Written by `order`: rows in paint order, back to front. `order[k]` is painted k-th.
        order: []u32,
    };

    /// One row per node of a tree of capacity `cap`.
    pub fn init(carver: *mem.Carver, cap: u32) Layers {
        std.debug.assert(cap > 0);
        return .{ .c = carver.columns(Columns, simd.rows(cap)) };
    }
    /// Puts every node back in layer 0, for the next frame.
    pub fn reset(ly: *Layers) void {
        @memset(ly.c.own, 0);
    }
};

/// Fills `layer` (one forward sweep) and `order`, a stable counting sort of the rows by layer:
/// a histogram, a prefix sum over the 256 layers, and a scatter. O(n + 256), no comparison
/// and no data-dependent branch. Run any time after the tree is built; it reads only `parent`.
/// Hit testing that honours layers takes the highest (layer, row), which is the last match in
/// `order`.
pub fn order(t: *const Tree, ly: *Layers) void {
    if (t.len == 0) return;
    const parent = t.c.parent;
    const own = ly.c.own;
    const layer = ly.c.layer;
    layer[0] = own[0];
    for (1..t.len) |i| layer[i] = @max(own[i], layer[parent[i]]);

    var start: [256]u32 = @splat(0);
    for (layer[0..t.len]) |l| start[l] += 1;
    var sum: u32 = 0;
    for (&start) |*s| {
        const count = s.*;
        s.* = sum;
        sum += count;
    }
    for (layer[0..t.len], 0..) |l, i| {
        ly.c.order[start[l]] = @intCast(i);
        start[l] += 1;
    }
}

/// Where the node with `id` was laid out in `prev`, the previous frame's tree, or a zero rect
/// if it was not there. A SIMD scan of the id column, O(n). Ported from prototype/ui.zig
/// (`Frame.lastRect`); the caller keeps the previous tree, as the runtime front end does.
pub fn lastRect(prev: *const Tree, id: types.Id) Rect {
    const i = prev.find(id);
    const r = @min(i, prev.cap - 1);
    const m = simd.b2f(i != types.none);
    const c = &prev.c;
    return .{ .x0 = c.rect[0][r] * m, .y0 = c.rect[1][r] * m, .x1 = c.rect[2][r] * m, .y1 = c.rect[3][r] * m };
}

const testing = std.testing;
const layout = @import("layout.zig");
const Texts = @import("../core/texts.zig").Texts;
const Id = types.Id;

/// A tree and an empty text list in a caller-owned buffer, for the tests.
const Scene = struct {
    raw: [128 * 1024]u8 align(mem.column_align) = undefined,
    t: Tree = undefined,
    tx: Texts = undefined,

    fn init(s: *Scene) void {
        var carver: mem.Carver = .{ .buf = &s.raw };
        s.t = Tree.init(&carver, 32);
        s.tx = Texts.init(&carver, 1);
    }
    fn run(s: *Scene, viewport: [2]f32) void {
        layout.run(&s.t, &s.tx, viewport);
    }
};

fn rect(x0: f32, y0: f32, x1: f32, y1: f32) Rect {
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

test "zstack: children overlap at the content origin, aligned across both axes" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    // root { stack(pad 5, centred) { a 100x40, b 60x80, c fill }, after 20x20 }
    const root = t.push(0, Id.from("root"), &.{ .size = .{ .px(400), .px(300) } });
    const stack = t.push(root, .none, &.{ .pad = @splat(5), .cross = .center, .gap = 7 });
    zstack(t, stack);
    const a = t.push(stack, .none, &.{ .size = .{ .px(100), .px(40) } });
    const b = t.push(stack, .none, &.{ .size = .{ .px(60), .px(80) } });
    const c = t.push(stack, .none, &.{ .size = .{ .fill, .fill } });
    t.seal(stack);
    const after = t.push(root, .none, &.{ .size = .{ .px(20), .px(20) } });
    t.seal(root);
    s.run(.{ 400, 300 });

    // The largest child on each axis plus padding; the gap does not apply to a stack.
    try testing.expectEqual(rect(0, 0, 110, 90), t.rect(stack));
    // Inner box is 100 x 80 at (5, 5); each child is centred in it.
    try testing.expectEqual(rect(5, 25, 105, 65), t.rect(a));
    try testing.expectEqual(rect(25, 5, 85, 85), t.rect(b));
    // A growing child stretches to the inner box on both axes.
    try testing.expectEqual(rect(5, 5, 105, 85), t.rect(c));
    // The stack itself is in its parent's flow.
    try testing.expectEqual(rect(0, 90, 20, 110), t.rect(after));
}

test "zstack: a fixed-size stack aligns its children to the end; later rows are on top" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(100) }, .dir = .x });
    const stack = t.push(root, .none, &.{ .size = .{ .px(50), .px(50) }, .cross = .end });
    zstack(t, stack);
    const under = t.push(stack, .none, &.{ .size = .{ .px(30), .px(30) } });
    const over = t.push(stack, .none, &.{ .size = .{ .px(10), .px(20) } });
    t.seal(stack);
    t.seal(root);
    s.run(.{ 200, 100 });
    try testing.expectEqual(rect(20, 20, 50, 50), t.rect(under));
    try testing.expectEqual(rect(40, 30, 50, 50), t.rect(over));
    // Paint and hit testing take later rows as on top, and the overlapping child is the later row.
    try testing.expect(over > under);
}

test "anchor: corners and edges of the parent's content box, with the subtree carried along" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    var raw: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var an = Anchors.init(&carver, 4);

    // root { button 100x30 at (50, 40) { badge 10x10, menu 80x60 { item 80x20 } } }
    const root = t.push(0, .none, &.{ .size = .{ .px(400), .px(300) }, .pad = .{ 50, 40, 0, 0 } });
    const button = t.push(root, .none, &.{ .size = .{ .px(100), .px(30) }, .pad = @splat(2) });
    const badge = t.push(button, .none, &.{ .size = .{ .px(10), .px(10) }, .float = true });
    const menu = t.push(button, .none, &.{ .size = .{ .px(80), .px(60) }, .float = true });
    const item = t.push(menu, .none, &.{ .size = .{ .px(80), .px(20) } });
    t.seal(menu);
    t.seal(button);
    const corner = t.push(root, .none, &.{ .size = .{ .px(20), .px(20) }, .float = true });
    t.seal(root);
    _ = an.push(badge, .top_right, .center, .{ 0, 0 });
    _ = an.push(menu, .bottom_left, .top_left, .{ 0, 4 });
    _ = an.push(corner, .bottom_right, .bottom_right, .{ -5, -5 });

    layout.prepare(t);
    layout.applyText(t, &s.tx, .x);
    layout.fit(t, .x);
    layout.resolve(t, .x, 400);
    layout.applyText(t, &s.tx, .y);
    layout.fit(t, .y);
    layout.resolve(t, .y, 300);
    layout.place(t);
    anchor(t, &an, rect(0, 0, 400, 300));
    layout.finalize(t);

    try testing.expectEqual(rect(50, 40, 150, 70), t.rect(button));
    // Centred on the top-right corner of the button's content box (148, 42).
    try testing.expectEqual(rect(143, 37, 153, 47), t.rect(badge));
    // Hung 4 px below the content box's bottom-left corner (52, 68); its child moves with it.
    try testing.expectEqual(rect(52, 72, 132, 132), t.rect(menu));
    try testing.expectEqual(rect(52, 72, 132, 92), t.rect(item));
    // Inside root's bottom-right corner, 5 px in. Root's content box is (50, 40)-(400, 300).
    try testing.expectEqual(rect(375, 275, 395, 295), t.rect(corner));
}

test "anchor: no anchors leaves the layout untouched; overflow is reported" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    var raw: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var an = Anchors.init(&carver, 1);
    const root = t.push(0, .none, &.{ .size = .{ .px(40), .px(40) } });
    const a = t.push(root, .none, &.{ .size = .{ .px(10), .px(10) }, .offset = .{ 3, 4 }, .float = true });
    t.seal(root);
    s.run(.{ 40, 40 });
    const before = t.rect(a);
    anchor(t, &an, rect(0, 0, 40, 40));
    layout.finalize(t);
    try testing.expectEqual(before, t.rect(a));
    _ = an.push(a, .center, .center, .{ 0, 0 });
    try testing.expect(!an.overflow);
    try testing.expectEqual(0, an.push(a, .top, .top, .{ 0, 0 }));
    try testing.expect(an.overflow);
    try testing.expectEqual(1, an.len);
    an.reset();
    try testing.expectEqual(0, an.len);
}

test "anchor: a popover is placed against another node's rect from the previous frame" {
    // Frame 1: a toolbar with a "save" button; nothing is anchored yet.
    var prev: Scene = .{};
    prev.init();
    {
        const t = &prev.t;
        const root = t.push(0, .none, &.{ .size = .{ .px(400), .px(300) }, .pad = @splat(10) });
        const bar = t.push(root, .none, &.{ .dir = .x, .gap = 5 });
        t.seal(t.push(bar, Id.from("open"), &.{ .size = .{ .px(60), .px(20) } }));
        t.seal(t.push(bar, Id.from("save"), &.{ .size = .{ .px(60), .px(20) } }));
        t.seal(bar);
        t.seal(root);
        prev.run(.{ 400, 300 });
    }
    const save = lastRect(&prev.t, Id.from("save"));
    try testing.expectEqual(rect(75, 10, 135, 30), save);
    // A node that was not there gives a zero rect.
    try testing.expectEqual(Rect{}, lastRect(&prev.t, Id.from("absent")));

    // Frame 2: a tooltip floating under the root, hung 2 px below the button's last rect and
    // centred on it, with a child that follows.
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    var raw: [8192]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var an = Anchors.init(&carver, 2);
    const root = t.push(0, .none, &.{ .size = .{ .px(400), .px(300) }, .pad = @splat(10) });
    const tip = t.push(root, .none, &.{ .size = .{ .px(100), .px(24) }, .pad = @splat(2), .float = true });
    const label = t.push(tip, .none, &.{ .size = .{ .px(50), .px(10) } });
    t.seal(tip);
    t.seal(root);
    _ = an.pushRect(tip, save, .bottom, .top, .{ 0, 2 });
    s.run(.{ 400, 300 });
    anchor(t, &an, rect(0, 0, 400, 300));
    layout.finalize(t);
    // Centre x of the button is 105, so the 100 px tip spans 55..155, from y = 30 + 2.
    try testing.expectEqual(rect(55, 32, 155, 56), t.rect(tip));
    try testing.expectEqual(rect(57, 34, 107, 44), t.rect(label));
}

test "anchor: flip to the other side only when the first side leaves the viewport" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    var raw: [8192]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var an = Anchors.init(&carver, 4);
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(100) } });
    const menu = t.push(root, .none, &.{ .size = .{ .px(50), .px(40) }, .float = true });
    const item = t.push(menu, .none, &.{ .size = .{ .px(50), .px(10) } });
    t.seal(menu);
    const fits = t.push(root, .none, &.{ .size = .{ .px(50), .px(20) }, .float = true });
    const stuck = t.push(root, .none, &.{ .size = .{ .px(50), .px(90) }, .float = true });
    const off = t.push(root, .none, &.{ .size = .{ .px(50), .px(40) }, .float = true });
    t.seal(root);
    const near_bottom = rect(150, 70, 190, 90);
    // A menu hung 2 px below a button near the bottom-right corner: it would end at y = 132,
    // so it opens 2 px above the button; across, it ends at x = 200, inside, so x stays.
    an.flip(an.pushRect(menu, near_bottom, .bottom_left, .top_left, .{ 0, 2 }), .{ true, true });
    // Room below: no flip.
    an.flip(an.pushRect(fits, rect(10, 10, 60, 30), .bottom_left, .top_left, .{ 0, 2 }), .{ true, true });
    // 90 px high in a 100 px viewport: neither side fits, so the first is kept.
    an.flip(an.pushRect(stuck, near_bottom, .bottom_left, .top_left, .{ 0, 2 }), .{ true, true });
    // Flipping is off unless asked for.
    _ = an.pushRect(off, near_bottom, .bottom_left, .top_left, .{ 0, 2 });
    s.run(.{ 200, 100 });
    anchor(t, &an, rect(0, 0, 200, 100));
    layout.finalize(t);
    try testing.expectEqual(rect(150, 28, 200, 68), t.rect(menu));
    try testing.expectEqual(rect(150, 28, 200, 38), t.rect(item));
    try testing.expectEqual(rect(10, 32, 60, 52), t.rect(fits));
    try testing.expectEqual(rect(150, 92, 200, 182), t.rect(stuck));
    try testing.expectEqual(rect(150, 92, 200, 132), t.rect(off));

    // Across: a submenu opened to the right of an item at the right edge opens to its left.
    an.reset();
    an.flip(an.pushRect(menu, rect(170, 10, 190, 20), .top_right, .top_left, .{ 4, 0 }), .{ true, false });
    s.run(.{ 200, 100 });
    anchor(t, &an, rect(0, 0, 200, 100));
    layout.finalize(t);
    try testing.expectEqual(rect(116, 10, 166, 50), t.rect(menu));
}

test "order: raised nodes and their subtrees paint after layer 0, rows in order within a layer" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    var raw: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var ly = Layers.init(&carver, 32);
    // root { a { menu { item } } b { tip } c }
    const root = t.push(0, .none, &.{});
    const a = t.push(root, .none, &.{});
    const menu = t.push(a, .none, &.{ .float = true });
    const item = t.push(menu, .none, &.{});
    t.seal(menu);
    t.seal(a);
    const b = t.push(root, .none, &.{});
    const tip = t.push(b, .none, &.{ .float = true });
    t.seal(b);
    const c = t.push(root, .none, &.{});
    t.seal(root);
    ly.reset();
    ly.c.own[menu] = 1;
    ly.c.own[tip] = 2;
    order(t, &ly);
    // item inherits the menu's layer.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1, 1, 0, 2, 0 }, ly.c.layer[0..t.len]);
    try testing.expectEqualSlices(u32, &.{ root, a, b, c, menu, item, tip }, ly.c.order[0..t.len]);

    // A child can raise itself above its raised parent, never below it.
    ly.c.own[item] = 3;
    ly.c.own[tip] = 0;
    ly.c.own[b] = 1;
    order(t, &ly);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1, 3, 1, 1, 0 }, ly.c.layer[0..t.len]);
    try testing.expectEqualSlices(u32, &.{ root, a, c, menu, b, tip, item }, ly.c.order[0..t.len]);

    // All in layer 0: paint order is row order.
    ly.reset();
    order(t, &ly);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5, 6 }, ly.c.order[0..t.len]);
}
