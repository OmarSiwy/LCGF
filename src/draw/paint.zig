//! paint: tree and side lists in, draw list out, in three linear sweeps. Tier 0: writes only
//! into the caller's `DrawList`. Ported from prototype/ui.zig ("paint").
//!
//!   1. nodes -> quads and an ordered op stream (write always, advance by 0 or 1)
//!   2. side lists -> text runs and custom draws (one row per run or draw that exists)
//!   3. ops -> commands by run-length encoding (equal-key quads merge into one batch)

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;
const DrawList = @import("draw_list.zig").DrawList;
const none = types.none;

/// Tree and side lists in, draw list out. `strings` is the storage `TextRun.start` indexes.
pub fn emit(t: *const Tree, tx: *const Texts, cu: *const Customs, strings: []const u8, d: *DrawList) void {
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
            .uv = c.uv[i],
            .fill = look.fill,
            .border_color = look.border_color,
            .radii = c.radii[i],
            .border = look.border,
            .opacity = c.alpha[i],
            .xform = c.world[i],
        };
        // Painted when either colour has alpha and the node is not fully transparent.
        const has_quad = vis & @intFromBool(((look.fill | look.border_color) >> 24) != 0) & @intFromBool(c.alpha[i] > 0);
        op_kind[o] = @backingInt(DrawList.Kind.quads);
        op_key[o] = (@as(u32, look.texture) << 16) | look.material;
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

    // 2. Side lists -> geometry. One row per text run or custom draw that
    //    exists; nodes without either cost nothing here.
    for (0..tx.len) |k| {
        const n = tx.c.node[k];
        d.runs[k] = .{
            .rect = .{
                c.rect[0][n] + c.pad_lo[0][n], c.rect[1][n] + c.pad_lo[1][n],
                c.rect[2][n] - c.pad_hi[0][n], c.rect[3][n] - c.pad_hi[1][n],
            },
            .clip = @as(V4, c.child_clip[c.parent[n]]) * sign,
            .start = tx.c.start[k],
            .bytes = tx.c.bytes[k],
            .px = tx.c.px[k],
            .color = fade(tx.c.color[k], c.alpha[n]),
            .font = tx.c.font[k],
        };
    }
    d.run_len = tx.len;
    for (0..cu.len) |k| {
        const n = cu.c.node[k];
        d.customs[k] = .{
            .rect = .{ c.rect[0][n], c.rect[1][n], c.rect[2][n], c.rect[3][n] },
            .clip = @as(V4, c.child_clip[c.parent[n]]) * sign,
            .data = cu.c.data[k],
            .id = cu.c.id[k],
            .node = n,
        };
    }
    d.custom_len = cu.len;
    d.strings = strings;

    // 3. Ops -> commands by run-length encoding. Consecutive quads with the
    //    same texture and material merge; text and custom ops stand alone.
    var n: u32 = 0;
    var prev_kind: u8 = 0xff;
    var prev_key: u32 = 0;
    for (0..o) |j| {
        const kind = d.op.kind[j];
        const key = d.op.key[j];
        const brk: u32 = @intFromBool(kind != 0) | @intFromBool(kind != prev_kind) | @intFromBool(key != prev_key);
        n += brk;
        const k = n - 1; // the first op always breaks, so n >= 1 here
        d.cmd.kind[k] = kind;
        d.cmd.key[k] = key;
        d.cmd.first[k] = simd.selU(brk != 0, d.op.ref[j], d.cmd.first[k]);
        d.cmd.count[k] = d.cmd.count[k] * (1 - brk) + 1;
        prev_kind = kind;
        prev_key = key;
    }
    d.cmd_len = n;
}

/// `color` (rgba8, alpha in the top byte) with its alpha times `alpha`, rounded. Exact for 1.
inline fn fade(color: u32, alpha: f32) u32 {
    const a: f32 = @floatFromInt(color >> 24);
    const scaled: u32 = @intFromFloat(@round(a * std.math.clamp(alpha, 0, 1)));
    return (color & 0x00ff_ffff) | (scaled << 24);
}

const testing = std.testing;
const mem = @import("../core/mem.zig");
const layout = @import("../layout/layout.zig");
const Strings = @import("../core/strings.zig").Strings;
const Id = types.Id;
const Color = types.Color;
const Cmd = @import("draw_list.zig").Cmd;

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
    try testing.expectEqual([4]f32{ 4, 4, 4, 4 }, d.quads[1].radii);
    try testing.expectEqual(2, d.quads[1].border);
    try testing.expectEqual(sc.t.rect(Scene.plain).array(), d.quads[3].rect);
    // The op stream: quad, quad, text, custom, quad on texture 3, quad.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1, 2, 0, 0 }, d.op.kind[0..6]);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0, 3 << 16, 0 }, d.op.key[0..6]);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 0, 0, 2, 3 }, d.op.ref[0..6]);
}

test "sweep 2: text runs get the content box, custom draws the node rect, both the parent clip" {
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    const sc: Scene = .build(&buf);
    const d = &sc.d;
    const label = sc.t.rect(Scene.label);
    try testing.expectEqual(1, d.run_len);
    try testing.expectEqual([4]f32{ label.x0 + 2, label.y0 + 2, label.x1 - 2, label.y1 - 2 }, d.runs[0].rect);
    try testing.expectEqual([4]f32{ 2, 52, 42, 62 }, d.runs[0].rect);
    try testing.expectEqual([4]f32{ 0, 0, 400, 300 }, d.runs[0].clip);
    try testing.expectEqualStrings("hello", d.strings[d.runs[0].start..][0..d.runs[0].bytes]);
    try testing.expectEqual(10, d.runs[0].px);
    try testing.expectEqual(Color.white.bitsOf(), d.runs[0].color);
    try testing.expectEqual(0, d.runs[0].font);
    try testing.expectEqual(1, d.custom_len);
    try testing.expectEqual(sc.t.rect(Scene.view).array(), d.customs[0].rect);
    try testing.expectEqual([4]f32{ 0, 0, 400, 300 }, d.customs[0].clip);
    try testing.expectEqual(77, d.customs[0].data);
    try testing.expectEqual(@backingInt(Id.from("view")), d.customs[0].id);
    try testing.expectEqual(Scene.view, d.customs[0].node);
}

test "sweep 3: equal-key quads merge, a key change or a text or custom op breaks the batch" {
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    const sc: Scene = .build(&buf);
    const d = &sc.d;
    try testing.expectEqual(5, d.cmd_len);
    try testing.expectEqual(Cmd{ .quads = .{ .first = 0, .count = 2, .texture = .white, .material = .solid } }, d.command(0));
    try testing.expectEqual(Cmd{ .text = 0 }, d.command(1));
    try testing.expectEqual(Cmd{ .custom = 0 }, d.command(2));
    try testing.expectEqual(Cmd{ .quads = .{ .first = 2, .count = 1, .texture = @fromBackingInt(3), .material = .solid } }, d.command(3));
    try testing.expectEqual(Cmd{ .quads = .{ .first = 3, .count = 1, .texture = .white, .material = .solid } }, d.command(4));
}

test "sweep 3: a repaint into a used draw list gives the same commands" {
    // `count` accumulates from the previous row's value, so stale rows must not leak in.
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    var sc: Scene = .build(&buf);
    const first = sc.d.command(0);
    emit(&sc.t, &sc.tx, &sc.cu, sc.d.strings, &sc.d);
    try testing.expectEqual(5, sc.d.cmd_len);
    try testing.expectEqual(first, sc.d.command(0));
    try testing.expectEqual(Cmd{ .quads = .{ .first = 3, .count = 1, .texture = .white, .material = .solid } }, sc.d.command(4));
}

test "children of a clipping node are clipped inside its border; a non-clipping border passes the clip on" {
    // The inset itself is computed by layout.finalize into `child_clip`; paint must hand that
    // clip, not the parent's outer rect, to every quad, run and custom draw of the children.
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var sc = Scene.carve(&carver);
    const t = &sc.t;
    const fill: Color = .rgb(0, 0, 200);
    _ = t.push(0, Id.from("root"), &.{ .size = .{ .px(400), .px(300) }, .clip = true });
    const framed = t.push(0, Id.from("framed"), &.{ .size = .{ .px(200), .px(100) }, .clip = true, .border = 3, .border_color = .white });
    _ = t.push(framed, Id.from("inner"), &.{ .size = .{ .px(300), .px(20) }, .fill = fill });
    const caption = t.push(framed, Id.from("caption"), &.{});
    t.c.text[caption] = sc.tx.push(caption, sc.s.add("x"), &.{});
    const view = t.push(framed, Id.from("view"), &.{ .size = .{ .px(10), .px(10) } });
    t.c.custom[view] = sc.cu.push(view, Id.from("view"), 0);
    t.seal(framed);
    const open = t.push(0, Id.from("open"), &.{ .size = .{ .px(200), .px(100) }, .border = 3, .border_color = .white });
    const loose = t.push(open, Id.from("loose"), &.{ .size = .{ .px(10), .px(10) }, .fill = fill });
    t.seal(open);
    t.seal(0);
    layout.run(t, &sc.tx, .{ 400, 300 });
    emit(t, &sc.tx, &sc.cu, sc.s.buf[0..sc.s.len], &sc.d);
    const d = &sc.d;

    // Quads: framed (border only), inner, open, loose.
    try testing.expectEqual(4, d.quad_len);
    try testing.expectEqual([4]f32{ 0, 0, 400, 300 }, d.quads[0].clip);
    try testing.expectEqual([4]f32{ 0, 0, 300, 20 }, d.quads[1].rect);
    try testing.expectEqual([4]f32{ 3, 3, 197, 97 }, d.quads[1].clip);
    try testing.expectEqual([4]f32{ 3, 3, 197, 97 }, d.runs[0].clip);
    try testing.expectEqual([4]f32{ 3, 3, 197, 97 }, d.customs[0].clip);
    try testing.expectEqual(sc.t.rect(loose).array(), d.quads[3].rect);
    try testing.expectEqual([4]f32{ 0, 0, 400, 300 }, d.quads[3].clip);
}

test "a renderer's one switch per command draws every quad, run and custom once, in order" {
    // The host loop of prototype/example.zig: one switch per command.
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    const sc: Scene = .build(&buf);
    const d = &sc.d;
    var next_quad: u32 = 0;
    var batches: u32 = 0;
    var runs: u32 = 0;
    var customs: u32 = 0;
    for (0..d.cmd_len) |i| switch (d.command(@intCast(i))) {
        .quads => |batch| {
            try testing.expectEqual(next_quad, batch.first);
            next_quad += batch.count;
            batches += 1;
        },
        .text => |k| {
            try testing.expectEqual(runs, k);
            runs += 1;
        },
        .custom => |k| {
            try testing.expectEqual(customs, k);
            try testing.expectEqual(sc.t.rect(Scene.view).array(), d.customs[k].rect);
            customs += 1;
        },
    };
    try testing.expectEqual(d.quad_len, next_quad);
    try testing.expect(batches < d.quad_len);
    try testing.expectEqual(d.run_len, runs);
    try testing.expectEqual(d.custom_len, customs);
    try testing.expectEqual(d.quad_len * @sizeOf(@import("draw_list.zig").Quad), d.quadBytes().len);
}

test "an empty tree paints nothing" {
    var buf: [Scene.bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var sc = Scene.carve(&carver);
    emit(&sc.t, &sc.tx, &sc.cu, "", &sc.d);
    try testing.expectEqual(0, sc.d.quad_len + sc.d.run_len + sc.d.custom_len + sc.d.cmd_len);
}
