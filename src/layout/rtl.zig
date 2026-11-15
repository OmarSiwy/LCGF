//! rtl: right-to-left layout as a sign coefficient on the inline (x) axis, the way
//! prototype/ui.zig makes the stacking direction a coefficient (`Tree.Columns.main`) instead of
//! a tag. Tier 0: no allocator, no I/O. The core passes lay everything out left to right;
//! `mirror` then reflects each child inside its parent's content box when the parent is
//! right-to-left, so stacking order, alignment, offsets and scroll all flip with one formula.
//!
//!   direction  forward sweep   every node's sign: +1 left to right, -1 right to left
//!   startEnd   SIMD            logical start/end padding written as left/right
//!   mirror     forward sweep   after `place`: x positions reflected inside RTL parents

const std = @import("std");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");
const Tree = @import("../core/tree.zig").Tree;

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
