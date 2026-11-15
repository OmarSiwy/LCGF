//! Events: the comptime front end's input side. Interactive widgets (spec nodes with an id)
//! become a generated `Widget` enum, so handling them is an exhaustive switch. Tier 1. Ported
//! from prototype/comptime_ui_probe.zig (`Ui().Widget` via `@Enum`).

const std = @import("std");
const spec_zig = @import("spec.zig");
const Spec = spec_zig.Spec;
const Kind = spec_zig.Kind;
const flatten = @import("flatten.zig");
const simd = @import("../core/simd.zig");
const none = @import("../core/types.zig").none;
const Input = @import("../core/input.zig").Input;

const W = simd.lanes;

/// The interactive widgets of `spec` and how input reaches them.
pub fn Events(comptime spec: Spec) type {
    const F = flatten.Flat(spec);
    const count = blk: {
        @setEvalBranchQuota(1000 + 8 * F.node_count);
        break :blk widgetCount(spec);
    };
    return struct {
        pub const Index = F.Index;
        /// Widgets: spec nodes with an id.
        pub const widget_count = count;

        const Ids = struct { names: [count][:0]const u8, nodes: [count]Index, kinds: [count]Kind };
        const ids: Ids = blk: {
            @setEvalBranchQuota(1000 + 8 * F.node_count);
            var out: Ids = undefined;
            var row: usize = 0;
            var k: usize = 0;
            idsWalk(spec, &row, &k, &out);
            break :blk out;
        };

        fn idsWalk(comptime node: Spec, comptime row: *usize, comptime k: *usize, comptime out: *Ids) void {
            if (node.id) |name| {
                out.names[k.*] = name;
                out.nodes[k.*] = row.*;
                out.kinds[k.*] = node.kind;
                k.* += 1;
            }
            row.* += 1;
            for (node.children) |c| idsWalk(c, row, k, out);
        }

        /// One tag per widget, in row order; a tag's value is its node's row, as in the probe
        /// (`@backingInt(Widget.volume) == 4`). A duplicate id is a compile error. Without
        /// widgets it is an empty enum.
        pub const Widget = if (count == 0) enum {} else @Enum(Index, .exhaustive, &ids.names, &ids.nodes);

        /// Row of each widget, in widget order (the order of `Widget`'s tags).
        pub const widget_nodes: [count]Index = ids.nodes;
        /// Kind of each widget, in widget order.
        pub const widget_kinds: [count]Kind = ids.kinds;

        /// The widget's position in widget order: its index into the per-widget tables.
        pub fn slot(comptime w: Widget) usize {
            return comptime std.mem.indexOfScalar(Index, &widget_nodes, @backingInt(w)).?;
        }

        /// The widget at position `k` of widget order.
        pub fn widget(k: usize) Widget {
            return @fromBackingInt(widget_nodes[k]);
        }

        /// Rows of the rect table: one per widget, padded to whole vectors.
        pub const rect_rows = simd.padded(count);

        /// Where each widget is on screen, in widget order: the static rect table. Exact size,
        /// so there is no capacity to configure. The host or a layout pass fills it each time
        /// layout changes; padding rows stay empty (x0 == x1), so nothing hits them.
        pub const Rects = struct {
            /// x0, y0, x1, y1 columns, in logical pixels, clipped as `Tree.Columns.vis`.
            c: [4][rect_rows]f32 = @splat(@splat(0)),

            /// The widgets' rows of a laid-out tree's `vis` columns (a tree built from this
            /// spec, so row numbers agree).
            pub fn fromTree(t: anytype) Rects {
                var r: Rects = .{};
                for (0..4) |side| {
                    for (widget_nodes, 0..) |node, k| r.c[side][k] = t.c.vis[side][node];
                }
                return r;
            }
        };

        /// Topmost widget under (x, y), or null. As `hit.at`: `lanes` rects per step, no early
        /// exit, half-open edges, and the latest row wins where widgets overlap.
        pub fn at(r: *const Rects, x: f32, y: f32) ?Widget {
            const px = simd.f(x);
            const py = simd.f(y);
            var found: u32 = none;
            var i: usize = 0;
            while (i < rect_rows) : (i += W) {
                const inside = (px >= simd.loadF(&r.c[0], i)) & (px < simd.loadF(&r.c[2], i)) &
                    (py >= simd.loadF(&r.c[1], i)) & (py < simd.loadF(&r.c[3], i));
                const m = simd.bits(inside);
                // Highest set lane. Wraps when m == 0, and is then discarded.
                const top = @as(u32, W - 1) -% @as(u32, @clz(m));
                found = simd.selU(m != 0, @as(u32, @intCast(i)) +% top, found);
            }
            if (comptime count == 0) return null;
            if (found == none) return null;
            return widget(found);
        }

        /// What an event on a widget of `kind` carries: a slider its new value, 0 at the left
        /// edge to 1 at the right; a checkbox nothing (it was toggled); any other widget
        /// nothing (it was clicked).
        pub fn Payload(comptime kind: Kind) type {
            return switch (kind) {
                .slider => f32,
                .checkbox, .label, .col, .row => void,
            };
        }

        /// One input event on one widget, tagged by the widget, so handling events is an
        /// exhaustive switch whose payload type follows the widget's kind:
        /// `switch (e) { .mute => ..., .volume => |v| ..., .pan => |v| ... }`.
        pub const Event = if (count == 0) union {} else blk: {
            var types_: [count]type = undefined;
            for (&types_, widget_kinds) |*T, kind| T.* = Payload(kind);
            break :blk @Union(.auto, Widget, &ids.names, &types_, &@splat(.{}));
        };

        /// Whether keyboard focus stops at a widget of `kind`: the ones that take input.
        pub fn focusable(comptime kind: Kind) bool {
            return switch (kind) {
                .checkbox, .slider => true,
                .label, .col, .row => false,
            };
        }

        /// The keyboard focus order, computed while compiling: the focusable widgets in row
        /// order, which is reading order (depth-first, children in declaration order).
        pub const focus_order: []const Widget = &focus_table;
        const focus_table = blk: {
            var k: usize = 0;
            for (widget_kinds) |kind| k += @intFromBool(focusable(kind));
            var out: [k]Widget = undefined;
            k = 0;
            for (widget_kinds, 0..) |kind, w| if (focusable(kind)) {
                out[k] = widget(w);
                k += 1;
            };
            break :blk out;
        };
        /// Position of each widget in `focus_order`, by widget order; `none` when not
        /// focusable. With `focus_order`, Tab is two table reads.
        const focus_pos: [count]u32 = blk: {
            var out: [count]u32 = @splat(none);
            for (focus_table, 0..) |w, k| out[slotOf(w)] = k;
            break :blk out;
        };
        fn slotOf(w: Widget) usize {
            return std.mem.indexOfScalar(Index, &widget_nodes, @backingInt(w)).?;
        }

        /// The widget Tab (`back` false) or Shift+Tab (`back` true) moves focus to from
        /// `from`, wrapping at the ends. From no focus, or from a widget that is not
        /// focusable, Tab goes to the first and Shift+Tab to the last. Null when nothing is
        /// focusable.
        pub fn nextFocus(from: ?Widget, back: bool) ?Widget {
            const len: u32 = focus_table.len;
            if (len == 0) return null;
            const at_ = if (from) |w| focus_pos[slotOf(w)] else none;
            const k = if (at_ == none)
                (if (back) len - 1 else 0)
            else if (back) (at_ + len - 1) % len else (at_ + 1) % len;
            return focus_table[k];
        }

        /// Moves `focus` for every Tab press (and auto-repeat) in this frame's key events, in
        /// order; Shift goes back. `tab` is the platform's scancode for Tab, as in `Input.Keys`.
        pub fn focusKeys(focus: *?Widget, in: *const Input, tab: u8) void {
            for (in.events) |e| {
                if (e.code != tab or (e.kind != .press and e.kind != .repeat)) continue;
                focus.* = nextFocus(focus.*, e.mods.shift);
            }
        }

        /// Pointer state across frames. The caller owns it and passes it to every `pointer`.
        pub const Pointer = struct {
            /// The widget the left button went down on, while it is held.
            pressed: ?Widget = null,
            /// The left button was down last frame.
            down: bool = false,
        };

        /// The event this frame's mouse makes, or null. A slider reports its value on press and
        /// every frame it stays pressed (a drag, clamped to the slider's ends, even outside
        /// it); any other widget reports a click when the button goes up over the widget it
        /// went down on.
        pub fn pointer(p: *Pointer, r: *const Rects, in: *const Input) ?Event {
            if (comptime count == 0) return null;
            const down = in.buttons.left;
            defer p.down = down;
            const x = in.pointer[0];
            const y = in.pointer[1];
            if (down and !p.down) p.pressed = at(r, x, y);
            const w = p.pressed orelse return null;
            if (!down) p.pressed = null;
            switch (w) {
                inline else => |tag| {
                    const k = comptime slot(tag);
                    if (comptime widget_kinds[k] == .slider) {
                        if (!down) return null;
                        const x0 = r.c[0][k];
                        const span = r.c[2][k] - x0;
                        const v = std.math.clamp((x - x0) / @max(span, std.math.floatMin(f32)), 0, 1);
                        return @unionInit(Event, @tagName(tag), v);
                    }
                    if (down or at(r, x, y) != tag) return null;
                    return @unionInit(Event, @tagName(tag), {});
                },
            }
        }
    };
}

/// Spec nodes in `node`'s subtree with an id.
fn widgetCount(comptime node: Spec) comptime_int {
    var k: comptime_int = @intFromBool(node.id != null);
    for (node.children) |c| k += widgetCount(c);
    return k;
}

// ---- tests -------------------------------------------------------------------------------------

const testing = std.testing;
const s = spec_zig;

/// The probe's usage spec.
const mixer = s.col(.{ .pad = @splat(8), .gap = 4 }, .{
    s.label(.title),
    s.row(.{ .gap = 8 }, .{ s.checkbox(.mute, .muted), s.slider(.volume, .volume) }),
    s.row(.{ .gap = 8 }, .{ s.label(.title), s.slider(.pan, .pan) }),
});
const App = Events(mixer);

test "Widget: one tag per id, valued by its node's row" {
    try testing.expectEqual(3, App.widget_count);
    try testing.expectEqual(u4, @typeInfo(App.Widget).@"enum".tag_type);
    try testing.expectEqual(3, @backingInt(App.Widget.mute));
    try testing.expectEqual(4, @backingInt(App.Widget.volume));
    try testing.expectEqual(7, @backingInt(App.Widget.pan));
    try testing.expectEqualSlices(u4, &.{ 3, 4, 7 }, &App.widget_nodes);
    try testing.expectEqualSlices(Kind, &.{ .checkbox, .slider, .slider }, &App.widget_kinds);
    try testing.expectEqual(1, App.slot(.volume));
    try testing.expectEqual(App.Widget.pan, App.widget(2));
    try testing.expectEqual(0, Events(s.label(.x)).widget_count);
}

/// The probe's exhaustive-switch example: what a click on each widget does.
fn onClick(w: App.Widget, muted: *bool, touched: *u32) void {
    switch (w) { // forgetting a widget here is a compile error
        .mute => muted.* = !muted.*,
        .volume, .pan => touched.* += 1,
    }
}

test "Widget: event handling is an exhaustive switch" {
    var muted = false;
    var touched: u32 = 0;
    onClick(.mute, &muted, &touched);
    onClick(.volume, &muted, &touched);
    onClick(App.widget(2), &muted, &touched);
    try testing.expect(muted);
    try testing.expectEqual(2, touched);
}

/// One root over `n` sliders, each with an id: a large widget enum.
fn manySliders(comptime n: comptime_int) Spec {
    @setEvalBranchQuota(2000 * n); // comptimePrint's format parsing
    var leaves: [n]Spec = undefined;
    for (&leaves, 0..) |*l, k| l.* = .{ .kind = .slider, .id = std.fmt.comptimePrint("s{d}", .{k}), .bind = "x" };
    return s.row(.{}, leaves);
}
const many = manySliders(2000);

test "Widget: large specs need no quota from the caller" {
    const M = Events(many);
    try testing.expectEqual(2000, M.widget_count);
    try testing.expectEqual(2000, @backingInt(@field(M.Widget, "s1999")));
}

const Tree = @import("../core/tree.zig").Tree;
const mem = @import("../core/mem.zig");
const types = @import("../core/types.zig");

/// The mixer with fixed sizes, so it lays out without text: root 200 x 100 at the origin, pad
/// 8, gap 4; the checkbox and volume slider in a row at y 8..28, the pan slider below at y
/// 32..52.
const sized = Spec{ .kind = .col, .style = .{ .size = .{ .px(200), .px(100) }, .pad = @splat(8), .gap = 4 }, .children = &.{
    .{ .kind = .row, .style = .{ .dir = .x, .gap = 8 }, .children = &.{
        .{ .kind = .checkbox, .id = "mute", .bind = "muted", .style = .{ .size = .{ .px(20), .px(20) } } },
        .{ .kind = .slider, .id = "volume", .bind = "volume", .style = .{ .size = .{ .px(100), .px(20) } } },
    } },
    .{ .kind = .row, .style = .{ .dir = .x }, .children = &.{
        .{ .kind = .slider, .id = "pan", .bind = "pan", .style = .{ .size = .{ .px(100), .px(20) } } },
    } },
} };
const Sized = Events(sized);

/// `spec`'s tree, pushed and laid out by the runtime front end at `viewport`.
fn laidOut(comptime sp: Spec, raw: []align(mem.column_align) u8, viewport: [2]f32) Tree {
    const layout = @import("../layout/layout.zig");
    const Texts = @import("../core/texts.zig").Texts;
    var carver: mem.Carver = .{ .buf = raw };
    var t = Tree.init(&carver, flatten.count(sp));
    var tx = Texts.init(&carver, 1);
    push(&t, &sp, 0);
    layout.run(&t, &tx, viewport);
    return t;
}
fn push(t: *Tree, n: *const Spec, parent: u32) void {
    const i = t.push(parent, if (n.id) |name| .hash(name) else .none, &n.style);
    for (n.children) |*c| push(t, c, i);
    t.seal(i);
}

test "at: the widget under the point, from the laid-out tree's rects" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    const t = laidOut(sized, &raw, .{ 200, 100 });
    const r = Sized.Rects.fromTree(&t);
    try testing.expectEqual([4]f32{ 8, 8, 28, 28 }, [4]f32{ r.c[0][0], r.c[1][0], r.c[2][0], r.c[3][0] });
    try testing.expectEqual(Sized.Widget.mute, Sized.at(&r, 10, 10).?);
    try testing.expectEqual(Sized.Widget.volume, Sized.at(&r, 36, 27).?);
    try testing.expectEqual(Sized.Widget.pan, Sized.at(&r, 8, 32).?);
    // The gap between checkbox and slider, the root's padding, and half-open edges.
    try testing.expectEqual(null, Sized.at(&r, 30, 10));
    try testing.expectEqual(null, Sized.at(&r, 4, 4));
    try testing.expectEqual(null, Sized.at(&r, 28, 10));
    try testing.expectEqual(null, Sized.at(&r, 108, 40));
    // The comptime sweep agrees with hit.at over the tree, where every widget senses.
    const hit = @import("../interact/hit.zig");
    var tt = t;
    for (Sized.widget_nodes) |node| tt.c.sense[node] = @bitCast(types.Sense.button);
    var y: f32 = -2;
    while (y < 102) : (y += 1.5) {
        var x: f32 = -2;
        while (x < 202) : (x += 1.5) {
            const want = hit.at(&tt, x, y, .any);
            const got = Sized.at(&r, x, y);
            try testing.expectEqual(want, if (got) |w| @as(u32, @backingInt(w)) else none);
        }
    }
}

test "at: overlapping rects, the latest widget wins; matches a scalar sweep" {
    const M = Events(many);
    var r: M.Rects = .{};
    var seed: u32 = 99;
    for (0..M.widget_count) |k| {
        seed = seed *% 1103515245 +% 12345;
        const x: f32 = @floatFromInt((seed >> 8) % 500);
        const y: f32 = @floatFromInt((seed >> 20) % 500);
        r.c[0][k] = x;
        r.c[1][k] = y;
        r.c[2][k] = x + 30;
        r.c[3][k] = y + 30;
    }
    var hits: u32 = 0;
    var y: f32 = 0;
    while (y < 530) : (y += 7.5) {
        var x: f32 = 0;
        while (x < 530) : (x += 7.5) {
            var want: ?M.Widget = null;
            for (0..M.widget_count) |k| {
                if (x >= r.c[0][k] and x < r.c[2][k] and y >= r.c[1][k] and y < r.c[3][k]) want = M.widget(k);
            }
            try testing.expectEqual(want, M.at(&r, x, y));
            hits += @intFromBool(want != null);
        }
    }
    try testing.expect(hits > 1000);
    // An empty table hits nothing, and a spec without widgets has no rows to sweep.
    try testing.expectEqual(null, M.at(&.{}, 10, 10));
    try testing.expectEqual(0, Events(s.label(.x)).rect_rows);
    try testing.expectEqual(null, Events(s.label(.x)).at(&.{}, 0, 0));
}

/// The sized mixer's rects, laid out.
fn sizedRects() Sized.Rects {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    const t = laidOut(sized, &raw, .{ 200, 100 });
    return Sized.Rects.fromTree(&t);
}

/// One frame of mouse input: the pointer at (x, y), the left button held or not.
fn mouse(x: f32, y: f32, left: bool) Input {
    return .{ .pointer = .{ x, y }, .buttons = .{ .left = left } };
}

test "Event: a tagged union over widgets, payload by kind" {
    try testing.expectEqual(Sized.Widget, @typeInfo(Sized.Event).@"union".tag_type.?);
    try testing.expectEqual(void, @FieldType(Sized.Event, "mute"));
    try testing.expectEqual(f32, @FieldType(Sized.Event, "volume"));
    try testing.expectEqual(f32, @FieldType(Sized.Event, "pan"));
}

test "pointer: a click toggles a checkbox, a press and drag set a slider" {
    const r = sizedRects();
    var p: Sized.Pointer = .{};
    var muted = false;
    var volume: f32 = 0.5;
    var pan: f32 = 0.5;
    // The volume slider is x 36..136; the checkbox 8..28; both y 8..28.
    const frames = [_]Input{
        mouse(10, 10, false), mouse(10, 10, true), mouse(12, 12, true), mouse(12, 12, false), // click mute
        mouse(61, 20, true), mouse(111, 20, true), mouse(500, 90, true), mouse(500, 90, false), // drag volume
        mouse(10, 10, true), mouse(100, 90, false), // press mute, release elsewhere: no click
        mouse(100, 90, true), mouse(10, 10, false), // press nothing, release on mute: no click
    };
    var events: u32 = 0;
    var volumes: [3]f32 = undefined;
    for (frames) |in| {
        const e = Sized.pointer(&p, &r, &in) orelse continue;
        switch (e) { // forgetting a widget here is a compile error
            .mute => muted = !muted,
            .volume => |v| {
                volumes[events - 1] = v;
                volume = v;
            },
            .pan => |v| pan = v,
        }
        events += 1;
    }
    try testing.expectEqual(4, events);
    try testing.expect(muted);
    try testing.expectEqualSlices(f32, &.{ 0.25, 0.75, 1 }, &volumes);
    try testing.expectEqual(1, volume);
    try testing.expectEqual(0.5, pan);
    try testing.expectEqual(null, p.pressed);
}

test "focus_order: the focusable widgets in reading order, computed at compile time" {
    try testing.expectEqualSlices(App.Widget, &.{ .mute, .volume, .pan }, App.focus_order);
    // A clickable label with an id is a widget but takes no focus.
    const L = Events(s.row(.{}, .{ s.slider(.b, .b), Spec{ .kind = .label, .id = "caption", .bind = "t" }, s.checkbox(.a, .a) }));
    try testing.expectEqualSlices(L.Widget, &.{ .b, .a }, L.focus_order);
    comptime {
        if (App.focus_order.len != 3) unreachable; // a comptime-known table
    }
    try testing.expectEqual(null, Events(s.label(.x)).nextFocus(null, false));
    try testing.expectEqual(L.Widget.b, L.nextFocus(.caption, false));
    try testing.expectEqual(L.Widget.a, L.nextFocus(.caption, true));
}

test "nextFocus, focusKeys: Tab walks the order and wraps, Shift+Tab walks back" {
    try testing.expectEqual(App.Widget.mute, App.nextFocus(null, false));
    try testing.expectEqual(App.Widget.pan, App.nextFocus(null, true));
    try testing.expectEqual(App.Widget.volume, App.nextFocus(.mute, false));
    try testing.expectEqual(App.Widget.mute, App.nextFocus(.pan, false));
    try testing.expectEqual(App.Widget.pan, App.nextFocus(.mute, true));
    const tab = 15;
    const events = [_]Input.Event{
        .{ .kind = .press, .code = tab }, // mute
        .{ .kind = .release, .code = tab },
        .{ .kind = .press, .code = 30 }, // another key
        .{ .kind = .press, .code = tab }, // volume
        .{ .kind = .repeat, .code = tab }, // pan
        .{ .kind = .press, .code = tab, .mods = .{ .shift = true } }, // volume
    };
    var focus: ?App.Widget = null;
    App.focusKeys(&focus, &.{ .events = &events }, tab);
    try testing.expectEqual(App.Widget.volume, focus.?);
    switch (focus.?) { // the focused widget, handled exhaustively
        .mute, .pan => return error.TestUnexpectedResult,
        .volume => {},
    }
}
