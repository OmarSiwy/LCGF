//! order: paint order and batching. Tier 0.
//!
//!   stacking layers   `paint.emitLayered` paints rows in `overlay.order`'s layer order
//!
//! The tests record how many draw commands (batches) each ordering gives for one scene, the
//! number a GPU back end pays per frame (docs/TARGETS.md D2).

const std = @import("std");
const paint = @import("paint.zig");
const overlay = @import("../layout/overlay.zig");
const DrawList = @import("draw_list.zig").DrawList;

/// Quad batches, text and custom commands in `d`, for the batch-count records.
pub const Counts = struct { quads: u32 = 0, text: u32 = 0, custom: u32 = 0 };

pub fn counts(d: *const DrawList) Counts {
    var n: Counts = .{};
    for (d.cmd.kind[0..d.cmd_len]) |k| {
        n.quads += @intFromBool(k == @backingInt(DrawList.Kind.quads));
        n.text += @intFromBool(k == @backingInt(DrawList.Kind.text));
        n.custom += @intFromBool(k == @backingInt(DrawList.Kind.custom));
    }
    return n;
}

const testing = std.testing;
const mem = @import("../core/mem.zig");
const types = @import("../core/types.zig");
const layout = @import("../layout/layout.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;
const Strings = @import("../core/strings.zig").Strings;
const Id = types.Id;

/// A list of six rows, each a filled row with a label, and a menu hanging from row 2 in layer 1
/// with three filled items, overlapping rows 3 to 5.
const List = struct {
    t: Tree,
    tx: Texts,
    cu: Customs,
    s: Strings,
    d: DrawList,
    ly: overlay.Layers,
    menu: u32 = 0,

    const cap = 32;
    const bytes = blk: {
        @setEvalBranchQuota(20_000);
        var counter: mem.Carver = .{ .buf = null };
        _ = carve(&counter);
        break :blk counter.off;
    };
    fn carve(carver: *mem.Carver) List {
        return .{
            .t = Tree.init(carver, cap),
            .tx = Texts.init(carver, 8),
            .cu = Customs.init(carver, 2),
            .s = .{ .buf = carver.slice(u8, 64) },
            .d = DrawList.init(carver, cap, 8, 2),
            .ly = overlay.Layers.init(carver, cap),
        };
    }
    fn build(buf: *align(mem.column_align) [bytes]u8) List {
        var carver: mem.Carver = .{ .buf = buf };
        var l = carve(&carver);
        const t = &l.t;
        _ = t.push(0, Id.from("root"), &.{ .size = .{ .px(200), .px(200) }, .clip = true, .fill = .rgb(10, 10, 10) });
        for (0..6) |r| {
            const row = t.push(0, .none, &.{ .size = .{ .fill, .px(24) }, .pad = @splat(4), .fill = .rgb(30, 30, 30) });
            const label = t.push(row, .none, &.{});
            t.c.text[label] = l.tx.push(label, l.s.add("row"), &.{});
            l.tx.c.w[r] = 30;
            l.tx.c.h[r] = 12;
            if (r == 2) {
                l.menu = t.push(row, .none, &.{ .float = true, .offset = .{ 20, 20 }, .size = .{ .px(80), .fit }, .fill = .rgb(60, 60, 60) });
                for (0..3) |_| _ = t.push(l.menu, .none, &.{ .size = .{ .fill, .px(20) }, .fill = .rgb(90, 90, 90) });
                t.seal(l.menu);
            }
            t.seal(row);
        }
        t.seal(0);
        layout.run(t, &l.tx, .{ 200, 200 });
        l.ly.reset();
        l.ly.c.own[l.menu] = 1;
        overlay.order(t, &l.ly);
        return l;
    }
};

test "stacking layers: a raised menu paints after every row; batch counts recorded" {
    var buf: [List.bytes]u8 align(mem.column_align) = undefined;
    var l: List = .build(&buf);
    const strings = l.s.buf[0..l.s.len];

    // Row order: the menu paints in the middle and rows 3 to 5 cover it.
    paint.emit(&l.t, &l.tx, &l.cu, strings, &l.d);
    const flat = counts(&l.d);
    const last_flat = l.d.command(l.d.cmd_len - 1);
    // Layer order: the menu and its items are the last quads.
    paint.emitLayered(&l.t, &l.tx, &l.cu, strings, &l.ly, &l.d);
    const layered = counts(&l.d);
    const last = l.d.command(l.d.cmd_len - 1);

    try testing.expectEqual(DrawList.Kind.text, std.meta.activeTag(last_flat));
    try testing.expectEqual(l.d.quad_len - 4, last.quads.first); // menu + 3 items, one batch
    try testing.expectEqual(4, last.quads.count);
    try testing.expectEqual(l.t.rect(l.menu).array(), l.d.quads[last.quads.first].rect);
    // The records: 11 quads (root, 6 rows, menu, 3 items) and 6 labels. Row order: 6 quad
    // batches, because each label breaks the run and the menu's quads run on into row 3's.
    // Layer order: 7, one more, since the menu's four quads are a batch of their own at the end.
    // Correct stacking costs one batch here; C0288 merges across the labels.
    try testing.expectEqual(11, l.d.quad_len);
    try testing.expectEqual(Counts{ .quads = 6, .text = 6 }, flat);
    try testing.expectEqual(Counts{ .quads = 7, .text = 6 }, layered);
}

test "stacking layers: with no node raised, layer order paints exactly like row order" {
    var buf: [List.bytes]u8 align(mem.column_align) = undefined;
    var l: List = .build(&buf);
    l.ly.reset();
    overlay.order(&l.t, &l.ly);
    const strings = l.s.buf[0..l.s.len];
    paint.emit(&l.t, &l.tx, &l.cu, strings, &l.d);
    var quads: [List.cap]@import("draw_list.zig").Quad = undefined;
    @memcpy(quads[0..l.d.quad_len], l.d.quads[0..l.d.quad_len]);
    const n = l.d.cmd_len;
    paint.emitLayered(&l.t, &l.tx, &l.cu, strings, &l.ly, &l.d);
    try testing.expectEqual(n, l.d.cmd_len);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(quads[0..l.d.quad_len]), std.mem.sliceAsBytes(l.d.quads[0..l.d.quad_len]));
}
