//! paint: tree and side lists in, draw list out, in three linear sweeps. Tier 0: writes only
//! into the caller's `DrawList`. Ported from prototype/ui.zig ("paint").
//!
//!   1. nodes -> quads and an ordered op stream (write always, advance by 0 or 1)

const std = @import("std");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;
const DrawList = @import("draw_list.zig").DrawList;
const none = types.none;

/// Tree and side lists in, draw list out. `strings` is the storage `TextRun.start` indexes.
pub fn emit(t: *const Tree, tx: *const Texts, cu: *const Customs, strings: []const u8, d: *DrawList) void {
    _ = tx;
    _ = cu;
    _ = strings;
    const c = &t.c;
    const V4 = @Vector(4, f32);
    const sign: V4 = .{ 1, 1, -1, -1 };

    // 1. Nodes -> quads and an ordered op stream. Every row writes its
    //    candidate output; the write index advances by 0 or 1.
    const quads = d.quads;
    const op_kind = d.op.kind;
    const op_key = d.op.key;
    const op_ref = d.op.ref;
    const rect = c.rect;
    const parent = c.parent;
    const child_clip = c.child_clip;
    const looks = c.look;
    var q: u32 = 0;
    var o: u32 = 0;
    for (0..t.len) |i| {
        const vis: u32 = c.visible[i];
        const clip: [4]f32 = @as(V4, child_clip[parent[i]]) * sign;
        const look = looks[i];
        quads[q] = .{
            .rect = .{ rect[0][i], rect[1][i], rect[2][i], rect[3][i] },
            .clip = clip,
            .params = look.params,
            .uv = .{ 0, 0, 1, 1 },
            .fill = look.fill,
            .border_color = look.border_color,
            .radius = look.radius,
            .border = look.border,
        };
        // Painted when either colour has alpha.
        const has_quad = vis & @intFromBool(((look.fill | look.border_color) >> 24) != 0);
        op_kind[o] = @backingInt(DrawList.Kind.quads);
        op_key[o] = @as(u32, look.texture) << 16 | look.material;
        op_ref[o] = q;
        q += has_quad;
        o += has_quad;

        op_kind[o] = @backingInt(DrawList.Kind.text);
        op_key[o] = 0;
        op_ref[o] = c.text[i];
        o += vis & @intFromBool(c.text[i] != none);

        op_kind[o] = @backingInt(DrawList.Kind.custom);
        op_key[o] = 0;
        op_ref[o] = c.custom[i];
        o += vis & @intFromBool(c.custom[i] != none);
    }
    d.quad_len = q;
}

const testing = std.testing;
const mem = @import("../core/mem.zig");
const layout = @import("../layout/layout.zig");
const Strings = @import("../core/strings.zig").Strings;
const Id = types.Id;
const Color = types.Color;

/// A laid-out scene of every op kind: root (clips, filled), a bordered quad, a text leaf, a
/// custom leaf, a quad on another texture, a quad back on the root's texture, and a filled
/// float pushed outside the root's clip, which paints nothing.
const Scene = struct {
    t: Tree,
    tx: Texts,
    cu: Customs,
    s: Strings,
    d: DrawList,

    const cap = 16;
    const bytes = blk: {
        @setEvalBranchQuota(10_000);
        var counter: mem.Carver = .{ .buf = null };
        _ = carve(&counter);
        break :blk counter.off;
    };
    fn carve(carver: *mem.Carver) Scene {
        return .{
            .t = Tree.init(carver, cap),
            .tx = Texts.init(carver, 4),
            .cu = Customs.init(carver, 4),
            .s = .{ .buf = carver.slice(u8, 64) },
            .d = DrawList.init(carver, cap, 4, 4),
        };
    }

    // Node rows, in push order.
    const root = 0;
    const box = 1;
    const label = 2;
    const view = 3;
    const tinted = 4;
    const plain = 5;
    const away = 6;

    /// Builds, lays out and paints the scene in `buf`.
    fn build(buf: *align(mem.column_align) [bytes]u8) Scene {
        var carver: mem.Carver = .{ .buf = buf };
        var sc = carve(&carver);
        const t = &sc.t;
        const fill: Color = .rgb(200, 0, 0);
        _ = t.push(0, Id.from("root"), &.{ .size = .{ .px(400), .px(300) }, .clip = true, .fill = .rgb(10, 10, 10) });
        _ = t.push(root, Id.from("box"), &.{ .size = .{ .px(100), .px(50) }, .fill = fill, .border = 2, .border_color = .white, .radius = 4 });
        _ = t.push(root, Id.from("label"), &.{ .pad = @splat(2) });
        t.c.text[label] = sc.tx.push(label, sc.s.add("hello"), &.{ .px = 10 });
        sc.tx.c.w[0] = 40;
        sc.tx.c.h[0] = 10;
        _ = t.push(root, Id.from("view"), &.{ .size = .{ .px(50), .px(50) } });
        t.c.custom[view] = sc.cu.push(view, Id.from("view"), 77);
        _ = t.push(root, Id.from("tinted"), &.{ .size = .{ .px(20), .px(20) }, .fill = fill, .texture = @fromBackingInt(3) });
        _ = t.push(root, Id.from("plain"), &.{ .size = .{ .px(20), .px(20) }, .fill = fill });
        _ = t.push(root, Id.from("away"), &.{ .size = .{ .px(10), .px(10) }, .float = true, .offset = .{ 1000, 0 }, .fill = fill });
        t.seal(root);
        layout.run(t, &sc.tx, .{ 400, 300 });
        emit(t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len], &sc.d);
        return sc;
    }
};

test "sweep 1: visible painted nodes become quads, every node its ops in paint order" {
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    const sc: Scene = .build(&buf);
    const d = &sc.d;
    // root, box, tinted, plain; `away` is filled but clipped out, label and view are unfilled.
    try testing.expectEqual(4, d.quad_len);
    try testing.expectEqual([4]f32{ 0, 0, 100, 50 }, d.quads[1].rect);
    try testing.expectEqual([4]f32{ 0, 0, 400, 300 }, d.quads[1].clip);
    try testing.expectEqual([4]f32{ 0, 0, 1, 1 }, d.quads[1].uv);
    try testing.expectEqual(Color.rgb(200, 0, 0).bitsOf(), d.quads[1].fill);
    try testing.expectEqual(Color.white.bitsOf(), d.quads[1].border_color);
    try testing.expectEqual(4, d.quads[1].radius);
    try testing.expectEqual(2, d.quads[1].border);
    try testing.expectEqual(sc.t.rect(Scene.plain).array(), d.quads[3].rect);
    // The op stream: quad, quad, text, custom, quad on texture 3, quad.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1, 2, 0, 0 }, d.op.kind[0..6]);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0, 3 << 16, 0 }, d.op.key[0..6]);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 0, 0, 2, 3 }, d.op.ref[0..6]);
}
