//! inherit: paint inputs that a node passes down to its subtree, resolved in one parent-ordered
//! sweep after layout and before paint. Tier 0. Rows are in push order, so a parent's value is
//! final before any child reads it; the sweep stays scalar for that reason (docs/DESIGN.md).

const std = @import("std");
const Tree = @import("../core/tree.zig").Tree;
const simd = @import("../core/simd.zig");

/// `alpha[i]` = `opacity[i]` times the parent's `alpha`: the opacity paint applies to node `i`.
/// The root takes its own. Idempotent: it reads `opacity`, never its own output.
pub fn opacity(t: *Tree) void {
    const c = &t.c;
    for (0..t.len) |i| {
        // Both operands loaded, so the root test is a select, not a branch.
        const up = c.alpha[c.parent[i]];
        c.alpha[i] = c.opacity[i] * simd.selF(i == 0, 1, up);
    }
}

/// `world[i]` = the parent's `world` after node `i`'s `transform` about its own centre: what
/// maps the node's layout rect to the screen. Run after layout (the centre comes from `rect`).
/// The root's parent is the identity. Idempotent like `opacity`.
pub fn transform(t: *Tree) void {
    const c = &t.c;
    const V6 = @Vector(6, f32);
    const identity: V6 = .{ 1, 0, 0, 1, 0, 0 };
    for (0..t.len) |i| {
        const m = c.transform[i];
        const cx = (c.rect[0][i] + c.rect[2][i]) * 0.5;
        const cy = (c.rect[1][i] + c.rect[3][i]) * 0.5;
        // Translate the centre to the origin, apply m, translate back.
        const l: [6]f32 = .{ m[0], m[1], m[2], m[3], m[4] + cx - (m[0] * cx + m[2] * cy), m[5] + cy - (m[1] * cx + m[3] * cy) };
        const p: [6]f32 = @select(f32, @as(@Vector(6, bool), @splat(i == 0)), identity, @as(V6, c.world[c.parent[i]]));
        c.world[i] = compose(p, l);
    }
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
    try testing.expectEqual(0.8, t.c.alpha[root]);
    try testing.expectEqual(0.4, t.c.alpha[half]);
    try testing.expectEqual(0.2, t.c.alpha[inner]);
    try testing.expectEqual(0.2, t.c.alpha[leaf]);
    try testing.expectEqual(0.8, t.c.alpha[side]);
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
    try testing.expectEqual(0.0, t.c.alpha[gone]);
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
    try testing.expectEqual([6]f32{ 1, 0, 0, 1, 0, 0 }, t.c.world[0]);
    // The box's centre stays put; its top-left corner goes to the top-right.
    try testing.expectEqual([2]f32{ 50, 50 }, apply(t.c.world[box], 50, 50));
    try testing.expectEqual([2]f32{ 100, 0 }, apply(t.c.world[box], 0, 0));
    // The child: moved right by 10, then turned with the box: right becomes down.
    try testing.expectEqual([2]f32{ 100, 10 }, apply(t.c.world[kid], 0, 0));
}
