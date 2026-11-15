//! Sizing rules of the layout passes beyond the prototype's grow/fit/px: the min, max and percent
//! rules every node already has, checked here rule by rule. Tier 0.

const std = @import("std");
const layout = @import("layout.zig");
const mem = @import("../core/mem.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;

const testing = std.testing;

/// A small tree and an empty text list in one caller-owned buffer, for the rule tests.
const Scene = struct {
    raw: [96 * 1024]u8 align(mem.column_align) = undefined,
    t: Tree = undefined,
    tx: Texts = undefined,

    fn init(s: *Scene) *Tree {
        var carver: mem.Carver = .{ .buf = &s.raw };
        s.t = Tree.init(&carver, 16);
        s.tx = Texts.init(&carver, 1);
        return &s.t;
    }
    fn run(s: *Scene, w: f32, h: f32) void {
        s.t.seal(0);
        layout.run(&s.t, &s.tx, .{ w, h });
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
