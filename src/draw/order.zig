//! order: paint order and batching. Tier 0.
//!
//!   stacking layers   `paint.emitLayered` paints rows in `overlay.order`'s layer order
//!   merge across text `mergeAcrossText` moves text and custom ops later, past quads that do
//!                     not overlap them, so quads on either side join one batch
//!   depth order       `depthOrder` lists the opaque quads front to back and gives every
//!                     quad and command a depth, for back ends with a depth buffer
//!
//! The tests record how many draw commands (batches) each ordering gives for one scene, the
//! number a GPU back end pays per frame (docs/TARGETS.md D2).

const std = @import("std");
const geometry = @import("geometry.zig");
const paint = @import("paint.zig");
const overlay = @import("../layout/overlay.zig");
const DrawList = @import("draw_list.zig").DrawList;
const simd = @import("../core/simd.zig");

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

/// Reorders `d`'s op stream so that fewer commands result, then encodes it again. A text or
/// custom op is held back while the quads after it do not overlap it (nor any other op held
/// back with it); the held ops are written out, in their order, just before the first quad
/// that overlaps one of them, and at the end. Quads keep their order and their rows, text and
/// custom ops keep theirs, and nothing moves past anything it overlaps, so the picture is the
/// same; quads that were split only by text now run on into one batch. Overlap is tested
/// against one bounding box of the held ops (conservative), on rects cut to their clip.
/// Layers need nothing extra: `paint.emitLayered` has already put the ops in layer order, and
/// a raised quad that overlaps a held run still waits for it.
pub fn mergeAcrossText(d: *DrawList) void {
    const V4 = @Vector(4, f32);
    const sign: V4 = .{ 1, 1, -1, -1 };
    const empty: V4 = @splat(std.math.inf(f32)); // in (x0, y0, -x1, -y1) form: a union identity
    const quad_kind = @backingInt(DrawList.Kind.quads);
    const text_kind = @backingInt(DrawList.Kind.text);
    // Held ops live in the command columns, which `encode` rewrites afterwards.
    const held_kind = d.cmd.kind;
    const held_key = d.cmd.key;
    const held_ref = d.cmd.first;
    var w: u32 = 0;
    var p: u32 = 0;
    var bound = empty;
    for (0..d.op_len) |j| {
        const kind = d.op.kind[j];
        const key = d.op.key[j];
        const ref = d.op.ref[j];
        const is_quad = kind == quad_kind;
        // The op's painted box, from whichever table its kind indexes; every load is clamped
        // so the selects read only valid rows.
        const q = d.quads[@min(ref, d.quads.len - 1)];
        const r = d.runs[@min(ref, d.runs.len - 1)];
        const cd = d.customs[@min(ref, d.customs.len - 1)];
        const qb: V4 = geometry.quadBounds(q);
        const rb: V4 = geometry.intersect(geometry.transformRect(r.rect, r.xform), r.clip);
        const cb: V4 = geometry.intersect(geometry.transformRect(cd.rect, cd.xform), cd.clip);
        const box = @select(f32, @as(@Vector(4, bool), @splat(is_quad)), qb, @select(f32, @as(@Vector(4, bool), @splat(kind == text_kind)), rb, cb)) * sign;
        // Overlap with the held bound: x0 < bx1 and bx0 < x1, same on y.
        const flipped = @shuffle(f32, bound, undefined, @Vector(4, i32){ 2, 3, 0, 1 });
        const overlaps = @reduce(.And, box < -flipped);
        const flush: u32 = @intFromBool(simd.andB(is_quad, overlaps));
        // Write the held ops out before this quad (0 or p of them).
        for (0..p * flush) |k| {
            d.op.kind[w + k] = held_kind[k];
            d.op.key[w + k] = held_key[k];
            d.op.ref[w + k] = held_ref[k];
        }
        w += p * flush;
        p -= p * flush;
        bound = @select(f32, @as(@Vector(4, bool), @splat(flush != 0)), empty, bound);
        // A quad goes out now; a text or custom op is held. Both rows are written always.
        d.op.kind[w] = kind;
        d.op.key[w] = key;
        d.op.ref[w] = ref;
        w += @intFromBool(is_quad);
        held_kind[p] = kind;
        held_key[p] = key;
        held_ref[p] = ref;
        p += @intFromBool(!is_quad);
        bound = @select(f32, @as(@Vector(4, bool), @splat(is_quad)), bound, @min(bound, box));
    }
    for (0..p) |k| {
        d.op.kind[w + k] = held_kind[k];
        d.op.key[w + k] = held_key[k];
        d.op.ref[w + k] = held_ref[k];
    }
    std.debug.assert(w + p == d.op_len);
    paint.encode(d);
}

/// For a back end with a depth buffer (Qt's scene graph renderer does the same with its opaque
/// batches). Writes `d.depth`: every op gets a depth from its place in paint order, later ops
/// nearer (smaller), and `opaques` lists the quads that cover their whole rect with alpha 1,
/// front to back. The back end then
///
///   1. draws the opaque quads in that order with depth test and depth write on, one instanced
///      draw from a copy of those rows: each pixel is shaded once, by its front-most opaque quad;
///   2. draws the usual commands back to front with depth test (less) and no depth write, so
///      everything behind an opaque quad, and the opaque quads themselves, fail early.
///
/// A quad counts as opaque when its fill and any border are fully opaque, its opacity is 1, it
/// uses the stock solid material with plain params on the white texture, and it has square
/// corners, a square clip and no rotation, scale or skew: then every pixel inside its clipped
/// rect is covered with alpha 1. Run after paint (and after `mergeAcrossText`, if used).
pub fn depthOrder(d: *DrawList) void {
    const quad_kind = @backingInt(DrawList.Kind.quads);
    const step = 1.0 / @as(f32, @floatFromInt(d.op_len + 1));
    // Depth per op, by paint order; commands take their first op's depth, so walk the ops and
    // count commands the way `encode` breaks them.
    var cmd: u32 = 0;
    var prev_kind: u8 = 0xff;
    var prev_key: u32 = 0;
    for (0..d.op_len) |j| {
        const kind = d.op.kind[j];
        const key = d.op.key[j];
        const z = 1 - @as(f32, @floatFromInt(j + 1)) * step;
        const brk: u32 = @intFromBool(kind != quad_kind) | @intFromBool(kind != prev_kind) | @intFromBool(key != prev_key);
        cmd += brk;
        // Write always, to the spare last row when there is nothing to write: a select that
        // loads the old value only for itself compiles to a branch (docs/CHECKS.md section 2).
        const spare_quad: u32 = @intCast(d.depth.quad.len - 1);
        const spare_cmd: u32 = @intCast(d.depth.cmd.len - 1);
        d.depth.quad[simd.selU(kind == quad_kind, @min(d.op.ref[j], spare_quad), spare_quad)] = z;
        d.depth.cmd[simd.selU(brk != 0, cmd - 1, spare_cmd)] = z;
        prev_kind = kind;
        prev_key = key;
    }
    // Opaque quads, front to back: the ops walked backwards, write always, advance by 0 or 1.
    var n: u32 = 0;
    var j = d.op_len;
    while (j > 0) {
        j -= 1;
        const ref = @min(d.op.ref[j], d.quads.len - 1);
        const q = d.quads[ref];
        const params: [4]u32 = @bitCast(q.params);
        // Bitwise ANDs of the conditions: `and` would be a jump per condition.
        const flat: u1 = @intFromBool(@reduce(.Or, @as(@Vector(4, u32), params)) == 0);
        const square: u1 = @intFromBool(@reduce(.And, @as(@Vector(4, f32), q.radii) == @as(@Vector(4, f32), @splat(0))));
        const square_clip: u1 = @intFromBool(@reduce(.And, @as(@Vector(4, f32), q.clip_radii) == @as(@Vector(4, f32), @splat(0))));
        const upright: u1 = @intFromBool(@reduce(.And, @as(@Vector(4, f32), q.xform[0..4].*) == @Vector(4, f32){ 1, 0, 0, 1 }));
        const border_ok: u1 = @intFromBool(q.border == 0) | @intFromBool((q.border_color >> 24) == 255);
        const covers: u1 = @intFromBool(d.op.kind[j] == quad_kind) & @intFromBool(d.op.key[j] == 0) &
            @intFromBool((q.fill >> 24) == 255) & @intFromBool(q.opacity >= 1) & flat & square & square_clip & upright & border_ok;
        d.depth.opaques[n] = ref;
        n += covers;
    }
    d.opaque_len = n;
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

test "merge across text: quads split only by labels join one batch; overlapping ones wait" {
    var buf: [List.bytes]u8 align(mem.column_align) = undefined;
    var l: List = .build(&buf);
    const strings = l.s.buf[0..l.s.len];
    paint.emitLayered(&l.t, &l.tx, &l.cu, strings, &l.ly, &l.d);
    var before: [List.cap]@import("draw_list.zig").Quad = undefined;
    @memcpy(before[0..l.d.quad_len], l.d.quads[0..l.d.quad_len]);
    const layered = counts(&l.d);
    mergeAcrossText(&l.d);
    const merged = counts(&l.d);
    // Records, same scene as above. Rows are stacked, so no label overlaps a later row's quad:
    // the labels are held past them and all six row quads join the root's batch. The menu (layer 1) overlaps labels 3 to 5, so they are written out before
    // it and the menu stays a batch of its own. 7 quad batches become 2; text stays 6.
    try testing.expectEqual(Counts{ .quads = 7, .text = 6 }, layered);
    try testing.expectEqual(Counts{ .quads = 2, .text = 6 }, merged);
    // Quads did not move.
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(before[0..l.d.quad_len]), std.mem.sliceAsBytes(l.d.quads[0..l.d.quad_len]));
    // Order: one batch of the 7 background quads, the 6 labels in order, then the menu.
    try testing.expectEqual(@import("draw_list.zig").Cmd{ .quads = .{ .first = 0, .count = 7, .texture = .white, .material = .solid } }, l.d.command(0));
    for (0..6) |k| try testing.expectEqual(@import("draw_list.zig").Cmd{ .text = @intCast(k) }, l.d.command(@intCast(1 + k)));
    try testing.expectEqual(@import("draw_list.zig").Cmd{ .quads = .{ .first = 7, .count = 4, .texture = .white, .material = .solid } }, l.d.command(7));
}

/// One painted item: kind and row in its table, and its box cut to its clip.
const Item = struct { kind: u8, ref: u32, box: [4]f32 };

fn items(d: *const DrawList, out: []Item) u32 {
    var n: u32 = 0;
    for (0..d.cmd_len) |i| switch (d.command(@intCast(i))) {
        .quads => |b| for (b.first..b.first + b.count) |q| {
            out[n] = .{ .kind = 0, .ref = @intCast(q), .box = cut(d.quads[q].rect, d.quads[q].clip) };
            n += 1;
        },
        .text => |k| {
            out[n] = .{ .kind = 1, .ref = k, .box = cut(d.runs[k].rect, d.runs[k].clip) };
            n += 1;
        },
        .custom, .canvas => |k| {
            out[n] = .{ .kind = 2, .ref = k, .box = cut(d.customs[k].rect, d.customs[k].clip) };
            n += 1;
        },
    };
    return n;
}
fn cut(r: [4]f32, c: [4]f32) [4]f32 {
    return .{ @max(r[0], c[0]), @max(r[1], c[1]), @min(r[2], c[2]), @min(r[3], c[3]) };
}
fn overlap(a: [4]f32, b: [4]f32) bool {
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3];
}
/// Every pair of items that overlap is painted in the same relative order in `a` and `b`, and
/// both paint the same items: the pictures are the same.
fn samePicture(a: []const Item, b: []const Item) !void {
    try testing.expectEqual(a.len, b.len);
    for (a, 0..) |x, i| for (a[i + 1 ..]) |y| {
        if (!overlap(x.box, y.box)) continue;
        var px: usize = b.len;
        var py: usize = b.len;
        for (b, 0..) |z, k| {
            if (z.kind == x.kind and z.ref == x.ref) px = k;
            if (z.kind == y.kind and z.ref == y.ref) py = k;
        }
        try testing.expect(px < py and py < b.len);
    };
}

test "merge across text: overlapping items keep their order, in row and in layer order" {
    var buf: [List.bytes]u8 align(mem.column_align) = undefined;
    var l: List = .build(&buf);
    const strings = l.s.buf[0..l.s.len];
    var want: [64]Item = undefined;
    var got: [64]Item = undefined;
    inline for (.{ false, true }) |layered| {
        if (layered) paint.emitLayered(&l.t, &l.tx, &l.cu, strings, &l.ly, &l.d) else paint.emit(&l.t, &l.tx, &l.cu, strings, &l.d);
        const nw = items(&l.d, &want);
        mergeAcrossText(&l.d);
        const ng = items(&l.d, &got);
        try samePicture(want[0..nw], got[0..ng]);
    }
    // Row order records: 6 quad batches become 1 (the menu overlaps no label held when it
    // comes; labels 3 to 5 follow it and still follow it). Layer order: 7 become 2, above.
    paint.emit(&l.t, &l.tx, &l.cu, strings, &l.d);
    mergeAcrossText(&l.d);
    try testing.expectEqual(Counts{ .quads = 1, .text = 6 }, counts(&l.d));
}

test "depth order: opaque quads front to back in one draw; batch counts recorded" {
    var buf: [List.bytes]u8 align(mem.column_align) = undefined;
    var l: List = .build(&buf);
    const strings = l.s.buf[0..l.s.len];
    // Make two quads translucent and round a third: they stay out of the opaque list.
    l.t.c.look[1].fill = types.Color.rgba(30, 30, 30, 128).bitsOf(); // row 0
    l.t.c.look[3].radius = 4; // row 1
    paint.emitLayered(&l.t, &l.tx, &l.cu, strings, &l.ly, &l.d);
    mergeAcrossText(&l.d);
    depthOrder(&l.d);
    // 11 quads, 9 opaque, listed nearest first: the menu's items, the menu, then rows 5 to 2
    // and the root (row 0 is translucent, row 1 rounded).
    try testing.expectEqual(9, l.d.opaque_len);
    const op = l.d.depth.opaques[0..l.d.opaque_len];
    try testing.expectEqualSlices(u32, &.{ 10, 9, 8, 7, 6, 5, 4, 3, 0 }, op);
    for (op[1..], op[0 .. op.len - 1]) |back, front| try testing.expect(l.d.depth.quad[front] < l.d.depth.quad[back]);
    // Depths follow paint order: every command is behind the ones after it.
    for (0..l.d.cmd_len - 1) |k| {
        const a = l.d.command(@intCast(k));
        const b = l.d.command(@intCast(k + 1));
        const za = switch (a) {
            .quads => |q| l.d.depth.quad[q.first],
            else => l.d.depth.cmd[k],
        };
        const zb = switch (b) {
            .quads => |q| l.d.depth.quad[q.first],
            else => l.d.depth.cmd[k + 1],
        };
        try testing.expect(zb < za);
    }
    // Records: with depth, pass 1 is 1 instanced draw of 9 opaque quads, pass 2 the usual 2
    // quad batches and 6 text commands; without depth, the 2 + 6 alone. The second pass then
    // shades only what is in front of the opaque quads.
    try testing.expectEqual(Counts{ .quads = 2, .text = 6 }, counts(&l.d));
}
