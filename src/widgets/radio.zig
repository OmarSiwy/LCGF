//! Radio group: a set of options of which exactly one is selected. Tier 2, written against
//! the public API of tiers 0 and 1 (the recipe in base.zig).
//!
//! State: the application's selection, a `u32` index into the options. The runtime front end
//! takes a pointer to it and the captions as a slice; the comptime front end binds a `u32`
//! field (checked while compiling) and takes the captions as a tuple of string fields, one
//! option per field. Each option is a widget of its own (a hit target and a focus stop), named
//! `<group>.<index>` in the comptime `Widget` enum and `group.with(index)` at run time.

const std = @import("std");
const base = @import("base.zig");
const label_zig = @import("label.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Style = types.Style;

// ---- spec -----------------------------------------------------------------------------------

/// The type of a radio group's bound field: the index of the selected option.
pub const Bind = u32;

/// Why `State`'s field `name` cannot hold a radio group's selection, or null when it can.
pub fn bindError(comptime State: type, comptime name: []const u8) ?[]const u8 {
    return base.fieldError(State, "radio group", name, Bind);
}

/// The id of option `index` of the group named `group`, in both front ends: the runtime front
/// end derives it with `Id.with`, the comptime one from the option's spec name.
pub fn optionId(group: Id, index: u32) Id {
    return group.with(index);
}

/// The group's name from an option's comptime name `<group>.<index>`.
pub fn groupName(comptime option: []const u8) []const u8 {
    return option[0..comptime std.mem.lastIndexOfScalar(u8, option, '.').?];
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A radio group named `id` selecting the `u32` field `bind`, one option per string field
    /// in `captions` (a tuple of enum literals): `ct.radio(th, .size, .size, .{ .s_text,
    /// .m_text, .l_text })`. An empty tuple is a compile error.
    pub fn radio(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime captions: anytype) Spec {
        if (captions.len == 0) @compileError("radio group '" ++ @tagName(id) ++ "' needs at least one option");
        _ = th;
        var options: [captions.len]Spec = undefined;
        for (&options, captions, 0..) |*o, caption, i| {
            o.* = .{
                .kind = .radio_option,
                .id = std.fmt.comptimePrint("{s}.{d}", .{ @tagName(id), i }),
                .bind = @tagName(bind),
                .index = i,
                .children = &.{label_zig.ct.label(.default, caption)},
            };
        }
        const final = options;
        return .{ .kind = .radio, .bind = @tagName(bind), .style = .{ .dir = .y }, .children = &final };
    }
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "bindError: a radio group binds a u32" {
    const State = struct { size: u32 = 0, on: bool = false };
    try testing.expectEqual(null, comptime bindError(State, "size"));
    try testing.expectEqualStrings("radio group 'on' needs a u32 field, not bool", comptime bindError(State, "on").?);
}

test "ct.radio: one focusable widget per option, named <group>.<index>, bound to the group's field" {
    const events = @import("../comptime/events.zig");
    const s = comptime ct.radio(.default, .size, .size, .{ .s_text, .m_text, .l_text });
    try testing.expectEqual(spec_zig.Kind.radio, s.kind);
    try testing.expectEqual(null, s.id);
    try testing.expectEqual(@as(usize, 3), s.children.len);
    inline for (s.children, 0..) |o, i| {
        try testing.expectEqual(spec_zig.Kind.radio_option, o.kind);
        try testing.expectEqual(@as(u32, i), o.index);
        try testing.expectEqualStrings("size", o.bind.?);
        try testing.expectEqualStrings("size", comptime groupName(o.id.?));
    }
    const E = events.Events(s);
    try testing.expectEqual(3, E.widget_count);
    try testing.expectEqualSlices(E.Widget, &.{ .@"size.0", .@"size.1", .@"size.2" }, E.focus_order);
    try testing.expectEqual(void, @FieldType(E.Event, "size.1"));
}

test "optionId: options of one group are distinct and differ from the group's id" {
    const g = Id.from("size");
    try testing.expect(optionId(g, 0) != optionId(g, 1));
    try testing.expect(optionId(g, 0) != g);
    try testing.expectEqual(optionId(g, 2), g.with(2));
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
