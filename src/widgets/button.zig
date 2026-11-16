//! Button: a caption on a face that reports a click. Tier 2, written against the public API
//! of tiers 0 and 1 (the recipe in base.zig).
//!
//! State: none of its own. The caption is the application's string (`str` in the runtime
//! front end, a `[]const u8` field bound by the caption's label in the comptime one, checked
//! as a label's binding), and a click is reported, not stored: `Response.clicked` in the
//! runtime front end, the button's `Event` (no payload) in the comptime one.

const std = @import("std");
const base = @import("base.zig");
const label_zig = @import("label.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Response = types.Response;

// ---- runtime front end ----------------------------------------------------------------------

/// A button named `id` showing `str`; `clicked` is set the frame the left button goes up over
/// it after going down on it.
pub fn button(f: *Frame, th: *const Theme, id: Id, str: []const u8) Response {
    const node = f.open(id, base.buttonStyle(th));
    const r = f.interact(node, .button);
    f.setFill(node, base.buttonFill(th, r));
    f.setCursor(.pointer, r.hovered);
    _ = label_zig.label(f, th, str);
    f.close();
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A button named `id` showing the string field `text`; its click is its event:
    /// `ct.button(th, .reset, .reset_text)`. Its kind is `.button`, so it is a `Widget` with
    /// a `void` event and a stop in the focus order.
    pub fn button(comptime th: Theme, comptime id: @EnumLiteral(), comptime text: @EnumLiteral()) Spec {
        var s = spec_zig.row(base.buttonStyle(&th), .{label_zig.ct.label(th, text)});
        s.kind = .button;
        s.id = @tagName(id);
        return s;
    }
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const events = @import("../comptime/events.zig");

test "ct.button: a named, focusable widget with a void event, its caption a bound label" {
    const s = comptime ct.button(.default, .go, .go_text);
    try testing.expectEqual(spec_zig.Kind.button, s.kind);
    try testing.expectEqualStrings("go", s.id.?);
    try testing.expectEqual(null, s.bind);
    try testing.expectEqual(types.Axis.x, s.style.dir);
    try testing.expectEqual(spec_zig.Kind.label, s.children[0].kind);
    try testing.expectEqualStrings("go_text", s.children[0].bind.?);
    const E = events.Events(spec_zig.row(.{}, .{ s, comptime ct.button(.default, .stop, .stop_text) }));
    try testing.expectEqual(void, @FieldType(E.Event, "go"));
    try testing.expectEqualSlices(E.Widget, &.{ .go, .stop }, E.focus_order);
}

test "button state: the caption binds as a label does" {
    const State = struct { go_text: []const u8 = "Go", count: u32 = 0 };
    try testing.expectEqual(null, comptime label_zig.bindError(State, "go_text"));
    try testing.expect(comptime label_zig.bindError(State, "count") != null);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
