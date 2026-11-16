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

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
