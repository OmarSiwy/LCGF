//! Switch: an on/off control drawn as a knob on a track, with a caption. Tier 2, written
//! against the public API of tiers 0 and 1 (the recipe in base.zig). It is a checkbox in
//! behaviour (a click or Space flips it) and a different thing to assistive technology: it
//! reports on and off, not checked.
//!
//! State: the application's `bool`. The runtime front end takes a pointer to it; the comptime
//! front end binds a `bool` field, checked while compiling. The caption is a bound label.
//!
//! Not animated: the knob jumps. `Frame.animate` (prototype/ui.zig) is the anim lane's, which
//! has not landed; the knob's side is one table index, so easing it later is one call.

const std = @import("std");
const base = @import("base.zig");
const label_zig = @import("label.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;

// ---- spec -----------------------------------------------------------------------------------

/// The type of a switch's bound field.
pub const Bind = bool;

/// Why `State`'s field `name` cannot be a switch's value, or null when it can.
pub fn bindError(comptime State: type, comptime name: []const u8) ?[]const u8 {
    return base.fieldError(State, "switch", name, Bind);
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A switch named `id` over the `bool` field `bind`, captioned by the string field `text`:
    /// `ct.@"switch"(th, .vsync, .vsync, .vsync_text)`.
    pub fn @"switch"(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime text: @EnumLiteral()) Spec {
        // Track (with its knob), caption: the rows the front ends push, in spec order.
        const track: Spec = .{ .kind = .col, .children = &.{Spec{ .kind = .col }} };
        var s = spec_zig.row(.{}, .{ track, label_zig.ct.label(th, text) });
        s.kind = .@"switch";
        s.id = @tagName(id);
        s.bind = @tagName(bind);
        return s;
    }
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "bindError: a switch binds a bool" {
    const State = struct { on: bool = false, n: u32 = 0 };
    try testing.expectEqual(null, comptime bindError(State, "on"));
    try testing.expectEqualStrings("switch 'n' needs a bool field, not u32", comptime bindError(State, "n").?);
}

test "ct.switch: a named, focusable widget with a void event: track, knob and caption rows" {
    const events = @import("../comptime/events.zig");
    const s = comptime ct.@"switch"(.default, .vsync, .vsync, .vsync_text);
    try testing.expectEqual(spec_zig.Kind.@"switch", s.kind);
    try testing.expectEqualStrings("vsync", s.id.?);
    try testing.expectEqualStrings("vsync", s.bind.?);
    try testing.expectEqual(@as(usize, 2), s.children.len);
    try testing.expectEqual(@as(usize, 1), s.children[0].children.len);
    try testing.expectEqualStrings("vsync_text", s.children[1].bind.?);
    const E = events.Events(s);
    try testing.expectEqual(void, @FieldType(E.Event, "vsync"));
    try testing.expectEqualSlices(E.Widget, &.{.vsync}, E.focus_order);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
