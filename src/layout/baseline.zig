//! Baselines. Every node gets a first baseline, the distance from its top edge down to the line
//! its text sits on, so a row can line its children's text up (CSS `align-items: baseline`).
//! `fitFlex(.y)` carries it bottom-up in the sweep it already makes:
//!
//!   a node with a text run    padding top + the run's baseline (`apply`)
//!   a column                  padding top + its first in-flow child's (margin top included)
//!   a row                     padding top + the lowest of its in-flow children's
//!   anything else             its bottom edge (CSS synthesizes one there)
//!
//! A baseline is measured from the node's own top, so growing or stretching the node later does
//! not move it. Tier 0.

const std = @import("std");
const layout = @import("layout.zig");
const flex = @import("flex.zig");
const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Strings = @import("../core/strings.zig").Strings;
const Flex = flex.Flex;
const b01 = simd.b2f;

/// Scatters each text run's first baseline (`ascent[k]` for run k, measured from the run's
/// top, as the font reports it with `w` and `h`) into its node, and marks which nodes carry
/// text this frame. Call after measuring and before `fitFlex(.y)`. `ascent` has one row per run.
pub fn apply(t: *const Tree, fx: *const Flex, tx: *const Texts, ascent: []const f32) void {
    std.debug.assert(ascent.len >= tx.len);
    @memset(fx.c.text_has[0..simd.padded(t.len)], 0);
    for (tx.c.node[0..tx.len], ascent[0..tx.len]) |node, base| {
        fx.c.text_base[node] = base;
        fx.c.text_has[node] = 1;
    }
}

/// fitFlex, once node `i`'s children are folded and its natural height `nat` is known: its
/// baseline. On x the result is rewritten by the y sweep before anything reads it.
pub inline fn settle(t: *const Tree, fx: *const Flex, i: usize, nat: f32) void {
    const f = &fx.c;
    const text = f.text_has[i];
    const kids = b01(t.c.nkids[i] > 0);
    const has = @max(text, kids);
    const inside = f.base_kids[i] + text * (f.text_base[i] - f.base_kids[i]);
    f.base[i] = nat + has * (t.c.pad_lo[1][i] + inside - nat);
}

/// fitFlex: folds in-flow child `i`'s baseline (below its top margin) into parent `p`: the
/// first child's in a column (the reverse sweep sees it last, so it overwrites), the largest
/// in a row.
pub inline fn fold(t: *const Tree, fx: *const Flex, i: usize, p: usize) void {
    const f = &fx.c;
    const v = f.margin_lo[1][i] + f.base[i];
    const row = @max(f.base_kids[p], v);
    const pick = row + t.c.main[1][p] * (v - row);
    f.base_kids[p] += t.c.flow[i] * (pick - f.base_kids[p]);
    const below = t.c.nat[1][i] + f.margin_hi[1][i] - f.base[i];
    f.below_kids[p] += t.c.flow[i] * (@max(f.below_kids[p], below) - f.below_kids[p]);
}

/// 1.0 when node `p` is a row that lines its children up by baseline: a row, not wrapping.
inline fn baseRow(t: *const Tree, fx: *const Flex, p: usize) f32 {
    return fx.c.align_base[p] * t.c.main[0][p] * (1 - fx.c.wrap[p]);
}

/// fitFlex, on y: a baseline-aligned row's content height is its children's highest part above
/// the shared baseline plus their deepest part below it, not the tallest child. Otherwise
/// `content`.
pub inline fn content(t: *const Tree, fx: *const Flex, a: u1, i: usize, plain: f32) f32 {
    const on_y: f32 = @floatFromInt(a);
    const stacked = fx.c.base_kids[i] + fx.c.below_kids[i];
    return plain + on_y * baseRow(t, fx, i) * (stacked - plain);
}

/// placeFlex, on y: in a baseline-aligned row, child `i` sits so its baseline is at the row's
/// (`base_kids`, below the row's padding), unless it has its own cross alignment. Otherwise
/// `plain`.
pub inline fn across(t: *const Tree, fx: *const Flex, i: usize, p: usize, plain: f32) f32 {
    const f = &fx.c;
    const own = b01(f.self_cross[i] >= 0);
    const by_base = f.base_kids[p] - f.base[i];
    return plain + baseRow(t, fx, p) * (1 - own) * (by_base - plain);
}

const testing = std.testing;
const types = @import("../core/types.zig");

/// A tree, its text runs with hand-set extents, and Flex rows in one buffer.
const Scene = struct {
    raw: [128 * 1024]u8 align(mem.column_align) = undefined,
    t: Tree = undefined,
    tx: Texts = undefined,
    fx: Flex = undefined,
    strings: Strings = undefined,
    ascent: [8]f32 = @splat(0),

    fn init(s: *Scene) *Tree {
        var carver: mem.Carver = .{ .buf = &s.raw };
        s.t = Tree.init(&carver, 24);
        s.tx = Texts.init(&carver, 8);
        s.fx = Flex.init(&carver, 24);
        s.strings = .{ .buf = carver.slice(u8, 64) };
        return &s.t;
    }
    /// A leaf under `parent` with a text run of `w` x `h` whose baseline is `asc` below its top.
    fn text(s: *Scene, parent: u32, style: *const types.Style, w: f32, h: f32, asc: f32) u32 {
        const n = s.t.push(parent, .none, style);
        const k = s.tx.push(n, s.strings.add("x"), &.{});
        s.t.c.text[n] = k;
        s.tx.c.w[k] = w;
        s.tx.c.h[k] = h;
        s.ascent[k] = asc;
        return n;
    }
    fn run(s: *Scene, w: f32, h: f32) void {
        s.t.seal(0);
        const t = &s.t;
        layout.prepare(t);
        layout.applyText(t, &s.tx, .x);
        layout.fitFlex(t, &s.fx, .x);
        layout.resolveFlex(t, &s.fx, .x, w);
        @import("wrap.zig").wrap(t, &s.fx);
        apply(t, &s.fx, &s.tx, &s.ascent);
        layout.applyText(t, &s.tx, .y);
        layout.fitFlex(t, &s.fx, .y);
        layout.resolveFlex(t, &s.fx, .y, h);
        layout.placeFlex(t, &s.fx);
        layout.finalize(t);
    }
    fn base(s: *const Scene, i: u32) f32 {
        return s.fx.c.base[i];
    }
};

test "baseline: a text node's is its run's, below its padding" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(200) } });
    const a = s.text(root, &.{}, 40, 12, 9);
    const b = s.text(root, &.{ .pad = .{ 0, 5, 0, 0 } }, 40, 12, 9);
    s.run(200, 200);
    try testing.expectEqual(9, s.base(a));
    try testing.expectEqual(14, s.base(b));
}

test "baseline: a column takes its first in-flow child's, a row its lowest child's" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(300), .px(300) } });
    const col = t.push(root, .none, &.{ .pad = .{ 0, 3, 0, 0 } });
    _ = t.push(col, .none, &.{ .float = true, .size = .{ .px(5), .px(50) } }); // floats: no say
    _ = s.text(col, &.{}, 40, 12, 9);
    _ = s.text(col, &.{}, 40, 30, 25);
    t.seal(col);
    const row = t.push(root, .none, &.{ .dir = .x, .pad = .{ 0, 2, 0, 0 } });
    _ = s.text(row, &.{}, 40, 12, 9);
    const big = s.text(row, &.{}, 40, 30, 25);
    _ = s.text(row, &.{}, 40, 20, 15);
    t.seal(row);
    s.fx.set(big, &.{ .margin = .{ 0, 4, 0, 0 } });
    s.run(300, 300);
    try testing.expectEqual(3 + 9, s.base(col));
    // The lowest child baseline counts its top margin: 4 + 25.
    try testing.expectEqual(2 + 4 + 25, s.base(row));
}

test "baseline: a node with neither text nor children has it at its bottom edge" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(200) } });
    const box = t.push(root, .none, &.{ .size = .{ .px(10), .px(18) } });
    const row = t.push(root, .none, &.{ .dir = .x, .pad = .{ 0, 1, 0, 0 } });
    _ = t.push(row, .none, &.{ .size = .{ .px(10), .px(7) } });
    t.seal(row);
    s.run(200, 200);
    try testing.expectEqual(18, s.base(box));
    try testing.expectEqual(1 + 7, s.base(row));
}

test "baseline: carried up through nesting, and measured from the node's own top" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(300), .px(300) } });
    const outer = t.push(root, .none, &.{ .pad = .{ 0, 10, 0, 0 } });
    const card = t.push(outer, .none, &.{ .dir = .x, .pad = @splat(4) });
    _ = s.text(card, &.{}, 40, 16, 12);
    t.seal(card);
    t.seal(outer);
    s.run(300, 300);
    try testing.expectEqual(4 + 12, s.base(card));
    try testing.expectEqual(10 + 4 + 12, s.base(outer));
    // The text line sits at outer's top + its baseline.
    try testing.expectEqual(s.t.c.pos[1][outer] + s.base(outer), s.t.c.pos[1][card] + s.base(card));
}

test "baseline alignment: children of a baseline row share one baseline" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(300), .px(300) } });
    const row = t.push(root, .none, &.{ .dir = .x, .gap = 4, .pad = .{ 0, 2, 0, 0 } });
    s.fx.set(row, &.{ .baseline = true });
    const a = s.text(row, &.{}, 40, 12, 9); // small text
    const b = s.text(row, &.{}, 40, 30, 24); // large text
    const c = t.push(row, .none, &.{ .size = .{ .px(10), .px(40) } }); // a box: baseline at its bottom
    t.seal(row);
    s.run(300, 300);
    // The row's baseline is the lowest: c's 40. Each child's baseline lands on y = 2 + 40.
    try testing.expectEqual(2 + 40, s.base(row));
    inline for (.{ a, b, c }) |k| try testing.expectEqual(2 + 40, t.c.pos[1][k] + s.base(k));
    // Above: 40; below: a's 3, b's 6, c's 0.
    try testing.expectEqual(2 + 40 + 6, t.c.size[1][row]);
}

test "baseline alignment: margins count; a child's own cross alignment wins" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(300), .px(300) } });
    const row = t.push(root, .none, &.{ .dir = .x, .size = .{ .fit, .px(100) } });
    s.fx.set(row, &.{ .baseline = true });
    const a = s.text(row, &.{}, 40, 12, 9);
    const b = s.text(row, &.{}, 40, 30, 24);
    const c = s.text(row, &.{}, 40, 12, 9);
    s.fx.set(a, &.{ .margin = .{ 0, 0, 0, 20 } }); // 20 below a: the row needs 3 + 20 under it
    s.fx.set(b, &.{ .margin = .{ 0, 5, 0, 0 } }); // 5 above b: the baseline is 5 + 24
    s.fx.set(c, &.{ .cross = .end });
    t.seal(row);
    s.run(300, 300);
    try testing.expectEqual(29, s.fx.c.base_kids[row]);
    try testing.expectEqual(29 - 9, t.c.pos[1][a]);
    try testing.expectEqual(5, t.c.pos[1][b]);
    try testing.expectEqual(100 - 12, t.c.pos[1][c]);
    // Content: 29 above, 23 below (a's 3 + 20); the px(100) height then clamps the row.
    try testing.expectEqual(23, s.fx.c.below_kids[row]);
}

test "baseline alignment: a nested row aligns by its own baseline; columns ignore the flag" {
    var s: Scene = .{};
    const t = s.init();
    const root = t.push(0, .none, &.{ .size = .{ .px(300), .px(300) } });
    const row = t.push(root, .none, &.{ .dir = .x });
    s.fx.set(row, &.{ .baseline = true });
    const label = s.text(row, &.{}, 40, 12, 9);
    // A button: padding 6 around a 16 px run whose baseline is 12 down.
    const button = t.push(row, .none, &.{ .dir = .x, .pad = @splat(6) });
    const caption = s.text(button, &.{}, 30, 16, 12);
    t.seal(button);
    t.seal(row);
    const col = t.push(root, .none, &.{});
    s.fx.set(col, &.{ .baseline = true });
    const x = s.text(col, &.{}, 40, 12, 9);
    const y = s.text(col, &.{}, 40, 30, 24);
    t.seal(col);
    s.run(300, 300);
    // button's baseline is 6 + 12 = 18; label moves down to meet it.
    try testing.expectEqual(18, s.base(button));
    try testing.expectEqual(t.c.pos[1][caption] + s.base(caption), t.c.pos[1][label] + s.base(label));
    try testing.expectEqual(18 - 9, t.c.pos[1][label] - t.c.pos[1][row]);
    // The column stacks as before.
    try testing.expectEqual(12, t.c.pos[1][y] - t.c.pos[1][x]);
}
