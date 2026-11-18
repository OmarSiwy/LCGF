//! inherit: paint inputs that a node passes down to its subtree, resolved in one parent-ordered
//! sweep after layout and before paint. Tier 0. The values live in the tree's `Extras` rows,
//! which only nodes with a paint extra or a clip have (`Tree.push`); every other node takes its
//! `scope` row's, which equals what a per-node sweep gives it: opacity 1 and the identity
//! transform change nothing, and only a clipping node changes the clip it hands down. Rows are
//! in push order, so a parent's row is final before any child row reads it; the sweeps stay
//! scalar for that reason (docs/DESIGN.md). `paint.emit` runs all three.

const std = @import("std");
const Tree = @import("../core/tree.zig").Tree;
const simd = @import("../core/simd.zig");

/// The row a row's node inherits from: its parent's `scope`, or row 0 (the defaults) for the
/// root, which is its own parent.
inline fn up(t: *const Tree, n: u32) u32 {
    return simd.selU(n == 0, 0, t.c.scope[t.c.parent[n]]);
}

/// Resolves the requested fields on each extra after the row it inherits from.
inline fn sweep(t: *Tree, comptime alpha: bool, comptime world: bool, comptime radii: bool) void {
    const c = &t.c;
    const x = &t.x;
    const V4 = @Vector(4, f32);
    for (1..t.xlen) |r| {
        const i = x.node[r];
        const row = &x.row[r];
        const inherited = &x.row[up(t, i)];
        if (alpha) row.alpha = row.opacity * inherited.alpha;
        if (world) {
            const m = row.transform;
            const cx = (c.rect[0][i] + c.rect[2][i]) * 0.5;
            const cy = (c.rect[1][i] + c.rect[3][i]) * 0.5;
            const local: [6]f32 = .{ m[0], m[1], m[2], m[3], m[4] + cx - (m[0] * cx + m[2] * cy), m[5] + cy - (m[1] * cx + m[3] * cy) };
            row.world = compose(inherited.world, local);
        }
        if (radii) {
            const own = @max(@as(V4, row.radii) - @as(V4, @splat(row.border)), @as(V4, @splat(0)));
            row.clip_radii = @select(f32, @as(@Vector(4, bool), @splat(c.clips[i] != 0)), own, inherited.clip_radii);
        }
    }
}

/// `alpha` of every extras row = its `opacity` times the inherited row's `alpha`: the opacity
/// paint applies to the row's node and the nodes that take its scope. Idempotent: it reads
/// `opacity`, never its own output.
pub fn opacity(t: *Tree) void {
    sweep(t, true, false, false);
}

/// `world` of every extras row = the inherited `world` after the row's `transform` about its
/// node's centre: what maps the node's layout rect to the screen. Run after layout (the centre
/// comes from `rect`). Idempotent like `opacity`.
pub fn transform(t: *Tree) void {
    sweep(t, false, true, false);
}

/// `clip_radii` of every extras row: the corner radii of the clip its node hands its children.
/// A clipping node clips to the area inside its border, so its radii less the border (not
/// below 0); any other node passes the inherited row's on; row 0 is square. Paint gives each
/// quad its parent's. Rounded corners are applied to the clip rect the quad gets, which is the
/// clipping node's inner rect unless an outer clip cut into it.
pub fn clip(t: *Tree) void {
    sweep(t, false, false, true);
}

/// Resolves opacity, transform and clip together in parent order.
pub fn all(t: *Tree) void {
    sweep(t, true, true, true);
}

/// Opacity paint applies to node `i`, after `opacity`.
pub fn alphaOf(t: *const Tree, i: u32) f32 {
    return t.x.row[t.c.scope[i]].alpha;
}

/// Layout space to screen for node `i`, after `transform`.
pub fn worldOf(t: *const Tree, i: u32) [6]f32 {
    return t.x.row[t.c.scope[i]].world;
}

/// Corner radii of the clip node `i` hands its children, after `clip`.
pub fn clipRadiiOf(t: *const Tree, i: u32) [4]f32 {
    return t.x.row[t.c.scope[i]].clip_radii;
}

/// p after l: x -> p(l(x)).
inline fn compose(p: [6]f32, l: [6]f32) [6]f32 {
    return .{
        p[0] * l[0] + p[2] * l[1],
        p[1] * l[0] + p[3] * l[1],
        p[0] * l[2] + p[2] * l[3],
        p[1] * l[2] + p[3] * l[3],
        p[0] * l[4] + p[2] * l[5] + p[4],
        p[1] * l[4] + p[3] * l[5] + p[5],
    };
}

/// Where `world` sends the point (x, y).
pub fn apply(m: [6]f32, x: f32, y: f32) [2]f32 {
    return .{ m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5] };
}

const testing = std.testing;
const mem = @import("../core/mem.zig");
const Id = @import("../core/types.zig").Id;

test "opacity: nested opacities multiply down the tree, siblings do not affect each other" {
    const bytes = comptime blk: {
        @setEvalBranchQuota(10_000);
        var counter: mem.Carver = .{ .buf = null };
        _ = Tree.init(&counter, 8);
        break :blk counter.off;
    };
    var buf: [bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var t = Tree.init(&carver, 8);
    const root = t.push(0, Id.from("root"), &.{ .opacity = 0.8 });
    const half = t.push(root, .none, &.{ .opacity = 0.5 });
    const inner = t.push(half, .none, &.{ .opacity = 0.5 });
    const leaf = t.push(inner, .none, &.{});
    t.seal(inner);
    t.seal(half);
    const side = t.push(root, .none, &.{});
    t.seal(root);
    opacity(&t);
    opacity(&t); // a second run gives the same result
    try testing.expectEqual(0.8, alphaOf(&t, root));
    try testing.expectEqual(0.4, alphaOf(&t, half));
    try testing.expectEqual(0.2, alphaOf(&t, inner));
    try testing.expectEqual(0.2, alphaOf(&t, leaf));
    try testing.expectEqual(0.8, alphaOf(&t, side));
}

test "opacity: paint fades quads by the instance opacity and text by its colour's alpha" {
    const Texts = @import("../core/texts.zig").Texts;
    const Customs = @import("../core/customs.zig").Customs;
    const Strings = @import("../core/strings.zig").Strings;
    const DrawList = @import("draw_list.zig").DrawList;
    const S = struct {
        t: Tree,
        tx: Texts,
        cu: Customs,
        s: Strings,
        d: DrawList,
        fn carve(carver: *mem.Carver) @This() {
            return .{ .t = Tree.init(carver, 8), .tx = Texts.init(carver, 2), .cu = Customs.init(carver, 2), .s = .{ .buf = carver.slice(u8, 16) }, .d = DrawList.init(carver, 8, 2, 2) };
        }
    };
    const bytes = comptime blk: {
        @setEvalBranchQuota(10_000);
        var counter: mem.Carver = .{ .buf = null };
        _ = S.carve(&counter);
        break :blk counter.off;
    };
    var buf: [bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var sc = S.carve(&carver);
    const t = &sc.t;
    _ = t.push(0, Id.from("root"), &.{ .size = .{ .px(100), .px(100) }, .opacity = 0.5, .fill = .white });
    const label = t.push(0, .none, &.{});
    t.c.text[label] = sc.tx.push(label, sc.s.add("hi"), &.{ .color = .rgba(10, 20, 30, 200) });
    const gone = t.push(0, .none, &.{ .size = .{ .px(10), .px(10) }, .opacity = 0, .fill = .white });
    t.seal(0);
    @import("../layout/layout.zig").run(t, &sc.tx, .{ 100, 100 });
    opacity(t);
    @import("paint.zig").emit(t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len], &sc.d);
    // The root quad carries its opacity; the fully transparent node paints nothing.
    try testing.expectEqual(1, sc.d.quad_len);
    try testing.expectEqual(0.5, sc.d.quads[0].opacity);
    try testing.expectEqual(0.0, alphaOf(t, gone));
    // Text has no instance opacity: its colour's alpha is scaled, 200 * 0.5.
    try testing.expectEqual(@import("../core/types.zig").Color.rgba(10, 20, 30, 100).bitsOf(), sc.d.runs[0].color);
}

test "transform: about the centre, composed down the tree" {
    const bytes = comptime blk: {
        @setEvalBranchQuota(10_000);
        var counter: mem.Carver = .{ .buf = null };
        _ = Tree.init(&counter, 8);
        break :blk counter.off;
    };
    var buf: [bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var t = Tree.init(&carver, 8);
    _ = t.push(0, Id.from("root"), &.{});
    // A 100x100 box at (0, 0) turned 90 degrees clockwise about (50, 50), and inside it a child
    // moved 10 px right in its own frame.
    const box = t.push(0, .none, &.{ .transform = .{ 0, 1, -1, 0, 0, 0 } });
    const kid = t.push(box, .none, &.{ .transform = .{ 1, 0, 0, 1, 10, 0 } });
    t.seal(box);
    t.seal(0);
    // Rects as layout would leave them.
    inline for (.{ 0, 0, 100, 100 }, 0..) |v, k| t.c.rect[k][box] = v;
    inline for (.{ 0, 0, 20, 20 }, 0..) |v, k| t.c.rect[k][kid] = v;
    transform(&t);
    transform(&t);
    try testing.expectEqual([6]f32{ 1, 0, 0, 1, 0, 0 }, worldOf(&t, 0));
    // The box's centre stays put; its top-left corner goes to the top-right.
    try testing.expectEqual([2]f32{ 50, 50 }, apply(worldOf(&t, box), 50, 50));
    try testing.expectEqual([2]f32{ 100, 0 }, apply(worldOf(&t, box), 0, 0));
    // The child: moved right by 10, then turned with the box: right becomes down.
    try testing.expectEqual([2]f32{ 100, 10 }, apply(worldOf(&t, kid), 0, 0));
}

test "clip: a clipping node's radii less its border reach every descendant until the next clip" {
    const bytes = comptime blk: {
        @setEvalBranchQuota(10_000);
        var counter: mem.Carver = .{ .buf = null };
        _ = Tree.init(&counter, 8);
        break :blk counter.off;
    };
    var buf: [bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var t = Tree.init(&carver, 8);
    _ = t.push(0, Id.from("root"), &.{ .radius = 9 });
    const card = t.push(0, .none, &.{ .clip = true, .radius = 12, .border = 2, .radii = .{ -1, -1, 1, 0 } });
    const row = t.push(card, .none, &.{ .radius = 30 });
    const inner = t.push(row, .none, &.{ .clip = true });
    t.seal(inner);
    t.seal(row);
    t.seal(card);
    t.seal(0);
    clip(&t);
    clip(&t);
    try testing.expectEqual([4]f32{ 0, 0, 0, 0 }, clipRadiiOf(&t, 0)); // root does not clip
    try testing.expectEqual([4]f32{ 10, 10, 0, 0 }, clipRadiiOf(&t, card));
    try testing.expectEqual([4]f32{ 10, 10, 0, 0 }, clipRadiiOf(&t, row)); // not clipping: passes it on
    try testing.expectEqual([4]f32{ 0, 0, 0, 0 }, clipRadiiOf(&t, inner)); // square clip of its own
}

test "one pass over nested extras preserves separately computed alpha, transforms and clips" {
    var buf: [32 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var t = Tree.init(&carver, 8);
    var parent = t.push(0, .none, &.{ .opacity = 0.875, .clip = true, .radius = 12, .border = 0.5 });
    for (0..5) |i| {
        parent = t.push(parent, .none, &.{
            .opacity = 0.625,
            .clip = i % 2 != 0,
            .radii = .{ 1.5, 2, 3.5, 4 },
            .transform = .{ 0, 1, -1, 0, 1.25, -2.125 },
        });
        t.c.rect[0][parent] = @floatFromInt(i);
        t.c.rect[2][parent] = t.c.rect[0][parent] + 3.5;
    }
    opacity(&t);
    transform(&t);
    clip(&t);
    var want: [9]@import("../core/tree.zig").Extra = undefined;
    @memcpy(want[0..t.xlen], t.x.row[0..t.xlen]);
    for (t.x.row[1..t.xlen]) |*extra| {
        extra.alpha = -1;
        extra.world = @splat(98);
        extra.clip_radii = @splat(42);
    }
    all(&t);
    try testing.expectEqualSlices(@import("../core/tree.zig").Extra, want[0..t.xlen], t.x.row[0..t.xlen]);
}
