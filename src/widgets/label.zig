//! Label: static text in the theme's size and colour. It shows a string and takes no input.
//! Tier 2, written against the public API of tiers 0 and 1 (the recipe in base.zig).
//!
//! Input: none. A label has no id and senses nothing, so hit testing passes through it to
//! what is under it, Tab never stops on it, and in the comptime front end it is no `Widget`.
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
const Style = types.Style;
const TextStyle = types.TextStyle;
const Input = @import("../core/input.zig").Input;

// ---- spec -----------------------------------------------------------------------------------

/// The type a comptime label's bound field must have.
pub const Bind = []const u8;

/// Why `State`'s field `name` cannot be shown by a label, or null when it can. `ComptimeUi`
/// turns a non-null result into a compile error.
pub fn bindError(comptime State: type, comptime name: []const u8) ?[]const u8 {
    return base.fieldError(State, "label", name, Bind);
}

// ---- look -----------------------------------------------------------------------------------

/// The text: the theme's size and colour.
pub fn labelText(th: *const Theme) TextStyle {
    return .{ .px = th.text_px, .color = th.text };
}

/// The leaf around the text: sized to it (the default `fit`), no fill, static text to
/// assistive technology.
pub fn labelStyle(th: *const Theme) Style {
    _ = th;
    return .{ .role = .label };
}

// ---- runtime front end ----------------------------------------------------------------------

/// A text leaf showing `str`. The bytes are copied, so `str` may be a temporary.
pub fn label(f: *Frame, th: *const Theme, str: []const u8) Node {
    return f.textStyled(str, labelText(th), labelStyle(th));
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// Text showing the string field `text`: `ct.label(th, .title)`.
    pub fn label(comptime th: Theme, comptime text: @EnumLiteral()) Spec {
        return .{ .kind = .label, .bind = @tagName(text), .style = labelStyle(&th) };
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

/// Two labels on a column, in both front ends: the tests' page until the example page (C0510).
fn Pair(comptime th: Theme) type {
    return struct {
        const col: Style = .{ .dir = .y, .pad = @splat(8), .gap = 4 };
        pub const App = struct {
            pub fn build(_: *App, f: *Frame) void {
                _ = f.open(.from("col"), col);
                _ = label(f, &th, "Title");
                _ = label(f, &th, "Layer 0");
                f.close();
            }
        };
        pub const State = struct { title: []const u8 = "Title", layer: []const u8 = "Layer 0" };
        pub const Ui = base.ComptimeUi(State, spec_zig.col(col, .{ ct.label(th, .title), ct.label(th, .layer) }), th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256, .depth = 4 });
    };
}

var pair_default: Pair(.default).Run = .{};

test "label look: sized to its measured text, one run in the theme's size and colour, in both front ends" {
    const h = &pair_default;
    h.init();
    const in: Input = .{ .viewport = .{ 200, 100 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    const tx = out.runtime.texts;
    const th = Theme.default;
    try testing.expectEqual(@as(u32, 2), out.runtime.draw.run_len);
    // Rows: root, column, two labels.
    for ([2]u32{ 2, 3 }, [2]f32{ 5, 7 }) |row, bytes| {
        const k = t.c.text[row];
        try testing.expectEqual(th.text_px, tx.c.px[k]);
        try testing.expectEqual(th.text.bitsOf(), tx.c.color[k]);
        const r = t.rect(row);
        try testing.expectApproxEqAbs(bytes * th.text_px * 0.6, r.w(), 0.5);
        try testing.expectApproxEqAbs(th.text_px * 1.25, r.h(), 0.5);
    }
    // No fill: a label paints its text and nothing else.
    try testing.expectEqual(@as(u32, 0), t.c.look[2].fill);
}

test "label look: other theme tokens restyle both front ends alike" {
    const S = struct {
        var h: Pair(.{ .text = .rgb(10, 20, 30), .text_px = 20 }).Run = .{};
    };
    S.h.init();
    const in: Input = .{ .viewport = .{ 200, 100 } };
    const out = try S.h.frame(&in);
    try testing.expectEqual(@as(f32, 20), out.runtime.texts.c.px[0]);
    try testing.expectApproxEqAbs(@as(f32, 5 * 20 * 0.6), out.runtime.tree.rect(2).w(), 0.5);
}

/// A label between two checkboxes, in both front ends.
const Between = struct {
    const th = Theme.default;
    const row: Style = .{ .dir = .x, .gap = 8, .cross = .center };
    pub const App = struct {
        a: bool = false,
        b: bool = false,
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.from("row"), row);
            _ = base.checkbox(f, &th, .from("a"), &app.a, "A");
            _ = label(f, &th, "between");
            _ = base.checkbox(f, &th, .from("b"), &app.b, "B");
            f.close();
        }
    };
    pub const State = struct { a: bool = false, a_text: []const u8 = "A", text: []const u8 = "between", b: bool = false, b_text: []const u8 = "B" };
    pub const Ui = base.ComptimeUi(State, spec_zig.row(row, .{ base.ct.checkbox(th, .a, .a, .a_text), ct.label(th, .text), base.ct.checkbox(th, .b, .b, .b_text) }), th);
    pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256, .depth = 4 });
};

var between: Between.Run = .{};

test "label input: hit testing passes through it, Tab skips it, and a click on it changes nothing" {
    const hit = @import("../interact/hit.zig");
    const focus = @import("../interact/focus.zig");
    const h = &between;
    h.init();
    var in: Input = .{ .viewport = .{ 300, 60 } };
    var out = try h.frame(&in);
    const t = out.runtime.tree;
    // Rows: root, row, box a (2, 3, 4), the label (5), box b (6, 7, 8).
    const text_row: u32 = 5;
    try testing.expectEqual(@as(u32, 0), t.c.sense[text_row]);
    const r = t.rect(text_row);
    const mid = [2]f32{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    try testing.expectEqual(types.none, hit.at(t, mid[0], mid[1], .any));
    try testing.expectEqual(null, Between.Ui.Events.at(&h.ui.rects, mid[0], mid[1]));
    // Tab order: a then b, in both front ends.
    const stop: u8 = @bitCast(types.Sense{ .focus = true });
    const a = t.find(.from("a"));
    const b = t.find(.from("b"));
    try testing.expectEqual(a, focus.seek(t, t.c.sense, stop, 0, t.len, types.none, false));
    try testing.expectEqual(b, focus.seek(t, t.c.sense, stop, 0, t.len, a, false));
    try testing.expectEqualSlices(Between.Ui.Events.Widget, &.{ .a, .b }, Between.Ui.Events.focus_order);
    // Press and release on the label: nothing toggles, nothing takes focus or reports a click.
    in.pointer = mid;
    _ = try h.frame(&in);
    in.buttons.left = true;
    _ = try h.frame(&in);
    in.buttons.left = false;
    out = try h.frame(&in);
    try testing.expect(!h.app.a and !h.app.b);
    try testing.expect(!h.ui.signals.state.a and !h.ui.signals.state.b);
    try testing.expectEqual(null, out.comptime_.event);
    try testing.expectEqual(@as(u32, 0), h.ctx.inter.focus);
    try testing.expectEqual(@as(u32, 0), h.ctx.inter.clicked);
}

var label_semantics: base.Semantic(16) = .{};

test "label a11y: role label, named by its own text, no value, no states, in both front ends" {
    const a11y = @import("../a11y/tree.zig");
    const h = &pair_default;
    h.init();
    const in: Input = .{ .viewport = .{ 200, 100 } };
    _ = try h.frame(&in);
    const x = &label_semantics;
    try x.run(h);
    for ([2]u32{ 2, 3 }, [2][]const u8{ "Title", "Layer 0" }) |node, want| {
        const r = x.row(node).?;
        try testing.expectEqual(@backingInt(a11y.Role.label), x.out[0].c.role[r]);
        try testing.expectEqualStrings(want, x.name(0, r));
        try testing.expectEqualStrings(want, x.name(1, r));
        try testing.expectEqual(@as(f32, 0), x.out[0].c.value[r]);
        try testing.expectEqual(@as(u8, 0), x.out[0].c.state[r]);
    }
    // The column is presentational: the labels hang off the root.
    try testing.expectEqual(null, x.row(1));
    try testing.expectEqual(@as(u32, 3), x.out[0].len);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
