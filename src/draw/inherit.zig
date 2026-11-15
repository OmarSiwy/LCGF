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
