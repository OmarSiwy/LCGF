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

    /// One row per tree node, `simd.rows(cap)` rows each. A zeroed row is `Style{}`.
    pub const Columns = struct {
        /// Width over height; 0 for none.
        aspect: []f32,
    };

    /// What `set` writes for one node. The defaults change nothing.
    pub const Style = struct {
        /// Width over height (CSS `aspect-ratio`); 0 for none. The height follows the resolved
        /// width, replacing content, grow, stretch and percent on y; a fit-sized width follows a
        /// px height. min and max still clamp the result.
        aspect: f32 = 0,
    };

    /// Carves the columns from `carver` for a tree of `cap` nodes.
    pub fn init(carver: *mem.Carver, cap: u32) Flex {
        return .{ .c = carver.columns(Columns, simd.rows(cap)) };
    }

    /// Writes node `i`'s row.
    pub fn set(fx: *Flex, i: u32, s: *const Style) void {
        fx.c.aspect[i] = s.aspect;
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
