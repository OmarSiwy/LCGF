//! Colour picker (tier 2): a saturation and value area dragged in two dimensions, a hue slider
//! and an opacity slider, in both front ends. Follows the five-commit recipe of
//! widgets/base.zig and is written against the public API of tiers 0 and 1 only.
//!
//! State lives in the application: the colour as an `Hsva` value (hue, saturation, value,
//! opacity, each 0 to 1). The area and the slider tracks are painted with the stock material's
//! linear gradients (`draw/features.zig`), so the picker is quads only: no texture, no custom
//! draw. Each part works like `base.slider` (the value follows the pointer while held) and, while
//! focused, answers the arrow keys, Home and End as an APG slider.

const std = @import("std");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Input = @import("../core/input.zig").Input;
const DrawList = @import("../draw/draw_list.zig").DrawList;
const Mono = @import("../text/protocol.zig").Mono;
const features = @import("../draw/features.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const events = @import("../comptime/events.zig");
const signals = @import("../comptime/signals.zig");
const flatten = @import("../comptime/flatten.zig");
const a11y = @import("../a11y/tree.zig");
const base = @import("base.zig");
const list_zig = @import("list.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Node = types.Node;
const Color = types.Color;
const Style = types.Style;
const Response = types.Response;
const Rect = types.Rect;
const none = types.none;

// ---- spec ------------------------------------------------------------------------------------

/// A colour as the picker keeps it: hue, saturation, value and opacity, each 0 to 1. Kept in
/// HSV rather than RGB so a grey keeps its hue while it is dragged through.
pub const Hsva = struct {
    h: f32 = 0,
    s: f32 = 1,
    v: f32 = 1,
    a: f32 = 1,

    /// The colour in 8-bit RGBA (standard HSV to RGB, sector by sector).
    pub fn rgba(c: Hsva) Color {
        const h6 = base.unit(c.h) * 6;
        const s = base.unit(c.s);
        const v = base.unit(c.v);
        const k = [3]f32{ 5, 3, 1 };
        var rgb: [3]u8 = undefined;
        for (&rgb, k) |*o, n| {
            const t = @mod(n + h6, 6);
            const x = v - v * s * @max(0, @min(@min(t, 4 - t), 1));
            o.* = @intFromFloat(@round(x * 255));
        }
        return .rgba(rgb[0], rgb[1], rgb[2], @intFromFloat(@round(base.unit(c.a) * 255)));
    }
};

/// Why `State` cannot back a comptime colour picker bound to the field `color`; null when it
/// can.
pub fn check(comptime State: type, comptime color: []const u8) ?[]const u8 {
    comptime {
        if (!@hasField(State, color)) return "colorpicker: state has no field '" ++ color ++ "' for the colour";
        if (@FieldType(State, color) != Hsva) return "colorpicker: field '" ++ color ++ "' must be a colorpicker.Hsva";
        return null;
    }
}

/// `check` as a compile error.
pub fn validate(comptime State: type, comptime color: []const u8) void {
    if (comptime check(State, color)) |msg| @compileError(msg);
}

/// The picker's parts, each a widget: the area, the hue slider, the opacity slider.
pub const Part = enum(u32) { area = 1, hue = 2, alpha = 3 };

/// The hue slider's colour stops, red round to red.
const hue_stops = 6;

/// A part's id, derived from the picker's id the same way in both front ends.
pub fn partId(id: Id, part: Part) Id {
    return id.with(@backingInt(part));
}

// ---- look: one function per part, called by both front ends -------------------------------

/// Size of the saturation and value area; the sliders are as wide.
pub const area_size = [2]f32{ 160, 120 };
/// Height of a slider track.
pub const track_px: f32 = 12;

pub fn pickerStyle(th: *const Theme) Style {
    return .{ .dir = .y, .gap = th.gap, .role = .group };
}

/// The area: its fill is the pure hue; two gradient layers on it whiten to the left and darken
/// to the bottom.
pub fn areaStyle(th: *const Theme, c: Hsva) Style {
    _ = th;
    return .{ .size = .{ .px(area_size[0]), .px(area_size[1]) }, .clip = true, .fill = (Hsva{ .h = c.h }).rgba(), .role = .slider };
}

/// The area's layers: white to clear from the left, then clear to black from the top.
pub fn areaLayer(dark: bool) Style {
    const white = Color.rgba(255, 255, 255, 255);
    // A gradient starts at the fill, and paint skips a quad whose fill and border are both
    // clear, so a layer fading in starts one step above clear.
    const fills = [2]Color{ white, .rgba(0, 0, 0, 1) };
    const tos = [2]Color{ .rgba(255, 255, 255, 0), .black };
    const angles = [2]f32{ 0, std.math.pi / 2.0 };
    const k = @intFromBool(dark);
    return .{ .size = .{ .px(area_size[0]), .px(area_size[1]) }, .float = true, .fill = fills[k], .params = features.linear(tos[k], angles[k]) };
}

/// The ring marking saturation (across) and value (up) in the area.
pub fn areaMarker(c: Hsva) Style {
    const x = base.unit(c.s) * area_size[0];
    const y = (1 - base.unit(c.v)) * area_size[1];
    return .{ .size = .{ .px(12), .px(12) }, .float = true, .offset = .{ x - 6, y - 6 }, .radius = 6, .border = 2, .border_color = .white };
}

/// A slider track as wide as the area.
pub fn trackStyle(th: *const Theme) Style {
    _ = th;
    return .{ .dir = .x, .size = .{ .px(area_size[0]), .px(track_px) }, .role = .slider };
}

/// Hue segment `k` of the hue track: a gradient from one stop to the next.
pub fn hueSegment(k: u32) Style {
    const at = @as(f32, @floatFromInt(k)) / hue_stops;
    const next = @as(f32, @floatFromInt(k + 1)) / hue_stops;
    return .{ .size = .{ .grow(1), .fill }, .fill = (Hsva{ .h = at }).rgba(), .params = features.linear((Hsva{ .h = @mod(next, 1) }).rgba(), 0) };
}

/// The opacity track: the colour from clear to opaque.
pub fn alphaFill(c: Hsva) Style {
    var solid = c;
    solid.a = 1;
    // One step above clear, as `areaLayer`: paint skips a quad whose colours are all clear.
    var clear = solid.rgba();
    clear.a = 1;
    return .{ .size = .{ .px(area_size[0]), .px(track_px) }, .float = true, .fill = clear, .params = features.linear(solid.rgba(), 0) };
}

/// A slider's thumb at `frac` of the track: a white bar a little taller than the track.
pub fn thumbStyle(frac: f32) Style {
    return .{ .size = .{ .px(4), .px(track_px + 4) }, .float = true, .offset = .{ base.unit(frac) * area_size[0] - 2, -2 }, .fill = .white, .border = 1, .border_color = .black };
}

// ---- behaviour: pure functions of the value and what happened -------------------------------

/// Step of an arrow key, as a fraction of a part's range.
pub const key_step: f32 = 0.01;

/// While the area is held, saturation and value follow the pointer inside `rect`: across is
/// saturation, up is value (both clamped).
pub fn dragArea(c: Hsva, held: bool, rect: Rect, x: f32, y: f32) Hsva {
    if (!held) return c;
    var out = c;
    out.s = base.unit((x - rect.x0) / @max(rect.w(), 1));
    out.v = 1 - base.unit((y - rect.y0) / @max(rect.h(), 1));
    return out;
}

/// A slider's value after this frame's keys (press and repeat): Right and Up add a step, Left
/// and Down take one, Home and End go to the ends (APG slider).
pub fn sliderKeys(value: f32, in: *const Input) f32 {
    const km = &list_zig.default_keys;
    var v = value;
    for (in.events) |e| {
        if (e.kind != .press and e.kind != .repeat) continue;
        if (e.code == km.right or e.code == km.up) v += key_step;
        if (e.code == km.left or e.code == km.down) v -= key_step;
        if (e.code == km.home) v = 0;
        if (e.code == km.end) v = 1;
    }
    return base.unit(v);
}

/// One frame of input for a picker: each part follows the pointer while held (the area in two
/// dimensions, the sliders across, as `base.slide`), and the focused part answers keys (the
/// area: Left and Right move saturation, Up and Down value). `r` and `rects` are the parts'
/// responses and last rects, in `Part` order.
pub fn update(c: Hsva, r: [3]Response, rects: [3]Rect, in: *const Input) Hsva {
    const x = in.pointer[0];
    var out = dragArea(c, r[0].held, rects[0], x, in.pointer[1]);
    out.h = base.slide(out.h, r[1].held, (x - rects[1].x0) / @max(rects[1].w(), 1), 0, 1);
    out.a = base.slide(out.a, r[2].held, (x - rects[2].x0) / @max(rects[2].w(), 1), 0, 1);
    if (r[0].focused) {
        const km = &list_zig.default_keys;
        for (in.events) |e| {
            if (e.kind != .press and e.kind != .repeat) continue;
            if (e.code == km.right) out.s = base.unit(out.s + key_step);
            if (e.code == km.left) out.s = base.unit(out.s - key_step);
            if (e.code == km.up) out.v = base.unit(out.v + key_step);
            if (e.code == km.down) out.v = base.unit(out.v - key_step);
        }
    }
    if (r[1].focused) out.h = sliderKeys(out.h, in);
    if (r[2].focused) out.a = sliderKeys(out.a, in);
    return out;
}

// ---- accessibility ---------------------------------------------------------------------------

/// The parts' `value` columns: the area its saturation (a 2D slider has one value; its value
/// is reported as saturation, ARIA has no two-axis slider), the hue slider degrees, the opacity
/// slider its fraction. The group's value is the opacity-free colour as 0xRRGGBB.
pub fn values(c: Hsva) [3]f32 {
    return .{ base.unit(c.s), base.unit(c.h) * 360, base.unit(c.a) };
}

pub fn groupValue(c: Hsva) f32 {
    const k = c.rgba();
    return @floatFromInt((@as(u32, k.r) << 16) | (@as(u32, k.g) << 8) | k.b);
}

/// Names the picker after the text of `label` (a caption's row), as `aria-labelledby`.
pub fn setName(s: *a11y.Semantics, group: u32, label: u32) void {
    s.c.labelled_by[group] = label;
}

// ---- runtime front end ----------------------------------------------------------------------

/// A colour picker for `color`. Returns the area's response.
pub fn colorpicker(f: *Frame, th: *const Theme, id: Id, color: *Hsva) Response {
    // Input first: it moves the marker and thumbs the rows below show. Responses come from last
    // frame's interaction; `interact` marks the parts and reports the same responses.
    var r: [3]Response = undefined;
    var rects: [3]Rect = undefined;
    inline for (.{ Part.area, Part.hue, Part.alpha }, 0..) |p, k| {
        r[k] = f.ctx.inter.response(partId(id, p));
        rects[k] = f.lastRect(partId(id, p));
    }
    color.* = update(color.*, r, rects, f.in);
    const c = color.*;
    const vals = values(c);
    var g = pickerStyle(th);
    g.value = groupValue(c);
    _ = f.open(.none, g);
    var a = areaStyle(th, c);
    a.value = vals[0];
    const area = f.open(partId(id, .area), a);
    const ra = f.interact(area, .any);
    _ = f.leaf(.none, areaLayer(false));
    _ = f.leaf(.none, areaLayer(true));
    _ = f.leaf(.none, areaMarker(c));
    f.close();
    var hs = trackStyle(th);
    hs.value = vals[1];
    const hue = f.open(partId(id, .hue), hs);
    _ = f.interact(hue, .any);
    for (0..hue_stops) |k| _ = f.leaf(.none, hueSegment(@intCast(k)));
    _ = f.leaf(.none, thumbStyle(c.h));
    f.close();
    var al = trackStyle(th);
    al.value = vals[2];
    const alpha = f.open(partId(id, .alpha), al);
    _ = f.interact(alpha, .any);
    _ = f.leaf(.none, alphaFill(c));
    _ = f.leaf(.none, thumbStyle(c.a));
    f.close();
    f.close();
    return ra;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A colour picker named `id` for the `Hsva` field `color`. Its three parts are widgets
    /// named `<id>_area`, `<id>_hue` and `<id>_alpha`; the group holding them is bound to the
    /// colour.
    pub fn colorpicker(comptime th: Theme, comptime id: @EnumLiteral(), comptime color: @EnumLiteral()) Spec {
        _ = th;
        const name = @tagName(id);
        const leaf: Spec = .{ .kind = .col };
        var area = spec_zig.row(.{}, .{ leaf, leaf, leaf });
        area.id = name ++ "_area";
        const segs: [hue_stops + 1]Spec = @splat(leaf);
        var hue = spec_zig.row(.{}, segs);
        hue.id = name ++ "_hue";
        var alpha = spec_zig.row(.{}, .{ leaf, leaf });
        alpha.id = name ++ "_alpha";
        var s = spec_zig.col(.{}, .{ area, hue, alpha });
        s.bind = @tagName(color);
        return s;
    }

    /// The name and field a `ct.colorpicker` node was built with.
    pub fn fields(comptime n: Spec) struct { name: []const u8, color: []const u8 } {
        const area = n.children[0].id.?;
        return .{ .name = area[0 .. area.len - "_area".len], .color = n.bind.? };
    }
};

/// Whether spec node `n` is a colour picker made by `ct.colorpicker`: a column bound to a field.
fn isPicker(comptime n: Spec) bool {
    return n.kind == .col and n.bind != null;
}

/// The comptime front end for a page of colour pickers: rows, columns and labels as in
/// `base.ComptimeUi`, every column bound to a field a picker made by `ct.colorpicker`.
pub fn ComptimeColorpicker(comptime State: type, comptime spec: Spec, comptime th: Theme) type {
    const E = events.Events(spec);
    const S = signals.Signals(State, spec);
    const Tables = list_zig.CtFrame(flatten.count(spec) + 1, @max(list_zig.labelCount(spec), 1));
    comptime checkAll(State, spec);
    return struct {
        const Self = @This();
        pub const Events = E;
        pub const Signals = S;

        page: Tables = .{},
        signals: S.Runtime = .{},
        pointer: list_zig.CtPointer(E) = .{},
        font: Mono = .{},

        pub const Output = struct { draw: *const DrawList, tree: *const Tree, event: ?E.Event };

        fn parts(comptime name: []const u8) [3]E.Widget {
            return comptime .{
                std.meta.stringToEnum(E.Widget, name ++ "_area").?,
                std.meta.stringToEnum(E.Widget, name ++ "_hue").?,
                std.meta.stringToEnum(E.Widget, name ++ "_alpha").?,
            };
        }

        fn responses(ui: *const Self, comptime name: []const u8, in: *const Input) [3]Response {
            var r: [3]Response = undefined;
            inline for (parts(name), 0..) |w, k| r[k] = ui.pointer.response(w, in);
            return r;
        }

        pub fn frame(ui: *Self, in: *const Input) Output {
            const event = ui.pointer.step(in);
            inline for (comptime pickersOf(spec)) |n| {
                const v = comptime ct.fields(n);
                var rects: [3]Rect = undefined;
                inline for (parts(v.name), 0..) |w, k| rects[k] = ui.pointer.rectOf(w);
                const c = update(@field(ui.signals.state, v.color), ui.responses(v.name, in), rects, in);
                ui.signals.set(comptime field(v.color), c);
            }

            const tb = ui.page.begin(in);
            var next: u32 = 0;
            ui.push(spec, 0, &next, in);
            const t = ui.page.end(in);
            ui.pointer.store(t);
            return .{ .draw = &tb.d, .tree = t, .event = event };
        }

        fn push(ui: *Self, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            const tb = &ui.page.tables;
            const state = &ui.signals.state;
            next.* += 1;
            if (n.kind == .label) {
                list_zig.pushLabel(tb, parent, &n.style, @field(state, n.bind.?), &th);
                return;
            }
            if (comptime !isPicker(n)) {
                const i = tb.t.push(parent, .none, &n.style);
                inline for (n.children) |c| ui.push(c, i, next, in);
                tb.t.seal(i);
                return;
            }
            // A colour picker (`ct.colorpicker`): rows as `colorpicker` builds them.
            next.* += comptime flatten.count(n) - 1;
            const v = comptime ct.fields(n);
            const id: Id = .hash(v.name);
            const c: Hsva = @field(state, v.color);
            const vals = values(c);
            var g = pickerStyle(&th);
            g.value = groupValue(c);
            const group = tb.t.push(parent, .none, &g);
            var a = areaStyle(&th, c);
            a.value = vals[0];
            const area = tb.t.push(group, partId(id, .area), &a);
            _ = tb.t.push(area, .none, &areaLayer(false));
            _ = tb.t.push(area, .none, &areaLayer(true));
            _ = tb.t.push(area, .none, &areaMarker(c));
            tb.t.seal(area);
            var hs = trackStyle(&th);
            hs.value = vals[1];
            const hue = tb.t.push(group, partId(id, .hue), &hs);
            for (0..hue_stops) |k| _ = tb.t.push(hue, .none, &hueSegment(@intCast(k)));
            _ = tb.t.push(hue, .none, &thumbStyle(c.h));
            tb.t.seal(hue);
            var al = trackStyle(&th);
            al.value = vals[2];
            const alpha = tb.t.push(group, partId(id, .alpha), &al);
            _ = tb.t.push(alpha, .none, &alphaFill(c));
            _ = tb.t.push(alpha, .none, &thumbStyle(c.a));
            tb.t.seal(alpha);
            tb.t.seal(group);
        }

        fn field(comptime name: []const u8) S.Field {
            return comptime std.meta.stringToEnum(S.Field, name).?;
        }
    };
}

/// The picker nodes of `n`'s subtree.
fn pickersOf(comptime n: Spec) []const Spec {
    if (isPicker(n)) return &.{n};
    var out: []const Spec = &.{};
    for (n.children) |c| out = out ++ pickersOf(c);
    return out;
}

fn checkAll(comptime State: type, comptime n: Spec) void {
    if (isPicker(n)) validate(State, n.bind.?);
    for (n.children) |c| checkAll(State, c);
}

// ---- example page -----------------------------------------------------------------------------

/// The example page: a caption and a colour picker on a panel, in both front ends, in theme
/// `th`. Its tests and golden images run it.
pub fn Example(comptime th: Theme) type {
    return struct {
        const panel: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(16), .gap = 8, .fill = th.panel };
        pub const start: Hsva = .{ .h = 0.6, .s = 0.5, .v = 0.75, .a = 1 };

        /// Runtime front end: the application owns the colour.
        pub const App = struct {
            color: Hsva = start,

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, panel);
                _ = base.label(f, &th, "Colour");
                _ = colorpicker(f, &th, .from("paint"), &app.color);
                f.close();
            }
        };

        /// Comptime front end: the same page as a spec over a state struct.
        pub const State = struct {
            title: []const u8 = "Colour",
            color: Hsva = start,
        };
        pub const spec = spec_zig.col(panel, .{
            base.ct.label(th, .title),
            ct.colorpicker(th, .paint, .color),
        });
        pub const Ui = ComptimeColorpicker(State, spec, th);
        pub const limits: context.Limits = .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const theme: Theme = .default;
const Replay = @import("../core/input.zig").Replay;

var harness: Example(theme).Run = .{};

/// Rows of the example page: root, panel, caption, group, then the parts.
const group_row = 3;
const area_row = group_row + 1;
const hue_row = area_row + 4;
const alpha_row = hue_row + 1 + hue_stops + 1;

test "colorpicker: a group of three sliders with their values" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 240 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    const c = Example(theme).start;
    try testing.expectEqual(@backingInt(a11y.Role.group), t.c.role[group_row]);
    for ([_]u32{ area_row, hue_row, alpha_row }) |k| try testing.expectEqual(@backingInt(a11y.Role.slider), t.c.role[k]);
    try testing.expectEqual(@as(f32, 0.5), t.c.value[area_row]);
    try testing.expectApproxEqAbs(@as(f32, 216), t.c.value[hue_row], 1e-3);
    try testing.expectEqual(@as(f32, 1), t.c.value[alpha_row]);
    const k = c.rgba();
    try testing.expectEqual(@as(f32, @floatFromInt(@as(u32, k.r) * 65536 + @as(u32, k.g) * 256 + k.b)), t.c.value[group_row]);
    try testing.expectEqual(t.find(partId(.from("paint"), .hue)), hue_row);

    var sbuf: [4096]u8 align(@import("../core/mem.zig").column_align) = undefined;
    var carver: @import("../core/mem.zig").Carver = .{ .buf = &sbuf };
    var sem = a11y.Semantics.init(&carver, t.cap);
    sem.clear();
    setName(&sem, group_row, group_row - 1);
    a11y.names(t, &sem);
    try testing.expectEqual(t.c.text[group_row - 1], sem.c.name[group_row]);
}

test "check: what a comptime colour picker's state must have" {
    const Good = struct { c: Hsva = .{} };
    const Bad = struct { c: Color = .white };
    try testing.expectEqual(null, comptime check(Good, "c"));
    try testing.expectEqualStrings("colorpicker: state has no field 'x' for the colour", comptime check(Good, "x").?);
    try testing.expectEqualStrings("colorpicker: field 'c' must be a colorpicker.Hsva", comptime check(Bad, "c").?);
}

test "ct.colorpicker: three part widgets in a group bound to the colour" {
    const spec = comptime ct.colorpicker(theme, .paint, .color);
    const E = events.Events(spec);
    try testing.expectEqual(3, E.widget_count);
    try testing.expectEqualSlices(E.Widget, &.{ .paint_area, .paint_hue, .paint_alpha }, &.{ E.widget(0), E.widget(1), E.widget(2) });
    const v = comptime ct.fields(spec);
    try testing.expectEqualStrings("paint", v.name);
    try testing.expectEqualStrings("color", v.color);
    // Group, area + 3 layers, hue + 6 segments + thumb, opacity + fill + thumb.
    try testing.expectEqual(1 + 4 + 8 + 3, flatten.count(spec));
}

test "Hsva.rgba: the six hue sectors, saturation, value and opacity" {
    try testing.expectEqual(Color.rgba(255, 0, 0, 255), (Hsva{ .h = 0 }).rgba());
    try testing.expectEqual(Color.rgba(255, 255, 0, 255), (Hsva{ .h = 1.0 / 6.0 }).rgba());
    try testing.expectEqual(Color.rgba(0, 255, 0, 255), (Hsva{ .h = 2.0 / 6.0 }).rgba());
    try testing.expectEqual(Color.rgba(0, 255, 255, 255), (Hsva{ .h = 3.0 / 6.0 }).rgba());
    try testing.expectEqual(Color.rgba(0, 0, 255, 255), (Hsva{ .h = 4.0 / 6.0 }).rgba());
    try testing.expectEqual(Color.rgba(255, 0, 255, 255), (Hsva{ .h = 5.0 / 6.0 }).rgba());
    try testing.expectEqual(Color.rgba(255, 0, 0, 255), (Hsva{ .h = 1 }).rgba());
    try testing.expectEqual(Color.rgba(128, 128, 128, 255), (Hsva{ .h = 0.3, .s = 0, .v = 0.5 }).rgba());
    try testing.expectEqual(Color.rgba(0, 0, 0, 0), (Hsva{ .v = 0, .a = 0 }).rgba());
    try testing.expectEqual(Color.rgba(255, 128, 128, 255), (Hsva{ .s = 0.5 }).rgba());
}

test "colorpicker: both front ends agree; marker and thumbs sit at the values" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 240 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    const c = Example(theme).start;
    const area = t.rect(area_row);
    try testing.expectEqual(area_size[0], area.w());
    try testing.expectEqual(area_size[1], area.h());
    // The ring is centred on (s, 1 - v) of the area.
    const ring = t.rect(area_row + 3);
    try testing.expectApproxEqAbs(area.x0 + c.s * area.w(), (ring.x0 + ring.x1) / 2, 0.5);
    try testing.expectApproxEqAbs(area.y0 + (1 - c.v) * area.h(), (ring.y0 + ring.y1) / 2, 0.5);
    const thumb = t.rect(hue_row + 1 + hue_stops);
    try testing.expectApproxEqAbs(t.rect(hue_row).x0 + c.h * area_size[0], (thumb.x0 + thumb.x1) / 2, 0.5);
    // The area's base is the pure hue; the hue track's segments share its width.
    try testing.expectEqual((Hsva{ .h = c.h }).rgba().bitsOf(), t.c.look[area_row].fill);
    try testing.expectApproxEqAbs(area_size[0] / hue_stops, t.rect(hue_row + 1).w(), 1);
}

test "dragArea, sliderKeys, update: the behaviour as pure functions" {
    const rect: Rect = .{ .x0 = 10, .y0 = 20, .x1 = 110, .y1 = 70 };
    const c: Hsva = .{};
    try testing.expectEqual(c, dragArea(c, false, rect, 60, 45));
    const d = dragArea(c, true, rect, 60, 45);
    try testing.expectEqual(@as(f32, 0.5), d.s);
    try testing.expectEqual(@as(f32, 0.5), d.v);
    const e = dragArea(c, true, rect, -50, 500);
    try testing.expectEqual(@as(f32, 0), e.s);
    try testing.expectEqual(@as(f32, 0), e.v);
    const km = list_zig.default_keys;
    const keys = [_]Input.Event{ .{ .kind = .press, .code = km.right }, .{ .kind = .repeat, .code = km.up }, .{ .kind = .release, .code = km.up } };
    try testing.expectApproxEqAbs(@as(f32, 0.52), sliderKeys(0.5, &.{ .events = &keys }), 1e-6);
    const ends = [_]Input.Event{ .{ .kind = .press, .code = km.end }, .{ .kind = .press, .code = km.right } };
    try testing.expectEqual(@as(f32, 1), sliderKeys(0.2, &.{ .events = &ends }));
    const home = [_]Input.Event{.{ .kind = .press, .code = km.home }};
    try testing.expectEqual(@as(f32, 0), sliderKeys(0.7, &.{ .events = &home }));
    // Only the focused part takes keys; only a held part follows the pointer.
    const rects = [3]Rect{ rect, rect, rect };
    var r: [3]Response = @splat(.{});
    r[1] = .{ .held = true, .focused = true };
    const in: Input = .{ .pointer = .{ 35, 45 }, .events = &home };
    const u = update(.{ .h = 0.9, .s = 0.3, .v = 0.4, .a = 0.6 }, r, rects, &in);
    try testing.expectEqual(Hsva{ .h = 0, .s = 0.3, .v = 0.4, .a = 0.6 }, u);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
