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
    const c = color.*;
    var g = pickerStyle(th);
    _ = &g;
    _ = f.open(.none, g);
    var a = areaStyle(th, c);
    _ = &a;
    const area = f.open(partId(id, .area), a);
    const ra = f.interact(area, .any);
    _ = f.leaf(.none, areaLayer(false));
    _ = f.leaf(.none, areaLayer(true));
    _ = f.leaf(.none, areaMarker(c));
    f.close();
    var hs = trackStyle(th);
    _ = &hs;
    const hue = f.open(partId(id, .hue), hs);
    _ = f.interact(hue, .any);
    for (0..hue_stops) |k| _ = f.leaf(.none, hueSegment(@intCast(k)));
    _ = f.leaf(.none, thumbStyle(c.h));
    f.close();
    var al = trackStyle(th);
    _ = &al;
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
            var g = pickerStyle(&th);
            _ = &g;
            const group = tb.t.push(parent, .none, &g);
            var a = areaStyle(&th, c);
            _ = &a;
            const area = tb.t.push(group, partId(id, .area), &a);
            _ = tb.t.push(area, .none, &areaLayer(false));
            _ = tb.t.push(area, .none, &areaLayer(true));
            _ = tb.t.push(area, .none, &areaMarker(c));
            tb.t.seal(area);
            var hs = trackStyle(&th);
            _ = &hs;
            const hue = tb.t.push(group, partId(id, .hue), &hs);
            for (0..hue_stops) |k| _ = tb.t.push(hue, .none, &hueSegment(@intCast(k)));
            _ = tb.t.push(hue, .none, &thumbStyle(c.h));
            tb.t.seal(hue);
            var al = trackStyle(&th);
            _ = &al;
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

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
