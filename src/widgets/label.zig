//! Label: static text in the theme's size and colour. It shows a string and takes no input.
//! Tier 2, written against the public API of tiers 0 and 1 (the recipe in base.zig).
//!
//! State: the string, owned by the application. The runtime front end takes it as `str`; the
//! comptime front end binds a `[]const u8` field of the state struct, checked while compiling.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Node = types.Node;

// ---- spec -----------------------------------------------------------------------------------

/// The type a comptime label's bound field must have.
pub const Bind = []const u8;

/// Why `State`'s field `name` cannot be shown by a label, or null when it can. `ComptimeUi`
/// turns a non-null result into a compile error.
pub fn bindError(comptime State: type, comptime name: []const u8) ?[]const u8 {
    return base.fieldError(State, "label", name, Bind);
}

// ---- runtime front end ----------------------------------------------------------------------

/// A text leaf showing `str`. The bytes are copied, so `str` may be a temporary.
pub fn label(f: *Frame, th: *const Theme, str: []const u8) Node {
    return f.text(str, base.labelText(th));
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// Text showing the string field `text`: `ct.label(th, .title)`.
    pub fn label(comptime th: Theme, comptime text: @EnumLiteral()) Spec {
        _ = th;
        return .{ .kind = .label, .bind = @tagName(text), .style = .{ .role = .label } };
    }
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "bindError: a label binds a []const u8 field, by name" {
    const State = struct { title: []const u8 = "", count: u32 = 0, on: bool = false };
    try testing.expectEqual(null, comptime bindError(State, "title"));
    try testing.expectEqualStrings("label 'count' needs a []const u8 field, not u32", comptime bindError(State, "count").?);
    try testing.expectEqualStrings("label 'on' needs a []const u8 field, not bool", comptime bindError(State, "on").?);
    try testing.expectEqualStrings("label 'nope': the state has no such field", comptime bindError(State, "nope").?);
}

test "ct.label: a text node bound to its field, no id, so it is no widget" {
    const s = comptime ct.label(.default, .title);
    try testing.expectEqual(spec_zig.Kind.label, s.kind);
    try testing.expectEqual(null, s.id);
    try testing.expectEqualStrings("title", s.bind.?);
    try testing.expectEqual(types.Role.label, s.style.role);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
