//! Interop between the two front ends (tier 1): a runtime `Frame` inside a region of a comptime
//! UI, and a comptime UI inside a runtime `Frame`. Neither front end knows about the other. The
//! host lays out the outer UI, reads the region's rect from it, and runs the inner front end
//! over `regionInput`: the region's size as its viewport and the pointer in the region's
//! coordinates. The inner front end's root (`Context.begin`'s, or a comptime spec's) is laid out
//! at (0, 0) in its region, as the prototype's `Frame.open` / `Frame.end` lay out any root.
//!
//! The other way round, a runtime `Frame` reserves the region as a node (`Frame.custom`, so the
//! draw list keeps its place in paint order), and after `Frame.end` the comptime `Layout` runs
//! with that node's size as its viewport; `widgetRects` and `regionInput` give `Events` its
//! rects and pointer.
//!
//! Either way the two front ends paint two draw lists, and `compose` makes them one: the host's,
//! with the guest's commands in place of the region's custom command, moved to the region and
//! clipped to it. A renderer takes the result like any draw list.

const std = @import("std");
const Input = @import("../core/input.zig").Input;
const spec_zig = @import("spec.zig");
const Spec = spec_zig.Spec;
const Style = @import("../core/types.zig").Style;
const draw_list = @import("../draw/draw_list.zig");
const DrawList = draw_list.DrawList;

/// A region: an empty column named `id` whose content another front end builds. Its rect comes
/// from the comptime layout like any node's; `id` makes it a tag of `Events(spec).Widget`, whose
/// value is its row.
pub fn region(comptime id: @EnumLiteral(), comptime style: Style) Spec {
    return canvas(id, style, 0);
}

/// A region sized by its content: on each axis whose `style` size is `fit`, it
/// takes the size its owner measured last (`setFit`). The comptime layout runs before the content
/// exists, so the owner builds the content in a viewport of its own after it, reports its size,
/// and on a change lays the page out again in the same frame (`ComptimeUi.rebuild`).
pub fn fitRegion(comptime id: @EnumLiteral(), comptime style: Style) Spec {
    var out = region(id, style);
    out.widget = FitRegion(@tagName(id));
    return out;
}

/// The `Spec.widget` of a `fitRegion` named `name`.
pub fn FitRegion(comptime name: [:0]const u8) type {
    return struct {
        /// The region's own custom command; no others.
        pub const custom_slots = 0;

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            _ = in;
            next.* += 1;
            const tb = &ui.tables;
            const kept = ui.keep(@This());
            var st = n.style;
            inline for (0..2) |a| {
                if (comptime n.style.size[a].kind == .fit) st.size[a] = .px(kept[a]);
            }
            const id = @import("../core/types.zig").Id.hash(name);
            const i = tb.t.push(parent, id, &st);
            tb.t.c.custom[i] = tb.cu.push(i, id, n.custom orelse 0);
            tb.t.seal(i);
        }
    };
}

/// Records the content size `size` of the `fitRegion` named `id` in comptime UI `ui`, for its
/// next frame. True when it changed, so the caller asks for another frame.
pub fn setFit(ui: anytype, comptime id: @EnumLiteral(), size: [2]f32) bool {
    const kept = ui.keep(FitRegion(@tagName(id)));
    const changed = kept[0] != size[0] or kept[1] != size[1];
    kept[0] = size[0];
    kept[1] = size[1];
    return changed;
}

/// A leaf whose custom command gives the host its final bounds, clip, id and opaque payload.
pub fn canvas(comptime id: @EnumLiteral(), comptime style: Style, comptime data: u64) Spec {
    var out = spec_zig.col(style, .{});
    out.id = @tagName(id);
    out.custom = data;
    return out;
}

/// Row `row`'s rect (x0, y0, x1, y1) in a comptime layout's RAM (`Columns.Dynamic`), as f32
/// whatever the coordinate type.
pub fn rectOf(ram: anytype, row: usize) [4]f32 {
    return coordinates(ram, row, "rect");
}

/// The widget rect table `Events(spec).Rects` from a comptime layout's RAM: each widget's
/// visible rect (`vis`), in the layout's own coordinates, as `Rects.fromTree` takes it from a
/// runtime tree. Judge the pointer against it through `regionInput`.
pub fn widgetRects(comptime E: type, ram: anytype) E.Rects {
    var r: E.Rects = .{};
    for (E.widget_nodes, 0..) |node, k| {
        const box = coordinates(ram, node, "vis");
        inline for (0..4) |side| r.c[side][k] = box[side];
    }
    return r;
}

/// Shared slots hold the selected alternative's geometry. An invisible descriptor
/// yields an empty box so a hidden hosted region or widget cannot claim that geometry.
fn coordinates(ram: anytype, row: usize, comptime col: []const u8) [4]f32 {
    const shared = @hasField(@TypeOf(ram.*), "geometry_slots");
    const slot = if (shared) ram.geometry_slots.by_node[row] else row;
    var box: [4]f32 = undefined;
    inline for (&box, 0..) |*x, k| x.* = toF32(@field(ram, col)[k][slot]);
    if (!shared) return box;
    return @select(f32, @as(@Vector(4, bool), @splat(ram.visible[row] != 0)), @as(@Vector(4, f32), box), @as(@Vector(4, f32), @splat(0)));
}

fn toF32(x: anytype) f32 {
    return if (@TypeOf(x) == f32) x else @floatFromInt(x);
}

/// The input of a front end hosted in `rect` (x0, y0, x1, y1, in `outer`'s coordinates): the
/// rect's size as its viewport, and the pointer moved by the rect's origin. Everything else is
/// `outer`'s. A pointer outside the rect lands outside the hosted root, which clips to the
/// viewport, so nothing in the region is hit; a drag that started inside keeps its widget, as
/// in a window. `contacts` keep window coordinates (their slice is the host's).
pub fn regionInput(outer: *const Input, rect: [4]f32) Input {
    var in = outer.*;
    in.viewport = .{ rect[2] - rect[0], rect[3] - rect[1] };
    in.pointer = .{ outer.pointer[0] - rect[0], outer.pointer[1] - rect[1] };
    return in;
}

/// `clip` moved by `off` and cut to `w`, all x0, y0, x1, y1: the larger lows, the smaller highs.
/// A select, not a blend: clips may be infinite.
fn cut(clip: [4]f32, off: @Vector(4, f32), w: [4]f32) [4]f32 {
    const moved = @as(@Vector(4, f32), clip) + off;
    const within: @Vector(4, f32) = w;
    return @select(f32, @Vector(4, bool){ true, true, false, false }, @max(moved, within), @min(moved, within));
}

/// `host` with `guest` drawn in the region `region_id`: the host's custom command whose
/// `CustomDraw.id` is `region_id` is replaced, in paint order, by all of `guest`'s commands. The
/// guest is in its region's coordinates (its root at (0, 0), as `regionInput` lays it out): its
/// rects move by the region's origin, its clips are cut to the region's rect and clip, and its
/// transforms keep their screen positions relative to the region. Its strings follow the host's
/// in `strings`, the caller's buffer, which `out.strings` then points into.
///
/// `out` is the caller's, carved for the host's rows plus the guest's. Nothing is written when
/// it, or `strings`, is too small, or when the host has no such region. Batches are not merged
/// across the seams, and `out` has no ops, depth or damage (`.everything`): run `order` or
/// `damage` passes on it afterwards if the renderer wants them.
pub fn compose(out: *DrawList, host: *const DrawList, guest: *const DrawList, region_id: u32, strings: []u8) error{ NoRegion, NoRoom }!void {
    const at = for (0..host.cmd_len) |k| {
        const cmd = host.command(@intCast(k));
        if (cmd == .custom and host.customs[cmd.custom].id == region_id) break k;
    } else return error.NoRegion;
    const slot = host.customs[host.cmd.first[at]];
    const cmds = host.cmd_len - 1 + guest.cmd_len;
    const string_bytes = host.strings.len + guest.strings.len;
    if (host.quad_len + guest.quad_len > out.quads.len or host.run_len + guest.run_len > out.runs.len or
        host.custom_len + guest.custom_len > out.customs.len or cmds > out.cmd.kind.len or string_bytes > strings.len)
        return error.NoRoom;

    const V4 = @Vector(4, f32);
    const o = V4{ slot.rect[0], slot.rect[1], slot.rect[0], slot.rect[1] };
    // The guest is seen through its region: inside the region's rect and the clip it has.
    const window = cut(slot.rect, @splat(0), slot.clip);

    const hq = host.quad_len;
    const hr = host.run_len;
    const hc = host.custom_len;
    @memcpy(out.quads[0..hq], host.quads[0..hq]);
    for (guest.quads[0..guest.quad_len], out.quads[hq..][0..guest.quad_len]) |g, *q| {
        q.* = g;
        q.rect = @as(V4, g.rect) + o;
        q.clip = cut(g.clip, o, window);
        // screen = A p + t; with p moved by the origin, t' = t + o - A o.
        const m = g.xform;
        q.xform[4] = m[4] + o[0] - (m[0] * o[0] + m[2] * o[1]);
        q.xform[5] = m[5] + o[1] - (m[1] * o[0] + m[3] * o[1]);
    }
    @memcpy(out.runs[0..hr], host.runs[0..hr]);
    for (guest.runs[0..guest.run_len], out.runs[hr..][0..guest.run_len]) |g, *r| {
        r.* = g;
        r.rect = @as(V4, g.rect) + o;
        r.clip = cut(g.clip, o, window);
        r.start = g.start + @as(u32, @intCast(host.strings.len));
    }
    @memcpy(out.customs[0..hc], host.customs[0..hc]);
    for (guest.customs[0..guest.custom_len], out.customs[hc..][0..guest.custom_len]) |g, *c| {
        c.* = g;
        c.rect = @as(V4, g.rect) + o;
        c.clip = cut(g.clip, o, window);
    }
    @memcpy(strings[0..host.strings.len], host.strings);
    @memcpy(strings[host.strings.len..string_bytes], guest.strings);

    // Commands: the host's up to the region, the guest's (indices moved past the host's rows),
    // then the rest of the host's.
    const rebase = [3]u32{ hq, hr, hc }; // by `DrawList.Kind`: quads, text, custom
    inline for (.{ "kind", "first", "count", "key" }) |name| {
        const dst = @field(out.cmd, name);
        const src = @field(host.cmd, name);
        @memcpy(dst[0..at], src[0..at]);
        @memcpy(dst[at..][0..guest.cmd_len], @field(guest.cmd, name)[0..guest.cmd_len]);
        @memcpy(dst[at + guest.cmd_len .. cmds], src[at + 1 .. host.cmd_len]);
    }
    for (out.cmd.first[at..][0..guest.cmd_len], guest.cmd.kind[0..guest.cmd_len]) |*first, kind| first.* += rebase[kind];

    out.quad_len = hq + guest.quad_len;
    out.run_len = hr + guest.run_len;
    out.custom_len = hc + guest.custom_len;
    out.cmd_len = cmds;
    out.strings = strings[0..string_bytes];
    out.op_len = 0;
    out.opaque_len = 0;
    out.damage = .everything;
}

// ---- tests -------------------------------------------------------------------------------------

const testing = std.testing;
const s = spec_zig;
const mem = @import("../core/mem.zig");
const types = @import("../core/types.zig");
const Layout = @import("layout.zig").Layout;
const Events = @import("events.zig").Events;
const context = @import("../runtime/context.zig");
const Context = context.Context;
const Frame = @import("../runtime/frame.zig").Frame;

/// A comptime page: a fixed 30 px header over a region that fills the rest.
const page = s.col(.{ .size = .{ .fill, .fill } }, .{
    s.row(.{ .size = .{ .fill, .px(30) }, .fill = .rgb(40, 40, 50) }, .{}),
    region(.list, .{ .size = .{ .fill, .fill } }),
});

const list_limits: context.Limits = .{ .nodes = 16, .texts = 1, .customs = 1, .strings = 16, .anims = 1, .tweens = 1, .flips = 1, .signals = 1, .depth = 4, .timers = 1, .memos = 1 };

/// The runtime side: rows of 20 px a data-driven list builds, one per item.
fn buildList(f: *Frame, items: u32, clicked: *?u32) void {
    for (0..items) |k| {
        const node = f.leaf(.hash(std.mem.asBytes(&k)), .{ .size = .{ .fill, .px(20) } });
        if (f.interact(node, .button).clicked) clicked.* = @intCast(k);
    }
}

test "regionInput: a runtime Frame hosted in a comptime UI's region" {
    const L = Layout(page, .{});
    const list_row = @backingInt(Events(page).Widget.list);
    var scratch: L.Scratch = undefined;
    var ram: L.Cols.Dynamic = undefined;

    const S = struct {
        var buffer: [Context.requiredBytes(list_limits)]u8 align(mem.column_align) = undefined;
    };
    var ctx = try Context.init(&S.buffer, list_limits);

    var outer: Input = .{ .viewport = .{ 400, 300 } };
    var clicked: ?u32 = null;
    // A press, then a release, over item 1 (window y 30 + 25): a click is judged against the
    // last frame's rects, in the region's coordinates.
    for ([_]bool{ false, true, false }) |down| {
        outer.pointer = .{ 10, 55 };
        outer.buttons.left = down;
        L.run(&scratch, &ram, outer.viewport);
        const rect = rectOf(&ram, list_row);
        try testing.expectEqual([4]f32{ 0, 30, 400, 300 }, rect);

        const in = regionInput(&outer, rect);
        var f = ctx.begin(&in);
        buildList(&f, 5, &clicked);
        const out = f.end(.{ .advance = 0.5, .line = 1.2 });
        try testing.expect(out.status.ok());
        // The hosted root is the region's size, and its rows are laid out from (0, 0).
        try testing.expectEqual(types.Rect{ .x0 = 0, .y0 = 0, .x1 = 400, .y1 = 270 }, out.tree.rect(0));
        try testing.expectEqual(types.Rect{ .x0 = 0, .y0 = 20, .x1 = 400, .y1 = 40 }, out.tree.rect(2));
    }
    try testing.expectEqual(@as(?u32, 1), clicked);

    // The header is outside the region: a click on it reaches no item.
    clicked = null;
    for ([_]bool{ true, false }) |down| {
        outer.pointer = .{ 10, 10 };
        outer.buttons.left = down;
        const in = regionInput(&outer, rectOf(&ram, list_row));
        var f = ctx.begin(&in);
        buildList(&f, 5, &clicked);
        _ = f.end(.{ .advance = 0.5, .line = 1.2 });
    }
    try testing.expectEqual(@as(?u32, null), clicked);
}

test "widgetRects: a comptime UI hosted in a runtime Frame's node" {
    // The comptime panel: a checkbox and a slider of fixed size in a padded row.
    const panel = comptime blk: {
        var mute = s.checkbox(.mute, .muted);
        mute.style.size = .{ .px(20), .px(20) };
        var volume = s.slider(.volume, .volume);
        volume.style.size = .{ .px(100), .px(20) };
        break :blk s.row(.{ .pad = @splat(10), .gap = 10 }, .{ mute, volume });
    };
    const L = Layout(panel, .{});
    const E = Events(panel);
    var scratch: L.Scratch = undefined;
    var ram: L.Cols.Dynamic = undefined;
    var pointer: E.Pointer = .{};

    const S = struct {
        var buffer: [Context.requiredBytes(list_limits)]u8 align(mem.column_align) = undefined;
    };
    var ctx = try Context.init(&S.buffer, list_limits);
    const panel_id: types.Id = .from("panel");

    // Window (90, 60) is over the slider: 50 px into its 100, so 0.5. Then a click on the
    // checkbox at (20, 60).
    const script = [_]struct { at: [2]f32, down: bool }{ .{ .at = .{ 90, 60 }, .down = true }, .{ .at = .{ 90, 60 }, .down = false }, .{ .at = .{ 20, 60 }, .down = true }, .{ .at = .{ 20, 60 }, .down = false } };
    var got: [script.len]?E.Event = undefined;
    for (script, &got) |step, *g| {
        const outer: Input = .{ .viewport = .{ 400, 300 }, .pointer = step.at, .buttons = .{ .left = step.down } };
        // The runtime page: a 40 px toolbar, then the panel's node filling the rest.
        var f = ctx.begin(&outer);
        _ = f.leaf(.from("toolbar"), .{ .size = .{ .fill, .px(40) } });
        _ = f.custom(panel_id, .{ .size = .{ .fill, .fill } }, 0);
        const out = f.end(.{ .advance = 0.5, .line = 1.2 });
        const r = out.tree.rect(out.tree.find(panel_id));
        const rect: [4]f32 = .{ r.x0, r.y0, r.x1, r.y1 };
        try testing.expectEqual([4]f32{ 0, 40, 400, 300 }, rect);

        const in = regionInput(&outer, rect);
        L.run(&scratch, &ram, in.viewport);
        const rects = widgetRects(E, &ram);
        try testing.expectEqual([4]f32{ 40, 10, 140, 30 }, [4]f32{ rects.c[0][1], rects.c[1][1], rects.c[2][1], rects.c[3][1] });
        g.* = E.pointer(&pointer, &rects, &in);
    }
    try testing.expectEqual(@as(?E.Event, .{ .volume = 0.5 }), got[0]);
    try testing.expectEqual(@as(?E.Event, null), got[1]);
    try testing.expectEqual(@as(?E.Event, null), got[2]);
    try testing.expectEqual(@as(?E.Event, .mute), got[3]);
}

const tree = @import("../core/tree.zig");
const layout = @import("../layout/layout.zig");
const paint = @import("../draw/paint.zig");
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;

/// Pushes `sp` into `t` row for row, as `Tree.push` numbers a spec (flatten.zig).
fn pushAll(t: *tree.Tree, comptime sp: Spec, parent: u32) void {
    const i = t.push(parent, if (sp.id) |name| .hash(name) else .none, &sp.style);
    inline for (sp.children) |c| pushAll(t, c, i);
    t.seal(i);
}

test "compose: the comptime panel's draw list in the runtime page's, in the region's place" {
    // The comptime side: two coloured widgets. Painted by the tier-0 passes over its rows
    // until the comptime paint (lane ct-paint) gives it a draw list of its own.
    const panel = comptime blk: {
        var mute = s.checkbox(.mute, .muted);
        mute.style.size = .{ .px(20), .px(20) };
        mute.style.fill = .rgb(1, 1, 1);
        var volume = s.slider(.volume, .volume);
        volume.style.size = .{ .px(100), .px(20) };
        volume.style.fill = .rgb(2, 2, 2);
        break :blk s.row(.{ .pad = @splat(10), .gap = 10 }, .{ mute, volume });
    };
    const G = struct {
        var buf: [1 << 16]u8 align(mem.column_align) = undefined;
        var out_buf: [1 << 16]u8 align(mem.column_align) = undefined;
        var buffer: [Context.requiredBytes(list_limits)]u8 align(mem.column_align) = undefined;
    };
    var carver: mem.Carver = .{ .buf = &G.buf };
    var gt = tree.Tree.init(&carver, 3);
    var gtx = Texts.init(&carver, 1);
    const gcu = Customs.init(&carver, 1);
    var gd = DrawList.init(&carver, 3, 1, 1);

    // The runtime side: a toolbar, the panel's region, and a status bar painted after it.
    var ctx = try Context.init(&G.buffer, list_limits);
    const outer: Input = .{ .viewport = .{ 400, 300 } };
    var f = ctx.begin(&outer);
    _ = f.leaf(.from("toolbar"), .{ .size = .{ .fill, .px(40) }, .fill = .rgb(3, 3, 3) });
    const panel_id: types.Id = .from("panel");
    _ = f.custom(panel_id, .{ .size = .{ .fill, .fill } }, 0);
    _ = f.leaf(.from("status"), .{ .size = .{ .fill, .px(20) }, .fill = .rgb(4, 4, 4) });
    const host = f.end(.{ .advance = 0.5, .line = 1.2 }).draw;
    try testing.expectEqual(3, host.cmd_len); // toolbar, the region, status

    const r = host.customs[0].rect;
    pushAll(&gt, panel, 0);
    layout.run(&gt, &gtx, .{ r[2] - r[0], r[3] - r[1] });
    paint.emit(&gt, &gtx, &gcu, "", &gd);
    try testing.expectEqual(2, gd.quad_len);

    var out_carver: mem.Carver = .{ .buf = &G.out_buf };
    var out = DrawList.init(&out_carver, 8, 2, 2);
    var strings: [16]u8 = undefined;
    try compose(&out, host, &gd, @backingInt(panel_id), &strings);

    // Toolbar, the panel's batch where the region was, then the status bar over both.
    try testing.expectEqual(3, out.cmd_len);
    try testing.expectEqual(draw_list.Cmd{ .quads = .{ .first = 0, .count = 1, .texture = .white, .material = .solid } }, out.command(0));
    try testing.expectEqual(draw_list.Cmd{ .quads = .{ .first = 2, .count = 2, .texture = .white, .material = .solid } }, out.command(1));
    try testing.expectEqual(draw_list.Cmd{ .quads = .{ .first = 1, .count = 1, .texture = .white, .material = .solid } }, out.command(2));
    // The panel's quads moved by the region's origin (0, 40) and clipped to the region.
    try testing.expectEqual([4]f32{ 10, 50, 30, 70 }, out.quads[2].rect);
    try testing.expectEqual([4]f32{ 40, 50, 140, 70 }, out.quads[3].rect);
    try testing.expectEqual(r, out.quads[2].clip);
    try testing.expectEqual([6]f32{ 1, 0, 0, 1, 0, 0 }, out.quads[3].xform);
    try testing.expectEqual(gd.quads[0].fill, out.quads[2].fill);

    try testing.expectError(error.NoRegion, compose(&out, host, &gd, @backingInt(types.Id.from("nope")), &strings));
    var small = DrawList.init(&out_carver, 2, 1, 1);
    try testing.expectError(error.NoRoom, compose(&small, host, &gd, @backingInt(panel_id), &strings));
}
