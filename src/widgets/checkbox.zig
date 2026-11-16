//! Checkbox: a box and a caption; a click toggles it. Tier 2, written against the public API
//! of tiers 0 and 1 (the recipe in base.zig).
//!
//! State: the application's value, a `bool` (two states) or a `Check` (three: the mixed
//! state shows that some of what the box stands for is on). The runtime front end takes a
//! pointer to it; the comptime front end binds a `bool` or `Check` field, checked while
//! compiling. The caption is a bound label, as a button's.

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

// ---- spec -----------------------------------------------------------------------------------

/// A tri-state checkbox's value. The application sets `mixed`; input only ever makes it `on`
/// or `off`.
pub const Check = enum(u2) {
    off,
    on,
    mixed,

    /// `v` as a `Check`: a `bool` is off or on, a `Check` is itself.
    pub fn of(v: anytype) Check {
        return if (@TypeOf(v) == bool) @fromBackingInt(@intCast(@intFromBool(v))) else v;
    }

    /// What the tree's `value` column holds, which accessibility reads: off 0, on 1, mixed
    /// 0.5 (ARIA `aria-checked="mixed"`).
    pub fn value(c: Check) f32 {
        const table = [3]f32{ 0, 1, 0.5 };
        return table[@backingInt(c)];
    }
};

/// Why `State`'s field `name` cannot be a checkbox's value, or null when it can: it must be a
/// `bool` or a `Check`.
pub fn bindError(comptime State: type, comptime name: []const u8) ?[]const u8 {
    const as_bool = base.fieldError(State, "checkbox", name, bool) orelse return null;
    if (base.fieldError(State, "checkbox", name, Check) == null) return null;
    return comptime as_bool ++ " (or Check)";
}

/// `v` toggled by `clicked`, in its own type: a `bool` flips, a `Check` goes to `on` from
/// `off` or `mixed` and to `off` from `on`.
pub fn flip(v: anytype, clicked: bool) @TypeOf(v) {
    const now = Check.of(v);
    // Indexed by `clicked`: stay, or the other side of `on`.
    const to = [2]Check{ now, Check.of(now != .on) };
    const c = to[@intFromBool(clicked)];
    return if (@TypeOf(v) == bool) c == .on else c;
}

// ---- runtime front end ----------------------------------------------------------------------

/// A checkbox named `id` over `value` (a `*bool` or a `*Check`), captioned by `str`.
pub fn checkbox(f: *Frame, th: *const Theme, id: Id, value: anytype, str: []const u8) Response {
    const row = f.open(id, base.checkboxStyle(th));
    const r = f.interact(row, .button);
    value.* = flip(value.*, r.clicked);
    _ = f.leaf(.none, base.checkboxBox(th, Check.of(value.*) == .on));
    _ = label_zig.label(f, th, str);
    f.close();
    f.tree().c.value[row.ix()] = Check.of(value.*).value();
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A checkbox named `id` over the `bool` or `Check` field `bind`, captioned by the string
    /// field `text`: `ct.checkbox(th, .wire, .wireframe, .wire_text)`.
    pub fn checkbox(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime text: @EnumLiteral()) Spec {
        var s = spec_zig.row(base.checkboxStyle(&th), .{ Spec{ .kind = .col }, label_zig.ct.label(th, text) });
        s.kind = .checkbox;
        s.id = @tagName(id);
        s.bind = @tagName(bind);
        return s;
    }
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "bindError: a checkbox binds a bool or a Check" {
    const State = struct { on: bool = false, tri: Check = .mixed, level: f32 = 0 };
    try testing.expectEqual(null, comptime bindError(State, "on"));
    try testing.expectEqual(null, comptime bindError(State, "tri"));
    try testing.expectEqualStrings("checkbox 'level' needs a bool field, not f32 (or Check)", comptime bindError(State, "level").?);
    try testing.expectEqualStrings("checkbox 'nope': the state has no such field (or Check)", comptime bindError(State, "nope").?);
}

test "Check: of, value, and flip in either type" {
    try testing.expectEqual(Check.on, Check.of(true));
    try testing.expectEqual(Check.off, Check.of(false));
    try testing.expectEqual(Check.mixed, Check.of(Check.mixed));
    try testing.expectEqual([3]f32{ 0, 1, 0.5 }, [3]f32{ Check.off.value(), Check.on.value(), Check.mixed.value() });
    try testing.expectEqual(true, flip(false, true));
    try testing.expectEqual(false, flip(false, false));
    try testing.expectEqual(Check.on, flip(Check.mixed, true));
    try testing.expectEqual(Check.mixed, flip(Check.mixed, false));
    try testing.expectEqual(Check.off, flip(Check.on, true));
    try testing.expectEqual(Check.on, flip(Check.off, true));
}

test "ct.checkbox: a named, focusable widget bound to its field, a box and a caption" {
    const events = @import("../comptime/events.zig");
    const s = comptime ct.checkbox(.default, .tri, .tri, .tri_text);
    try testing.expectEqual(spec_zig.Kind.checkbox, s.kind);
    try testing.expectEqualStrings("tri", s.bind.?);
    try testing.expectEqual(@as(usize, 2), s.children.len);
    const E = events.Events(s);
    try testing.expectEqual(void, @FieldType(E.Event, "tri"));
    try testing.expectEqualSlices(E.Widget, &.{.tri}, E.focus_order);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
