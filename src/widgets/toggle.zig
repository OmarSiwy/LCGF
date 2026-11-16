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

// ---- spec -----------------------------------------------------------------------------------

/// The type of a toggle button's bound field: pressed or not.
pub const Bind = bool;

/// Why `State`'s field `name` cannot be a toggle button's state, or null when it can.
pub fn bindError(comptime State: type, comptime name: []const u8) ?[]const u8 {
    return base.fieldError(State, "toggle button", name, Bind);
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

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
