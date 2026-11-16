//! Toggle button: a button that stays pressed until it is pressed again (bold, mute, pin).
//! Tier 2, written against the public API of tiers 0 and 1 (the recipe in base.zig).
//!
//! State: the application's `bool`, true while pressed. The runtime front end takes a pointer
//! to it; the comptime front end binds a `bool` field, checked while compiling. The caption is
//! a bound label, as a button's.

const std = @import("std");
const base = @import("base.zig");
const label_zig = @import("label.zig");
const button_zig = @import("button.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Style = types.Style;
const Color = types.Color;
const Response = types.Response;
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const simd = @import("../core/simd.zig");

// ---- spec -----------------------------------------------------------------------------------

/// The type of a toggle button's bound field: pressed or not.
pub const Bind = bool;

/// Why `State`'s field `name` cannot be a toggle button's state, or null when it can.
pub fn bindError(comptime State: type, comptime name: []const u8) ?[]const u8 {
    return base.fieldError(State, "toggle button", name, Bind);
}

// ---- look -----------------------------------------------------------------------------------

/// The face's colours: released, the control fills; pressed, the accent at rest and under the
/// pointer and the held colour while held. Indexed `[pressed][stateIndex]`.
pub fn toggleFills(th: *const Theme) [2]base.StateColors {
    return .{ th.controlFills(), .{ th.accent, th.accent, th.control_held, th.control_held } };
}

/// The face's colour, picked by table index from whether it is pressed and from hover and
/// held. The face itself is a button's (`button.buttonStyle`).
pub fn toggleFill(th: *const Theme, pressed: bool, r: Response) Color {
    return toggleFills(th)[@intFromBool(pressed)][base.stateIndex(r)];
}

// ---- runtime front end ----------------------------------------------------------------------

/// A toggle button named `id` over `value`, captioned by `str`.
pub fn toggle(f: *Frame, th: *const Theme, id: Id, value: *bool, str: []const u8) Response {
    const node = f.open(id, button_zig.buttonStyle(th));
    const r = f.interact(node, .button);
    f.setFill(node, toggleFill(th, value.*, r));
    f.setCursor(.pointer, r.hovered);
    _ = label_zig.label(f, th, str);
    f.close();
    f.tree().c.value[node.ix()] = simd.b2f(value.*);
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A toggle button named `id` over the `bool` field `bind`, captioned by the string field
    /// `text`: `ct.toggle(th, .bold, .bold, .bold_text)`.
    pub fn toggle(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime text: @EnumLiteral()) Spec {
        var s = spec_zig.row(button_zig.buttonStyle(&th), .{label_zig.ct.label(th, text)});
        s.kind = .toggle;
        s.id = @tagName(id);
        s.bind = @tagName(bind);
        return s;
    }
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "bindError: a toggle button binds a bool" {
    const State = struct { bold: bool = false, size: f32 = 0 };
    try testing.expectEqual(null, comptime bindError(State, "bold"));
    try testing.expectEqualStrings("toggle button 'size' needs a bool field, not f32", comptime bindError(State, "size").?);
}

test "ct.toggle: a named, focusable widget with a void event, bound to its field, captioned" {
    const events = @import("../comptime/events.zig");
    const s = comptime ct.toggle(.default, .bold, .bold, .bold_text);
    try testing.expectEqual(spec_zig.Kind.toggle, s.kind);
    try testing.expectEqualStrings("bold", s.id.?);
    try testing.expectEqualStrings("bold", s.bind.?);
    try testing.expectEqualStrings("bold_text", s.children[0].bind.?);
    const E = events.Events(s);
    try testing.expectEqual(void, @FieldType(E.Event, "bold"));
    try testing.expectEqualSlices(E.Widget, &.{.bold}, E.focus_order);
}

/// Two toggle buttons, released and pressed, in both front ends, in theme `th`: the tests'
/// page until the example page (C0550).
fn Two(comptime th: Theme) type {
    return struct {
        const row: Style = .{ .dir = .x, .pad = @splat(8), .gap = 8 };
        pub const App = struct {
            bold: bool = false,
            italic: bool = true,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.from("row"), row);
                _ = toggle(f, &th, .from("bold"), &app.bold, "B");
                _ = toggle(f, &th, .from("italic"), &app.italic, "I");
                f.close();
            }
        };
        pub const State = struct { bold: bool = false, bold_text: []const u8 = "B", italic: bool = true, italic_text: []const u8 = "I" };
        pub const Ui = base.ComptimeUi(State, spec_zig.row(row, .{ ct.toggle(th, .bold, .bold, .bold_text), ct.toggle(th, .italic, .italic, .italic_text) }), th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });
    };
}

var two: Two(.default).Run = .{};

test "toggleFills: released is the button's table, pressed the accent until held" {
    const th = Theme.default;
    const t = toggleFills(&th);
    try testing.expectEqual(th.controlFills(), t[0]);
    try testing.expectEqual(base.StateColors{ th.accent, th.accent, th.control_held, th.control_held }, t[1]);
    for (0..4) |k| {
        const r: Response = .{ .hovered = k & 1 != 0, .held = k & 2 != 0 };
        try testing.expectEqual(button_zig.buttonFill(&th, r), toggleFill(&th, false, r));
        try testing.expectEqual(t[1][k], toggleFill(&th, true, r));
    }
}

test "toggle look: a button's face, filled by pressed and by hover, in both front ends" {
    const h = &two;
    h.init();
    const th = Theme.default;
    var in: Input = .{ .viewport = .{ 200, 60 } };
    var out = try h.frame(&in);
    // Rows: root, row, then per toggle: face, caption.
    const t = out.runtime.tree;
    try testing.expectEqual(th.control.bitsOf(), t.c.look[2].fill);
    try testing.expectEqual(th.accent.bitsOf(), t.c.look[4].fill);
    try testing.expectEqual(th.radius, t.c.look[2].radius);
    try testing.expectApproxEqAbs(@as(f32, 2 * th.pad + 8.4), t.rect(2).w(), 0.5);
    const r = t.rect(2);
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    out = try h.frame(&in);
    try testing.expectEqual(th.control_hot.bitsOf(), out.runtime.tree.c.look[2].fill);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
