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

const std = @import("std");
const Input = @import("../core/input.zig").Input;
const spec_zig = @import("spec.zig");
const Spec = spec_zig.Spec;
const Style = @import("../core/types.zig").Style;

/// A region: an empty column named `id` whose content another front end builds. Its rect comes
/// from the comptime layout like any node's; `id` makes it a tag of `Events(spec).Widget`, whose
/// value is its row.
pub fn region(comptime id: @EnumLiteral(), comptime style: Style) Spec {
    var out = spec_zig.col(style, .{});
    out.id = @tagName(id);
    return out;
}

/// Row `row`'s rect (x0, y0, x1, y1) in a comptime layout's RAM (`Columns.Dynamic`), as f32
/// whatever the coordinate type.
pub fn rectOf(ram: anytype, row: usize) [4]f32 {
    var r: [4]f32 = undefined;
    inline for (&r, 0..) |*x, k| x.* = toF32(ram.rect[k][row]);
    return r;
}

/// The widget rect table `Events(spec).Rects` from a comptime layout's RAM: each widget's
/// visible rect (`vis`), in the layout's own coordinates, as `Rects.fromTree` takes it from a
/// runtime tree. Judge the pointer against it through `regionInput`.
pub fn widgetRects(comptime E: type, ram: anytype) E.Rects {
    var r: E.Rects = .{};
    for (0..4) |side| {
        for (E.widget_nodes, 0..) |node, k| r.c[side][k] = toF32(ram.vis[side][node]);
    }
    return r;
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
