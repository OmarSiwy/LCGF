//! Number field: a number typed as text or stepped by keys and the wheel (WAI-ARIA APG
//! spinbutton). Tier 2, written against the public API of tiers 0 and 1 (the recipe in
//! base.zig). Built from the text field's parts (textfield.zig): the same box, caret and
//! editor, over the text of the number.
//!
//! State: a `Number`, the application's: the value and the text being typed. While the field
//! is not focused its text shows the value; typed text becomes the value on Enter, on a step,
//! and when the field loses focus (text that is not a number gives the old value back). The
//! ends and the step are a `Range`: arguments in the runtime front end, part of the widget's
//! type in the comptime one (as the slider's).

const std = @import("std");
const base = @import("base.zig");
const tf = @import("textfield.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const Tree = @import("../core/tree.zig").Tree;
const edit = @import("../text/edit/edit.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Rect = types.Rect;
const Response = types.Response;
const Style = types.Style;

// ---- spec -----------------------------------------------------------------------------------

/// A number field's state. Plain data with defaults; `.{ .value = 5 }` holds 5.
pub const Number = struct {
    value: f32 = 0,
    /// The text shown and edited: the value while not focused, what is typed while focused.
    text: tf.Text(24) = .{},
};

/// The ends of a number field's value and its step (Up and Down; Page Up and Page Down step
/// ten times as far).
pub const Range = struct { lo: f32 = 0, hi: f32 = 100, step: f32 = 1 };

/// Why `State`'s field `name` cannot be a number field's state, or null when it can.
pub fn bindError(comptime State: type, comptime name: []const u8) ?[]const u8 {
    return base.fieldError(State, "number", name, Number);
}

/// A compile error message for a range whose ends are not ordered or whose step is not
/// positive, or null.
pub fn rangeError(comptime name: []const u8, comptime range: Range) ?[]const u8 {
    if (!(range.lo < range.hi)) return std.fmt.comptimePrint("number '{s}': lo ({d}) must be below hi ({d})", .{ name, range.lo, range.hi });
    if (!(range.step > 0)) return std.fmt.comptimePrint("number '{s}': step ({d}) must be above 0", .{ name, range.step });
    return null;
}

// ---- look -----------------------------------------------------------------------------------

/// The box: a text field's (`textfield.fieldStyle`), as wide as it is given, one line tall.
pub fn numberStyle(th: *const Theme, focused: bool, scroll: f32) Style {
    return tf.fieldStyle(th, focused, scroll);
}

/// `value` written as the field shows it: the shortest text that reads back as it.
pub fn format(value: f32, buf: *[24]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch unreachable;
}

/// Writes the value as the text, caret at its end.
pub fn show(s: *Number) void {
    var buf: [24]u8 = undefined;
    s.text.set(format(s.value, &buf));
}

// ---- runtime front end ----------------------------------------------------------------------

/// A number field named `id` over `s`, running `range`. Returns its response.
pub fn number(f: *Frame, th: *const Theme, id: Id, s: *Number, range: Range) Response {
    const r0 = f.ctx.inter.response(id);
    _ = range;
    if (!r0.focused) show(s);
    const node = f.open(id, numberStyle(th, r0.focused, s.text.scroll));
    const r = f.interact(node, types.Sense.any);
    f.setCursor(.text, r.hovered);
    const v = tf.shown(&s.text, th, "");
    _ = f.leaf(.none, tf.selectionStyle(th, v.sel, 0));
    _ = f.textStyled(v.str, tf.textStyle(th, false), .{});
    _ = f.leaf(.none, tf.caretStyle(th, v.caret, 0, r0.focused));
    f.close();
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A number field named `id` over the `Number` field `bind`, running `range`. A range whose ends are not ordered, or
    /// whose step is not positive, is a compile error.
    pub fn number(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime range: Range) Spec {
        if (comptime rangeError(@tagName(id), range)) |msg| @compileError(msg);
        var s = spec_zig.row(numberStyle(&th, false, 0), .{ Spec{ .kind = .col }, Spec{ .kind = .label }, Spec{ .kind = .col } });
        s.id = @tagName(id);
        s.bind = @tagName(bind);
        s.widget = Comptime(@tagName(id), @tagName(bind), range);
        return s;
    }
};

/// The comptime number field named `name` over field `bind`, running `range` (`Spec.widget`):
/// the same rows as `number`.
pub fn Comptime(comptime name: [:0]const u8, comptime bind: []const u8, comptime range: Range) type {
    return struct {
        pub const focusable = true;
        /// The ends and step of its value.
        pub const value_range = range;

        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            return number_zig.bindError(State, field);
        }

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            _ = .{ n, in };
            const Ui = @TypeOf(ui.*);
            const th = &Ui.theme;
            const s = &@field(ui.signals.state, bind);
            const focused = ui.focus == @field(Ui.Events.Widget, name);
            const t = &ui.tables.t;
            if (!focused) show(s);
            next.* += 4;
            const i = t.push(parent, .hash(name), &numberStyle(th, focused, s.text.scroll));
            const v = tf.shown(&s.text, th, "");
            _ = t.push(i, .none, &tf.selectionStyle(th, v.sel, 0));
            tf.pushText(ui, i, v.str, tf.textStyle(th, false));
            _ = t.push(i, .none, &tf.caretStyle(th, v.caret, 0, focused));
            t.seal(i);
        }
    };
}

const number_zig = @This();

// ---- example page -------------------------------------------------------------------------

/// The number field's example page: Quantity (0 to 10 by 1, at 3) and Scale (-1 to 1 by 0.25,
/// at 0.5), each under its caption, on a panel, in both front ends.
pub const Page = struct {
    const th = Theme.default;
    const panel: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(12), .gap = 8, .fill = th.panel };
    pub const quantity: Range = .{ .lo = 0, .hi = 10, .step = 1 };
    pub const scale: Range = .{ .lo = -1, .hi = 1, .step = 0.25 };

    pub const App = struct {
        qty: Number = .{ .value = 3 },
        scale: Number = .{ .value = 0.5 },
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.from("panel"), panel);
            _ = base.label(f, &th, "Quantity");
            _ = number(f, &th, .from("qty"), &app.qty, quantity);
            _ = base.label(f, &th, "Scale");
            _ = number(f, &th, .from("scale"), &app.scale, scale);
            f.close();
        }
    };
    pub const State = struct {
        qty_text: []const u8 = "Quantity",
        qty: Number = .{ .value = 3 },
        scale_text: []const u8 = "Scale",
        scale: Number = .{ .value = 0.5 },
    };
    pub const spec = spec_zig.col(panel, .{
        base.ct.label(th, .qty_text),
        ct.number(th, .qty, .qty, quantity),
        base.ct.label(th, .scale_text),
        ct.number(th, .scale, .scale, scale),
    });
    pub const Ui = base.ComptimeUi(State, spec, th);
    pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 512, .depth = 8 });
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "bindError, rangeError: a number field binds a Number over an ordered range" {
    const State = struct { n: Number = .{}, f: f32 = 0 };
    try testing.expectEqual(null, comptime bindError(State, "n"));
    try testing.expectEqualStrings("number 'f' needs a widgets.number.Number field, not f32", comptime bindError(State, "f").?);
    try testing.expectEqual(null, comptime rangeError("n", .{}));
    try testing.expectEqualStrings("number 'n': lo (5) must be below hi (5)", comptime rangeError("n", .{ .lo = 5, .hi = 5 }).?);
    try testing.expectEqualStrings("number 'n': step (0) must be above 0", comptime rangeError("n", .{ .step = 0 }).?);
}

test "format: the shortest text of a value" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("3", format(3, &buf));
    try testing.expectEqualStrings("-0.25", format(-0.25, &buf));
    try testing.expectEqualStrings("0.1", format(0.1, &buf));
}

var page: Page.Run = .{};

fn both(h: *Page.Run, in: *const Input) !Page.Run.Pair {
    const out = try h.frame(in);
    inline for (.{ "qty", "scale" }) |f| {
        const a = &@field(h.app, f);
        const b = &@field(h.ui.signals.state, f);
        try testing.expectEqual(a.value, b.value);
        try testing.expectEqualStrings(a.text.text(), b.text.text());
        try testing.expectEqual([2]u32{ a.text.ed.caret, a.text.ed.anchor }, [2]u32{ b.text.ed.caret, b.text.ed.anchor });
    }
    return out;
}

test "number: the page agrees in both front ends; the text shows the value" {
    const h = &page;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 140 } };
    const out = try both(h, &in);
    const t = out.runtime.tree;
    // root, panel, two captions, two fields of four rows each.
    try testing.expectEqual(@as(u32, 12), t.len);
    try testing.expectEqualStrings("3", h.app.qty.text.text());
    try testing.expectEqualStrings("0.5", h.app.scale.text.text());
}

test "number look: a text field's box showing the value, the caret at its end while focused" {
    const h = &page;
    h.init();
    const th = Theme.default;
    var in: Input = .{ .viewport = .{ 320, 140 } };
    var out = try h.frame(&in);
    var t = out.runtime.tree;
    const q = t.find(.from("qty"));
    try testing.expectEqual(th.control_held.bitsOf(), t.c.look[q].fill);
    try testing.expectEqual(th.control_hot.bitsOf(), t.c.look[q].border_color);
    try testing.expectEqual(th.text.bitsOf(), out.runtime.texts.c.color[t.c.text[q + 2]]);
    try testing.expectApproxEqAbs(tf.lineHeight(&th) + th.pad, t.rect(q).h(), 0.5);
    const box = t.rect(q);
    in.pointer = .{ box.x1 - 4, (box.y0 + box.y1) * 0.5 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    in.buttons.left = false;
    out = try h.frame(&in);
    t = out.runtime.tree;
    try testing.expectEqual(th.accent.bitsOf(), t.c.look[q].border_color);
    try testing.expectEqual(th.text.bitsOf(), t.c.look[q + 3].fill);
    try testing.expectApproxEqAbs(box.x0 + th.pad + tf.advance(&th), t.rect(q + 3).x0, 0.5);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
