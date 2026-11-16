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

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const theme: Theme = .default;
const Replay = @import("../core/input.zig").Replay;

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

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
