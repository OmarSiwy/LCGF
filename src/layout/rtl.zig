//! rtl: right-to-left layout as a sign coefficient on the inline (x) axis, the way
//! prototype/ui.zig makes the stacking direction a coefficient (`Tree.Columns.main`) instead of
//! a tag. Tier 0: no allocator, no I/O. The core passes lay everything out left to right;
//! `mirror` then reflects each child inside its parent's content box when the parent is
//! right-to-left, so stacking order, alignment, offsets and scroll all flip with one formula.
//!
//!   direction  forward sweep   every node's sign: +1 left to right, -1 right to left
//!   startEnd   SIMD            logical start/end padding written as left/right
//!   factor     scalar          an `Align` factor as seen under a sign, for code placing on x
//!   mirror     forward sweep   after `place`: x positions reflected inside RTL parents

const std = @import("std");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");
const Tree = @import("../core/tree.zig").Tree;
const Align = @import("../core/types.zig").Align;

/// Inline direction of a node's content. `inherit` takes the parent's; the root inherits
/// left to right.
pub const Dir = enum(u8) {
    inherit,
    ltr,
    rtl,

    pub const sign = [3]f32{ 0, 1, -1 };
};

/// The direction columns, one row per node of a tree of capacity `cap`.
pub const Rtl = struct {
    c: Columns,

    pub const Columns = struct {
        /// Set by the caller: `Dir.sign` of the node's own direction, 0 to inherit.
        dir: []f32,
        /// Written by `direction`: +1 or -1.
        sign: []f32,
        /// Scratch for `mirror`: how far each node has moved along x.
        shift: []f32,
        /// 1.0 when the node's x padding is given as `start` and `end` (`pad`).
        logical: []f32,
        start: []f32,
        end: []f32,
    };

    pub fn init(carver: *mem.Carver, cap: u32) Rtl {
        std.debug.assert(cap > 0);
        return .{ .c = carver.columns(Columns, simd.rows(cap)) };
    }
    /// Every node back to `inherit`, for the next frame.
    pub fn reset(r: *Rtl) void {
        @memset(r.c.dir, 0);
        @memset(r.c.logical, 0);
    }
    /// Gives `node` padding at the start and end of its inline axis instead of `Style.pad`'s
    /// left and right: start is the left in a left-to-right node, the right in a right-to-left
    /// one. `startEnd` writes it into the tree.
    pub fn pad(r: *Rtl, node: u32, start: f32, end: f32) void {
        r.c.logical[node] = 1;
        r.c.start[node] = start;
        r.c.end[node] = end;
    }
    pub fn set(r: *Rtl, node: u32, d: Dir) void {
        r.c.dir[node] = Dir.sign[@backingInt(d)];
    }
};

/// Every node's effective sign: its own direction, or its parent's when it inherits. One
/// forward sweep, `dir + (1 - |dir|) * parent`, no branch. Needs only `parent`, so it can run
/// as soon as the tree is built.
pub fn direction(t: *const Tree, r: *Rtl) void {
    if (t.len == 0) return;
    const dir = r.c.dir;
    const sign = r.c.sign;
    const parent = t.c.parent;
    sign[0] = dir[0] + (1 - @abs(dir[0]));
    for (1..t.len) |i| sign[i] = dir[i] + (1 - @abs(dir[i])) * sign[parent[i]];
}

/// SIMD. Writes the left and right padding of every node given logical padding (`Rtl.pad`):
/// start on the left under +1, on the right under -1. Other nodes keep `Style.pad`. Run after
/// `direction` and before `fit`; it writes the same values every time, so it may run again.
/// Because `mirror` reflects children inside the content box, the content box itself must
/// already have its start padding on the right; that is what this pass is for.
pub fn startEnd(t: *Tree, r: *const Rtl) void {
    const lo = t.c.pad_lo[0];
    const hi = t.c.pad_hi[0];
    const n = simd.padded(t.len);
    const one = simd.f(1);
    const half = simd.f(0.5);
    var i: usize = 0;
    while (i < n) : (i += simd.lanes) {
        const ltr = (one + simd.loadF(r.c.sign, i)) * half;
        const start = simd.loadF(r.c.start, i);
        const end = simd.loadF(r.c.end, i);
        const left = end + ltr * (start - end);
        const right = start + ltr * (end - start);
        const logical = simd.loadF(r.c.logical, i);
        const l = simd.loadF(lo, i);
        const h = simd.loadF(hi, i);
        simd.storeF(lo, i, l + logical * (left - l));
        simd.storeF(hi, i, h + logical * (right - h));
    }
}

/// The share of leftover space placed on the left for `a` (prototype `Align.factor`) under
/// `sign`: `f` left to right, `1 - f` right to left, as `f + (1 - sign) / 2 * (1 - 2f)`. The
/// layout passes do not need it: `mirror` reflects the result, which mirrors every alignment
/// at once. It is for code that places along x by itself from a node's alignment and
/// direction, such as a text run aligned inside its box.
pub fn factor(a: Align, sign: f32) f32 {
    const f = Align.factor[@backingInt(a)];
    return f + (1 - sign) * 0.5 * (1 - 2 * f);
}

/// Reflects every child of a right-to-left parent along x inside the parent's content box, and
/// carries the move down to its subtree. Run after `place` and `direction`, before anything
/// that places in absolute coordinates (`overlay.anchor`) and before `finalize`.
///
/// With `rel` the child's left edge measured from the parent's content left edge, the child's
/// new `rel` is `rel + (1 - sign) / 2 * (inner - size - 2 * rel)`: unchanged for +1, mirrored
/// for -1. The first child then sits at the right, `Align.start` means right, and a positive
/// `offset` or `scroll` moves the other way. `Style.pad` stays physical (left stays left).
pub fn mirror(t: *Tree, r: *Rtl) void {
    if (t.len == 0) return;
    const parent = t.c.parent;
    const pos = t.c.pos[0];
    const size = t.c.size[0];
    const lo = t.c.pad_lo[0];
    const hi = t.c.pad_hi[0];
    const sign = r.c.sign;
    const shift = r.c.shift;
    shift[0] = 0;
    for (1..t.len) |i| {
        const p = parent[i];
        const inner = size[p] - lo[p] - hi[p];
        // pos[p] has moved already; pos[i] has not.
        const rel = pos[i] - (pos[p] - shift[p]) - lo[p];
        const flip = (1 - sign[p]) * 0.5;
        shift[i] = shift[p] + flip * (inner - size[i] - 2 * rel);
        pos[i] += shift[i];
    }
}

const testing = std.testing;
const types = @import("../core/types.zig");
const layout = @import("layout.zig");
const Texts = @import("../core/texts.zig").Texts;

/// A tree, an empty text list and the direction columns in a caller-owned buffer.
const Scene = struct {
    raw: [128 * 1024]u8 align(mem.column_align) = undefined,
    t: Tree = undefined,
    tx: Texts = undefined,
    r: Rtl = undefined,

    fn init(s: *Scene) void {
        var carver: mem.Carver = .{ .buf = &s.raw };
        s.t = Tree.init(&carver, 32);
        s.tx = Texts.init(&carver, 1);
        s.r = Rtl.init(&carver, 32);
    }
    /// `layout.run` with `direction` and `startEnd` first and `mirror` between `place` and
    /// `finalize`.
    fn run(s: *Scene, viewport: [2]f32) void {
        const t = &s.t;
        direction(t, &s.r);
        startEnd(t, &s.r);
        layout.prepare(t);
        layout.applyText(t, &s.tx, .x);
        layout.fit(t, .x);
        layout.resolve(t, .x, viewport[0]);
        layout.applyText(t, &s.tx, .y);
        layout.fit(t, .y);
        layout.resolve(t, .y, viewport[1]);
        layout.place(t);
        mirror(t, &s.r);
        layout.finalize(t);
    }
};

fn rect(x0: f32, y0: f32, x1: f32, y1: f32) types.Rect {
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

test "direction: inherited down the tree, overridden per node" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    const root = t.push(0, .none, &.{});
    const a = t.push(root, .none, &.{});
    const a1 = t.push(a, .none, &.{});
    t.seal(a1);
    t.seal(a);
    const b = t.push(root, .none, &.{});
    t.seal(b);
    t.seal(root);
    s.r.reset();
    direction(t, &s.r);
    try testing.expectEqualSlices(f32, &.{ 1, 1, 1, 1 }, s.r.c.sign[0..4]);
    s.r.set(root, .rtl);
    s.r.set(a1, .ltr);
    direction(t, &s.r);
    try testing.expectEqualSlices(f32, &.{ -1, -1, 1, -1 }, s.r.c.sign[0..4]);
    _ = .{ a, b };
}

test "mirror: a right-to-left row stacks from the right; subtrees follow, an LTR island stays LTR" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    // row 300x100, gap 10 { a 50, b 70 { b1 20 }, c fill { c1 30, c2 40 (c is LTR) } }
    const row = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(300), .px(100) }, .gap = 10 });
    const a = t.push(row, .none, &.{ .size = .{ .px(50), .px(10) } });
    t.seal(a);
    const b = t.push(row, .none, &.{ .size = .{ .px(70), .px(10) } });
    const b1 = t.push(b, .none, &.{ .size = .{ .px(20), .px(5) } });
    t.seal(b1);
    t.seal(b);
    const c = t.push(row, .none, &.{ .dir = .x, .size = .{ .fill, .px(10) } });
    const c1 = t.push(c, .none, &.{ .size = .{ .px(30), .px(5) } });
    t.seal(c1);
    const c2 = t.push(c, .none, &.{ .size = .{ .px(40), .px(5) } });
    t.seal(c2);
    t.seal(c);
    t.seal(row);

    // Left to right, the passes' own result.
    s.r.reset();
    s.run(.{ 300, 100 });
    try testing.expectEqual(rect(0, 0, 50, 10), t.rect(a));
    try testing.expectEqual(rect(60, 0, 130, 10), t.rect(b));
    try testing.expectEqual(rect(60, 0, 80, 5), t.rect(b1));
    try testing.expectEqual(rect(140, 0, 300, 10), t.rect(c));
    try testing.expectEqual(rect(140, 0, 170, 5), t.rect(c1));

    s.r.set(row, .rtl);
    s.r.set(c, .ltr);
    s.run(.{ 300, 100 });
    try testing.expectEqual(rect(250, 0, 300, 10), t.rect(a));
    try testing.expectEqual(rect(170, 0, 240, 10), t.rect(b));
    // b inherits RTL: its child sits at its right edge.
    try testing.expectEqual(rect(220, 0, 240, 5), t.rect(b1));
    // c is placed by its RTL parent but lays its own children out left to right.
    try testing.expectEqual(rect(0, 0, 160, 10), t.rect(c));
    try testing.expectEqual(rect(0, 0, 30, 5), t.rect(c1));
    try testing.expectEqual(rect(30, 0, 70, 5), t.rect(c2));
    // y is untouched.
    try testing.expectEqual(0, t.rect(b1).y0);
}

test "startEnd: start padding is on the left left to right and on the right right to left" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    // col 200 wide { row (start 10, end 2) { a 50 }, box 100 (start 20) { b1 30 },
    // plain 100 with physical left padding 5 { p1 30 } }
    const col = t.push(0, .none, &.{ .size = .{ .px(200), .px(100) } });
    const row = t.push(col, .none, &.{ .dir = .x, .size = .{ .fill, .px(10) } });
    const a = t.push(row, .none, &.{ .size = .{ .px(50), .px(10) } });
    t.seal(a);
    t.seal(row);
    const box = t.push(col, .none, &.{ .size = .{ .px(100), .px(10) } });
    const b1 = t.push(box, .none, &.{ .size = .{ .px(30), .px(5) } });
    t.seal(b1);
    t.seal(box);
    const plain = t.push(col, .none, &.{ .size = .{ .px(100), .px(10) }, .pad = .{ 5, 0, 0, 0 } });
    const p1 = t.push(plain, .none, &.{ .size = .{ .px(30), .px(5) } });
    t.seal(p1);
    t.seal(plain);
    t.seal(col);
    s.r.reset();
    s.r.pad(row, 10, 2);
    s.r.pad(box, 20, 0);

    s.run(.{ 200, 100 });
    try testing.expectEqual(10, t.rect(a).x0);
    try testing.expectEqual(20, t.rect(b1).x0);
    try testing.expectEqual(5, t.rect(p1).x0);

    s.r.set(col, .rtl);
    s.run(.{ 200, 100 });
    // End padding 2 on the left, start 10 on the right: a ends at 200 - 10.
    try testing.expectEqualSlices(f32, &.{ 2, 10 }, &.{ t.c.pad_lo[0][row], t.c.pad_hi[0][row] });
    try testing.expectEqual(rect(140, 0, 190, 10), t.rect(a));
    // box is placed at the right of col; b1 ends 20 px before box's right edge.
    try testing.expectEqual(rect(100, 10, 200, 20), t.rect(box));
    try testing.expectEqual(rect(150, 10, 180, 15), t.rect(b1));
    // Physical padding stays on the left: p1 is mirrored inside plain's content box 105..200.
    try testing.expectEqual(rect(170, 20, 200, 25), t.rect(p1));

    // Running it twice gives the same padding.
    startEnd(t, &s.r);
    try testing.expectEqualSlices(f32, &.{ 2, 10 }, &.{ t.c.pad_lo[0][row], t.c.pad_hi[0][row] });
}

test "factor: start and end swap under -1, center stays" {
    try testing.expectEqual(0, factor(.start, 1));
    try testing.expectEqual(1, factor(.end, 1));
    try testing.expectEqual(1, factor(.start, -1));
    try testing.expectEqual(0, factor(.end, -1));
    try testing.expectEqual(0.5, factor(.center, -1));
    try testing.expectEqual(0.5, factor(.center, 1));
}

test "mirror: under RTL, alignment lands where the mirrored factor puts it left to right" {
    // One child, aligned along x as the parent's main axis (a row) and as its cross axis (a
    // column), for every Align: mirrored layout == plain layout with the x factor from `factor`.
    inline for (.{ .start, .center, .end }) |al| {
        inline for (.{ types.Axis.x, types.Axis.y }) |d| {
            var rtl_: Scene = .{};
            var ltr_: Scene = .{};
            rtl_.init();
            ltr_.init();
            inline for (.{ &rtl_, &ltr_ }) |sc| {
                const t = &sc.t;
                const p = t.push(0, .none, &.{ .dir = d, .size = .{ .px(200), .px(50) }, .pad = .{ 3, 0, 7, 0 }, .main = al, .cross = al });
                t.seal(t.push(p, .none, &.{ .size = .{ .px(40), .px(10) } }));
                t.seal(p);
                sc.r.reset();
            }
            rtl_.r.set(0, .rtl);
            // The plain layout's x factor, as `factor` gives it for -1: the main one for a row,
            // the cross one for a column. y is not mirrored.
            if (d == .x) ltr_.t.c.align_main[0] = factor(al, -1) else ltr_.t.c.align_cross[0] = factor(al, -1);
            rtl_.run(.{ 200, 50 });
            ltr_.run(.{ 200, 50 });
            try testing.expectEqual(ltr_.t.rect(1), rtl_.t.rect(1));
        }
    }
    // Spelled out for the row: inner box 3..193; start puts the 40 px child at the right.
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    const p = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(200), .px(50) }, .pad = .{ 3, 0, 7, 0 }, .cross = .end });
    t.seal(t.push(p, .none, &.{ .size = .{ .px(40), .px(10) } }));
    t.seal(p);
    s.r.reset();
    s.r.set(p, .rtl);
    s.run(.{ 200, 50 });
    try testing.expectEqual(rect(153, 40, 193, 50), t.rect(1));
}

test "rtl: a right-to-left window with a toolbar, a grid form and a horizontal scroller" {
    const grid = @import("grid.zig");
    const scroll = @import("scroll.zig");
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 32);
    var tx = Texts.init(&carver, 1);
    var r = Rtl.init(&carver, 32);
    var gs = grid.Grids.init(&carver, .{ .grids = 1, .tracks = 4, .items = 4, .cells = 2 });
    const ext: [2][]f32 = .{ carver.slice(f32, simd.rows(32)), carver.slice(f32, simd.rows(32)) };

    // window 300 x 200, gap 4 {
    //   bar (row, start padding 8, gap 6) { back 40, title fill, menu 30 }
    //   form (grid [px 60, fr 1] x [fit]) { label, field }
    //   strip (row, 100 wide, clips) { three 100 px pages }
    // }
    const window = t.push(0, .none, &.{ .size = .{ .px(300), .px(200) }, .gap = 4 });
    const bar = t.push(window, .none, &.{ .dir = .x, .size = .{ .fill, .px(20) }, .gap = 6 });
    const back = t.push(bar, .none, &.{ .size = .{ .px(40), .fill } });
    t.seal(back);
    const title = t.push(bar, .none, &.{ .size = .{ .fill, .fill } });
    t.seal(title);
    const menu = t.push(bar, .none, &.{ .size = .{ .px(30), .fill } });
    t.seal(menu);
    t.seal(bar);
    const form = t.push(window, .none, &.{ .size = .{ .fill, .fit } });
    const k = gs.grid(form, &.{ .px(60), .fr(1) }, &.{.px(16)});
    const label = t.push(form, .none, &.{ .float = true });
    t.seal(label);
    _ = gs.autoItem(k, label);
    const field = t.push(form, .none, &.{ .float = true });
    t.seal(field);
    _ = gs.autoItem(k, field);
    t.seal(form);
    const strip = t.push(window, .none, &.{ .dir = .x, .size = .{ .px(100), .px(30) }, .clip = true });
    var pages: [3]u32 = undefined;
    for (&pages) |*p| {
        p.* = t.push(strip, .none, &.{ .size = .{ .px(100), .fill } });
        t.seal(p.*);
    }
    t.seal(strip);
    t.seal(window);
    r.reset();
    r.set(window, .rtl);
    r.pad(bar, 8, 0);

    const frame = struct {
        fn f(tt: *Tree, ttx: *Texts, rr: *Rtl, g: *grid.Grids, e: [2][]f32) void {
            direction(tt, rr);
            startEnd(tt, rr);
            grid.autoPlace(g);
            layout.prepare(tt);
            layout.applyText(tt, ttx, .x);
            grid.fit(tt, g, .x);
            grid.resolve(tt, g, .x, 300);
            layout.applyText(tt, ttx, .y);
            grid.fit(tt, g, .y);
            grid.resolve(tt, g, .y, 200);
            scroll.extent(tt, e);
            scroll.clamp(tt, e);
            layout.place(tt);
            mirror(tt, rr);
            layout.finalize(tt);
        }
    }.f;
    frame(&t, &tx, &r, &gs, ext);

    // The toolbar reads from the right, after its 8 px start padding: back, title, menu.
    try testing.expectEqual(rect(252, 0, 292, 20), t.rect(back));
    try testing.expectEqual(rect(36, 0, 246, 20), t.rect(title));
    try testing.expectEqual(rect(0, 0, 30, 20), t.rect(menu));
    // The grid's first column is on the right.
    try testing.expectEqual(rect(240, 24, 300, 40), t.rect(label));
    try testing.expectEqual(rect(0, 24, 240, 40), t.rect(field));
    // The strip is at the start (right) of the window; its first page fills it and the rest
    // overflow to the left, out of view.
    try testing.expectEqual(rect(200, 44, 300, 74), t.rect(strip));
    try testing.expectEqual(rect(200, 44, 300, 74), t.rect(pages[0]));
    try testing.expectEqual(rect(100, 44, 200, 74), t.rect(pages[1]));
    try testing.expectEqual(0, t.c.visible[pages[1]]);
    // A positive scroll brings the next page in from the left; past the end it is clamped.
    t.c.scroll[0][strip] = 1000;
    frame(&t, &tx, &r, &gs, ext);
    try testing.expectEqual(200, t.c.scroll[0][strip]);
    try testing.expectEqual(rect(200, 44, 300, 74), t.rect(pages[2]));
    try testing.expectEqual(1, t.c.visible[pages[2]]);
    try testing.expectEqual(0, t.c.visible[pages[0]]);
}
