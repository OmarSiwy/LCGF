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
const Style = types.Style;
const Color = types.Color;
const Input = @import("../core/input.zig").Input;

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

// ---- look -----------------------------------------------------------------------------------

/// The row: box, then caption, centred across, `gap` apart; role checkbox.
pub fn checkboxStyle(th: *const Theme) Style {
    return .{ .dir = .x, .gap = th.gap, .cross = .center, .role = .checkbox };
}

/// The box's fill by value: off the control colour, on and mixed the accent.
pub fn boxFills(th: *const Theme) [3]Color {
    return .{ th.control, th.accent, th.accent };
}

/// The 16 px box, outlined, filled by `boxFills`; it centres the dash.
pub fn checkboxBox(th: *const Theme, value: Check) Style {
    return .{ .size = .{ .px(16), .px(16) }, .radius = 3, .fill = boxFills(th)[@backingInt(value)], .border = 1, .border_color = th.control_hot, .main = .center, .cross = .center };
}

/// The mixed state's dash across the box: always there, transparent (so it paints nothing)
/// unless the value is mixed, so the look is picked by table index and the rows never change.
pub fn checkboxDash(th: *const Theme, value: Check) Style {
    const fills = [3]Color{ .transparent, .transparent, th.text };
    return .{ .size = .{ .px(8), .px(2) }, .radius = 1, .fill = fills[@backingInt(value)] };
}

// ---- runtime front end ----------------------------------------------------------------------

/// A checkbox named `id` over `value` (a `*bool` or a `*Check`), captioned by `str`.
pub fn checkbox(f: *Frame, th: *const Theme, id: Id, value: anytype, str: []const u8) Response {
    const row = f.open(id, checkboxStyle(th));
    const r = f.interact(row, .button);
    value.* = flip(value.*, r.clicked);
    const c = Check.of(value.*);
    _ = f.open(.none, checkboxBox(th, c));
    _ = f.leaf(.none, checkboxDash(th, c));
    f.close();
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
        // Box (with its dash), caption: the rows the front ends push, so rows keep spec order.
        const box: Spec = .{ .kind = .col, .children = &.{Spec{ .kind = .col }} };
        var s = spec_zig.row(checkboxStyle(&th), .{ box, label_zig.ct.label(th, text) });
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

/// Two checkboxes, a bool and a tri-state one, in both front ends, in theme `th`: the tests'
/// page until the example page (C0520).
fn Two(comptime th: Theme) type {
    return struct {
        const col: Style = .{ .dir = .y, .pad = @splat(8), .gap = 8 };
        pub const App = struct {
            on: bool = false,
            tri: Check = .mixed,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.from("col"), col);
                _ = checkbox(f, &th, .from("on"), &app.on, "On");
                _ = checkbox(f, &th, .from("tri"), &app.tri, "All");
                f.close();
            }
        };
        pub const State = struct { on: bool = false, on_text: []const u8 = "On", tri: Check = .mixed, tri_text: []const u8 = "All" };
        pub const Ui = base.ComptimeUi(State, spec_zig.col(col, .{ ct.checkbox(th, .on, .on, .on_text), ct.checkbox(th, .tri, .tri, .tri_text) }), th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });
    };
}

var two: Two(.default).Run = .{};

test "checkbox look: box, dash and caption laid out in a row; fills by value, in both front ends" {
    const h = &two;
    h.init();
    const th = Theme.default;
    const in: Input = .{ .viewport = .{ 200, 100 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    // Rows: root, column, then per checkbox: row, box, dash, caption.
    const on: u32 = 2;
    const tri: u32 = 6;
    for ([2]u32{ on, tri }) |row| {
        const box = t.rect(row + 1);
        try testing.expectEqual(@as(f32, 16), box.w());
        try testing.expectEqual(@as(f32, 16), box.h());
        const dash = t.rect(row + 2);
        try testing.expectEqual(types.Rect{ .x0 = box.x0 + 4, .y0 = box.y0 + 7, .x1 = box.x0 + 12, .y1 = box.y0 + 9 }, dash);
        try testing.expectEqual(box.x1 + th.gap, t.rect(row + 3).x0);
    }
    try testing.expectEqual(th.control.bitsOf(), t.c.look[on + 1].fill);
    try testing.expectEqual(Color.transparent.bitsOf(), t.c.look[on + 2].fill);
    try testing.expectEqual(th.accent.bitsOf(), t.c.look[tri + 1].fill);
    try testing.expectEqual(th.text.bitsOf(), t.c.look[tri + 2].fill);
    // Quads: the two boxes and the one visible dash; the off dash paints nothing.
    try testing.expectEqual(@as(u32, 3), out.runtime.draw.quad_len);
}

test "checkbox look: the theme's control, accent and text tokens reach both front ends" {
    const S = struct {
        var h: Two(.{ .control = .rgb(1, 2, 3), .accent = .rgb(4, 5, 6), .text = .rgb(7, 8, 9), .gap = 12 }).Run = .{};
    };
    S.h.init();
    const in: Input = .{ .viewport = .{ 200, 100 } };
    const out = try S.h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(Color.rgb(1, 2, 3).bitsOf(), t.c.look[3].fill);
    try testing.expectEqual(Color.rgb(4, 5, 6).bitsOf(), t.c.look[7].fill);
    try testing.expectEqual(Color.rgb(7, 8, 9).bitsOf(), t.c.look[8].fill);
    try testing.expectEqual(t.rect(3).x1 + 12, t.rect(5).x0);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
