//! overlay: nodes that sit on top of other nodes instead of beside them. Tier 0: no allocator,
//! no I/O. Built on what the core passes already do with `Style.float` and `Style.offset`
//! (prototype/ui.zig): a floating node is placed at its parent's content origin plus `offset`
//! and takes no part in the parent's flow.
//!
//!   zstack     a container whose children all overlap, sized to the largest of them

const std = @import("std");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;

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

const testing = std.testing;
const mem = @import("../core/mem.zig");
const layout = @import("layout.zig");
const Texts = @import("../core/texts.zig").Texts;
const Id = types.Id;
const Rect = types.Rect;

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
