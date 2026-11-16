//! Search field: a text field with a clear button. Tier 2, written against the public API of
//! tiers 0 and 1 (the recipe in base.zig). Built from the text field's parts (textfield.zig):
//! the same state, editor, caret and selection, inside a box that also holds a Clear button,
//! shown while there is text. Enter submits the search; Escape or the button clears it, and
//! the button gives focus back to the field.
//!
//! State: a `textfield.Text(cap)`, as for the text field.

const std = @import("std");
const base = @import("base.zig");
const tf = @import("textfield.zig");
const keys = @import("keys.zig");
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
const Color = types.Color;
const Response = types.Response;
const Style = types.Style;
const TextStyle = types.TextStyle;
const hintColor = tf.hintColor;

// ---- spec -----------------------------------------------------------------------------------

/// The state type: a text field's (`textfield.Text(cap)`).
pub const Text = tf.Text;

/// Why `State` cannot hold a search field over `name` with placeholder field `hint`, or null.
pub fn bindError(comptime State: type, comptime name: []const u8, comptime hint: []const u8) ?[]const u8 {
    return tf.textError(State, "search", name) orelse base.fieldError(State, "search placeholder", hint, []const u8);
}

/// The id of search field `id`'s clear button.
pub fn clearId(id: Id) Id {
    return id.with(1);
}

/// Escape, as a USB HID scancode.
pub const escape: u8 = 0x29;

/// The clear button's caption.
pub const clear_text = "Clear";

// ---- look -----------------------------------------------------------------------------------

/// The box around the field and the button: as wide as it is given (at least 80), inset, its
/// border the accent while the field is focused.
pub fn boxStyle(th: *const Theme, focused: bool) Style {
    const border = base.OnOff{ th.control_hot, th.accent };
    return .{
        .dir = .x,
        .size = .{ .fill, .fit },
        .min = .{ 80, 0 },
        .pad = .{ 0, 0, th.pad / 2, 0 },
        .cross = .center,
        .radius = th.radius,
        .fill = th.control_held,
        .border = 1,
        .border_color = border[@intFromBool(focused)],
    };
}

/// The field inside the box: a text field's (`textfield.fieldStyle`) layout, clipping and
/// role, painted by the box instead.
pub fn inputStyle(th: *const Theme, scroll: f32) Style {
    var s = tf.fieldStyle(th, false, scroll);
    s.min = .{ 0, 0 };
    s.fill = .transparent;
    s.border = 0;
    s.border_color = .transparent;
    return s;
}

/// The clear button: a small button face by interaction state while there is text (`shown`),
/// clear otherwise (it keeps its place, so the field does not move).
pub fn clearStyle(th: *const Theme, r: Response, shown: bool) Style {
    const faces = [2]Color{ .transparent, th.controlFills()[base.stateIndex(r)] };
    return .{ .pad = .{ th.pad / 2, 2, th.pad / 2, 2 }, .radius = th.radius, .fill = faces[@intFromBool(shown)] };
}

/// The clear button's caption, in the text colour while shown.
pub fn clearText(th: *const Theme, shown: bool) TextStyle {
    const colors = base.OnOff{ .transparent, th.text };
    return .{ .px = th.text_px, .color = colors[@intFromBool(shown)] };
}

// ---- runtime front end ----------------------------------------------------------------------

/// A search field named `id` over `s` (a `*Text(cap)`), showing `hint` while empty. Returns the
/// field's response.
pub fn search(f: *Frame, th: *const Theme, id: Id, s: anytype, hint: []const u8) Response {
    const inter = &f.ctx.inter;
    const clear = inter.response(clearId(id));
    const r0 = inter.response(id);
    const shown = s.text().len > 0;
    _ = f.open(.none, boxStyle(th, r0.focused));
    const node = f.open(id, inputStyle(th, s.scroll));
    const r = f.interact(node, types.Sense.any);
    f.setCursor(.text, r.hovered);
    const v = tf.shown(s, th, hint);
    _ = f.leaf(.none, tf.selectionStyle(th, v.sel, 0));
    _ = f.textStyled(v.str, tf.textStyle(th, v.hint), .{});
    _ = f.leaf(.none, tf.caretStyle(th, v.caret, 0, r0.focused));
    f.close();
    const b = f.open(clearId(id), clearStyle(th, clear, shown));
    // Hidden, it still senses (a click on it then clears nothing), as the comptime front end's
    // rects do: both see the same hover the frame it shows.
    _ = f.interact(b, .{ .hover = true, .click = true });
    _ = f.textStyled(clear_text, clearText(th, shown), .{ .role = .label });
    f.close();
    f.close();
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A search field named `id` over the `Text(cap)` field `bind`, showing the string field
    /// `hint` while empty; its clear button is the widget `<id>.clear`.
    pub fn search(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime hint: @EnumLiteral()) Spec {
        const name = @tagName(id);
        var field = spec_zig.row(inputStyle(&th, 0), .{ Spec{ .kind = .col }, Spec{ .kind = .label }, Spec{ .kind = .col } });
        field.id = name;
        field.widget = Stop;
        var button = spec_zig.row(clearStyle(&th, .{}, false), .{Spec{ .kind = .label }});
        button.id = name ++ ".clear";
        var s = spec_zig.row(boxStyle(&th, false), .{ field, button });
        s.bind = @tagName(bind);
        s.widget = Comptime(name, @tagName(bind), @tagName(hint));
        return s;
    }
};

/// The field inside a comptime search box: a focus stop whose events carry an `edit.Result`,
/// pushed and stepped by the box (`Comptime`).
pub const Stop = struct {
    pub const focusable = true;
    pub const Payload = edit.Result;

    pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
        _ = .{ ui, n, parent, next, in };
        unreachable; // pushed by the search box
    }
};

/// The comptime search field named `name` over field `bind`, placeholder field `hint`
/// (`Spec.widget` of the box): the same rows as `search`.
pub fn Comptime(comptime name: [:0]const u8, comptime bind: []const u8, comptime hint: []const u8) type {
    return struct {
        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            return search_zig.bindError(State, field, hint);
        }

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            const Ui = @TypeOf(ui.*);
            const th = &Ui.theme;
            const s = &@field(ui.signals.state, bind);
            const focused = ui.focus == @field(Ui.Events.Widget, name);
            const t = &ui.tables.t;
            const row = next.*;
            next.* += 7; // box, field, selection, text, caret, button, caption
            const shown = s.text().len > 0;
            const box = t.push(parent, .none, &boxStyle(th, focused));
            const i = t.push(box, .hash(name), &inputStyle(th, s.scroll));
            const v = tf.shown(s, th, @field(ui.signals.state, hint));
            _ = t.push(i, .none, &tf.selectionStyle(th, v.sel, 0));
            tf.pushText(ui, i, v.str, tf.textStyle(th, v.hint));
            _ = t.push(i, .none, &tf.caretStyle(th, v.caret, 0, focused));
            t.seal(i);
            const b = t.push(box, clearId(.hash(name)), &clearStyle(th, ui.response(row + 5, in), shown));
            const k = t.push(b, .none, &.{ .role = .label });
            t.c.text[k] = ui.tables.tx.push(k, ui.tables.strings.add(clear_text), &clearText(th, shown));
            t.seal(b);
            t.seal(box);
            _ = n;
        }
    };
}

const search_zig = @This();

// ---- example page -------------------------------------------------------------------------

/// The search field's example page: Find, placeholder "Search", under its caption on a panel,
/// in both front ends.
pub const Page = struct {
    const th = Theme.default;
    const panel: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(12), .gap = 8, .fill = th.panel };
    pub const Field = Text(64);

    pub const App = struct {
        find: Field = .{},
        searches: u32 = 0,
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.from("panel"), panel);
            _ = base.label(f, &th, "Find");
            _ = search(f, &th, .from("find"), &app.find, "Search");
            app.searches += @intFromBool(app.find.result.submitted);
            f.close();
        }
    };
    pub const State = struct {
        find_text: []const u8 = "Find",
        find: Field = .{},
        find_hint: []const u8 = "Search",
    };
    pub const spec = spec_zig.col(panel, .{
        base.ct.label(th, .find_text),
        ct.search(th, .find, .find, .find_hint),
    });
    pub const Ui = base.ComptimeUi(State, spec, th);
    pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 512, .depth = 8 });
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "bindError: a search field binds a Text(cap) and a string placeholder" {
    const State = struct { t: Text(4) = .{}, n: u32 = 0, hint: []const u8 = "" };
    try testing.expectEqual(null, comptime bindError(State, "t", "hint"));
    try testing.expectEqualStrings("search 'n' needs a textfield.Text(cap) field, not u32", comptime bindError(State, "n", "hint").?);
    try testing.expectEqualStrings("search placeholder 'x': the state has no such field", comptime bindError(State, "t", "x").?);
}

test "ct.search: the field is a focus stop with an edit.Result payload; the button a widget" {
    const E = Page.Ui.Events;
    try testing.expectEqual(2, E.widget_count);
    try testing.expectEqual(edit.Result, @FieldType(E.Event, "find"));
    try testing.expectEqual(void, @FieldType(E.Event, "find.clear"));
    try testing.expectEqualSlices(E.Widget, &.{.find}, E.focus_order);
}

var page: Page.Run = .{};

fn both(h: *Page.Run, in: *const Input) !Page.Run.Pair {
    const out = try h.frame(in);
    const a = &h.app.find;
    const b = &h.ui.signals.state.find;
    try testing.expectEqualStrings(a.text(), b.text());
    try testing.expectEqual([3]u32{ a.ed.caret, a.ed.anchor, @intFromBool(a.result.submitted) }, [3]u32{ b.ed.caret, b.ed.anchor, @intFromBool(b.result.submitted) });
    return out;
}

test "search: the page agrees in both front ends; the clear button only shows with text" {
    const h = &page;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 100 } };
    var out = try both(h, &in);
    var t = out.runtime.tree;
    const f = t.find(.from("find"));
    // root, panel, caption, box, field and its three rows, button and its caption.
    try testing.expectEqual(@as(u32, 10), t.len);
    // The field inside the box.
    try testing.expectEqual(f - 1, t.c.parent[f]);
    const b = t.find(clearId(.from("find")));
    try testing.expectEqual(Color.transparent.bitsOf(), t.c.look[b].fill);
    // With text, the button shows.
    h.app.find.set("zig");
    h.ui.signals.state.find.set("zig");
    out = try both(h, &in);
    t = out.runtime.tree;
    try testing.expectEqual(Theme.default.control.bitsOf(), t.c.look[b].fill);
}

test "search look: one inset box around the field and the button; the button lights on hover" {
    const h = &page;
    h.init();
    const th = Theme.default;
    var in: Input = .{ .viewport = .{ 320, 100 } };
    var out = try h.frame(&in);
    var t = out.runtime.tree;
    const f = t.find(.from("find"));
    const b = t.find(clearId(.from("find")));
    try testing.expectEqual(th.control_held.bitsOf(), t.c.look[f - 1].fill);
    try testing.expectEqual(th.control_hot.bitsOf(), t.c.look[f - 1].border_color);
    try testing.expectEqual(Color.transparent.bitsOf(), t.c.look[f].fill);
    // The field takes the width the button leaves; the button sits at the right.
    const box = t.rect(f - 1);
    try testing.expectEqual(box.x0, t.rect(f).x0);
    try testing.expectApproxEqAbs(t.rect(f).x1, t.rect(b).x0, 0.5);
    try testing.expectApproxEqAbs(box.x1 - th.pad / 2, t.rect(b).x1, 0.5);
    try testing.expectEqual(hintColor(&th).bitsOf(), out.runtime.texts.c.color[t.c.text[f + 2]]);
    // With text, over the button: hot.
    h.app.find.set("zig");
    h.ui.signals.state.find.set("zig");
    const r = t.rect(b);
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    _ = try h.frame(&in);
    out = try h.frame(&in);
    t = out.runtime.tree;
    try testing.expectEqual(th.control_hot.bitsOf(), t.c.look[b].fill);
    try testing.expectEqual(th.text.bitsOf(), out.runtime.texts.c.color[t.c.text[b + 1]]);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
