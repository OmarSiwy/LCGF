//! Chip: a short caption on a pill (a tag, a filter, a recipient), optionally with a button
//! that asks to remove it. Tier 2, written against the public API of tiers 0 and 1 (the
//! recipe in base.zig).
//!
//! State: the caption, the application's string, and nothing else: removing a chip is the
//! application's to do when it is asked (the remove button's click), as a list of chips is
//! the application's data. The runtime front end takes the caption as `str` and the remove
//! button's caption as an optional string; the comptime front end binds both as string fields
//! (checked as labels' bindings), the remove button's optional.

const std = @import("std");
const base = @import("base.zig");
const label_zig = @import("label.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;

// ---- spec -----------------------------------------------------------------------------------

/// The id of the remove button of the chip named `chip`, in both front ends: the runtime one
/// derives it with `Id.with`, the comptime one from the button's spec name `<chip>.remove`.
pub fn removeId(chip: Id) Id {
    return chip.with(0);
}

/// The chip's name from its remove button's comptime name `<chip>.remove`.
pub fn chipName(comptime remove: []const u8) []const u8 {
    return remove[0 .. remove.len - ".remove".len];
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A chip named `id` showing the string field `text`, with a remove button captioned by
    /// the string field `remove` when it is not null: `ct.chip(th, .rust, .rust_text,
    /// .remove_text)` or `ct.chip(th, .draft, .draft_text, null)`. The chip itself is no
    /// widget; its remove button is the widget `<id>.remove`, a button (void event, focus
    /// stop) whose click asks the application to remove the chip.
    pub fn chip(comptime th: Theme, comptime id: @EnumLiteral(), comptime text: @EnumLiteral(), comptime remove: ?@EnumLiteral()) Spec {
        const caption = label_zig.ct.label(th, text);
        const kids: []const Spec = if (remove) |r| &.{ caption, .{
            .kind = .button,
            .id = @tagName(id) ++ ".remove",
            .children = &.{label_zig.ct.label(th, r)},
        } } else &.{caption};
        return .{ .kind = .chip, .children = kids };
    }
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "ct.chip: no widget of its own; the remove button, when asked for, is a focusable button" {
    const events = @import("../comptime/events.zig");
    const plain = comptime ct.chip(.default, .draft, .draft_text, null);
    try testing.expectEqual(spec_zig.Kind.chip, plain.kind);
    try testing.expectEqual(null, plain.id);
    try testing.expectEqual(@as(usize, 1), plain.children.len);
    try testing.expectEqual(0, events.Events(plain).widget_count);
    const removable = comptime ct.chip(.default, .rust, .rust_text, .remove_text);
    try testing.expectEqual(@as(usize, 2), removable.children.len);
    const r = removable.children[1];
    try testing.expectEqual(spec_zig.Kind.button, r.kind);
    try testing.expectEqualStrings("rust.remove", r.id.?);
    try testing.expectEqualStrings("rust", comptime chipName(r.id.?));
    try testing.expectEqualStrings("remove_text", r.children[0].bind.?);
    const E = events.Events(removable);
    try testing.expectEqual(void, @FieldType(E.Event, "rust.remove"));
    try testing.expectEqualSlices(E.Widget, &.{.@"rust.remove"}, E.focus_order);
}

test "chip state: captions bind as labels do; removeId differs from the chip's id" {
    const State = struct { text: []const u8 = "Rust", n: u32 = 0 };
    try testing.expectEqual(null, comptime label_zig.bindError(State, "text"));
    try testing.expect(comptime label_zig.bindError(State, "n") != null);
    try testing.expect(removeId(.from("rust")) != Id.from("rust"));
    try testing.expectEqual(Id.from("rust").with(0), removeId(.from("rust")));
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
