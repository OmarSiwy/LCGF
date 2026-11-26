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
const keys = @import("keys.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const Tree = @import("../core/tree.zig").Tree;
const edit = @import("../text/edit/edit.zig");
const a11y = @import("../a11y/tree.zig");
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

// ---- behaviour ------------------------------------------------------------------------------

/// The value typed in `text` (spaces around it ignored), clamped to `range`, or null when
/// it is not a number.
pub fn parse(text: []const u8, range: Range) ?f32 {
    const v = std.fmt.parseFloat(f32, std.mem.trim(u8, text, " ")) catch return null;
    if (std.math.isNan(v)) return null;
    return std.math.clamp(v, range.lo, range.hi);
}

/// The value after key `code` on a focused field, or null for a key that does not step:
/// Up and Down by the step, Page Up and Page Down by ten, Home and End to the ends.
pub fn stepped(value: f32, code: u8, range: Range) ?f32 {
    const v: f32 = if (code == keys.up)
        value + range.step
    else if (code == keys.down)
        value - range.step
    else if (code == keys.page_up)
        value + 10 * range.step
    else if (code == keys.page_down)
        value - 10 * range.step
    else if (code == keys.home)
        range.lo
    else if (code == keys.end)
        range.hi
    else
        return null;
    return std.math.clamp(v, range.lo, range.hi);
}

/// Takes the typed text as the value (or, if it is not a number, the value back as the text).
pub fn commit(s: *Number, range: Range) void {
    s.value = parse(s.text.text(), range) orelse s.value;
    show(s);
}

/// Applies a frame's input to field `s` named `id`, laid out last frame at `last`: the pointer
/// places the caret (as `textfield.behave`); while focused the stepping keys (`stepped`)
/// change the value, Enter takes the typed text, and other keys and typed text edit it; the
/// wheel over the field steps the value (up adds); losing focus takes the typed text. Returns
/// whether the value changed.
pub fn behave(s: *Number, th: *const Theme, id: Id, r: Response, last: Rect, range: Range, in: *const Input) bool {
    const before = s.value;
    const t = &s.text;
    // Unfocused, the text is the value: so this is also where losing focus takes the text.
    if (!r.focused) commit(s, range);
    const ed = tf.point(t, th, r, last, in);
    const cx: edit.Context = .{ .clipboard = &t.clipboard, .copy_buf = &t.copied };
    var res: edit.Result = .{};
    for (in.events, 0..) |e, i| {
        if (!r.focused or i >= 64) break;
        const down = (e.kind == .press or e.kind == .repeat) and @as(u8, @bitCast(e.mods)) & 0xf == 0;
        const v = if (down) stepped(parse(t.text(), range) orelse s.value, e.code, range) else null;
        if (v) |nv| {
            s.value = nv;
            show(s);
            continue;
        }
        const one = tf.feed(ed, in, id, i, cx);
        tf.orResult(&res, one);
        if (one.submitted) commit(s, range);
    }
    const k = tf.keyboardOf(in, id, r.focused);
    var last_cx = cx;
    last_cx.composition = k.composition(id, &t.ime);
    tf.orResult(&res, tf.feed(ed, in, id, null, last_cx));
    if (r.hovered and in.wheel[1] != 0) {
        s.value = std.math.clamp(s.value + in.wheel[1] * range.step, range.lo, range.hi);
        show(s);
    }
    t.result = res;
    tf.follow(t, th, r, last);
    return s.value != before;
}

// ---- accessibility --------------------------------------------------------------------------

/// Marks row `i` of tree `t` a spin button (ARIA spinbutton) holding `value` in the value
/// column, which is where the accessibility bridge reads them.
pub fn expose(t: *Tree, i: u32, value: f32) void {
    t.c.role[i] = @backingInt(a11y.Role.spin_button);
    t.c.value[i] = value;
}

/// The semantics the tree columns cannot carry, for the field `name` in `t`: its name is the
/// row `label` (its caption, `aria-labelledby`), as for the text field, and its range is
/// `range` (`aria-valuemin`, `aria-valuemax`, and the step a screen reader's increment moves
/// by, as Up and Down do). A field not in `t` is skipped; `label` may be `none`.
pub fn semantics(t: *const Tree, s: *a11y.Semantics, name: Id, label: u32, range: Range) void {
    tf.semantics(t, s, name, label);
    const f = t.find(name);
    if (f == types.none) return;
    s.c.range[0][f] = range.lo;
    s.c.range[1][f] = range.hi;
    s.c.range[2][f] = range.step;
}

// ---- runtime front end ----------------------------------------------------------------------

/// A number field named `id` over `s`, running `range`. Returns its response; whether the
/// value changed is `s.value` against what it was.
pub fn number(f: *Frame, th: *const Theme, id: Id, s: *Number, range: Range) Response {
    const r0 = f.ctx.inter.response(id);
    _ = behave(s, th, id, r0, f.lastRect(id), range, f.in);
    tf.platform(f, &s.text);
    const node = f.open(id, numberStyle(th, r0.focused, s.text.scroll));
    const r = f.interact(node, types.Sense.any);
    f.setCursor(.text, r.hovered);
    const v = tf.shown(&s.text, th, "");
    _ = f.leaf(.none, tf.selectionStyle(th, v.sel, 0));
    _ = f.textStyled(v.str, tf.textStyle(th, false), .{});
    _ = f.leaf(.none, tf.caretStyle(th, v.caret, 0, r0.focused));
    f.close();
    expose(f.tree(), node.ix(), s.value);
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A number field named `id` over the `Number` field `bind`, running `range`. Its events
    /// carry the value, on a frame that changed it. A range whose ends are not ordered, or
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
/// the same rows as `number`, the same input applied (`behave`).
pub fn Comptime(comptime name: [:0]const u8, comptime bind: []const u8, comptime range: Range) type {
    return struct {
        pub const focusable = true;
        pub const Payload = f32;
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
            next.* += 4;
            const i = t.push(parent, .hash(name), &numberStyle(th, focused, s.text.scroll));
            const v = tf.shown(&s.text, th, "");
            _ = t.push(i, .none, &tf.selectionStyle(th, v.sel, 0));
            tf.pushText(ui, i, v.str, tf.textStyle(th, false));
            _ = t.push(i, .none, &tf.caretStyle(th, v.caret, 0, focused));
            t.seal(i);
            expose(t, i, s.value);
        }

        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) @TypeOf(event) {
            const Ui = @TypeOf(ui.*);
            const r = base.ctResponse(ui, row, event, in);
            const last: Rect = ui.lastRect(row);
            const s = &@field(ui.signals.state, bind);
            if (!behave(s, &Ui.theme, .hash(name), r, last, range, in)) return null;
            return @unionInit(Ui.Events.Event, name, s.value);
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
    pub const replay = @embedFile("testdata/number.replay");
    /// Frames kept as golden images, by name: tools/golden/ref/widgets/number-<name>.png.
    pub const golden_frames = .{ .{ "rest", 0 }, .{ "stepped", 3 }, .{ "typing", 5 }, .{ "wheel", 8 } };
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

test "parse, stepped: typed text and steps of a value" {
    const r: Range = .{ .lo = -1, .hi = 1, .step = 0.25 };
    try testing.expectEqual(@as(?f32, 0.5), parse(" 0.5 ", r));
    try testing.expectEqual(@as(?f32, 1), parse("7", r));
    try testing.expectEqual(@as(?f32, null), parse("x", r));
    try testing.expectEqual(@as(?f32, null), parse("nan", r));
    try testing.expectEqual(@as(?f32, 0.75), stepped(0.5, keys.up, r));
    try testing.expectEqual(@as(?f32, 0.25), stepped(0.5, keys.down, r));
    try testing.expectEqual(@as(?f32, 1), stepped(0.5, keys.page_up, r));
    try testing.expectEqual(@as(?f32, -1), stepped(0.5, keys.page_down, r));
    try testing.expectEqual(@as(?f32, -1), stepped(0.5, keys.home, r));
    try testing.expectEqual(@as(?f32, 1), stepped(0.5, keys.end, r));
    try testing.expectEqual(@as(?f32, null), stepped(0.5, keys.enter, r));
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

fn press(code: u8, mods: Input.Mods) Input.Event {
    return .{ .kind = .press, .code = code, .mods = mods };
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
    const q = t.find(.from("qty"));
    try testing.expectEqual(@backingInt(a11y.Role.spin_button), t.c.role[q]);
    try testing.expectEqual(@as(f32, 3), t.c.value[q]);
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

var number_semantics: base.Semantic(16) = .{};

test "number a11y: role spin button valued by its value, named by its caption, with its range" {
    const h = &page;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 140 } };
    const out = try h.frame(&in);
    const x = &number_semantics;
    try x.run(h);
    const t = out.runtime.tree;
    inline for (.{ .{ "qty", 3 }, .{ "scale", 0.5 } }) |w| {
        const n = t.find(.from(w[0]));
        const r = x.row(n).?;
        try testing.expectEqual(@backingInt(a11y.Role.spin_button), x.out[0].c.role[r]);
        try testing.expectEqual(@as(f32, w[1]), x.out[0].c.value[r]);
        try testing.expectEqual(@as(u8, 0), x.out[0].c.state[r]);
        for (1..4) |k| try testing.expectEqual(null, x.row(n + @as(u32, @intCast(k))));
    }
    const check = @import("check.zig");
    var sb: check.SemBuf = .{};
    var sem = sb.init();
    const q = t.find(.from("qty"));
    semantics(t, &sem, .from("qty"), q - 1, Page.quantity);
    a11y.names(t, &sem);
    const ctx = &h.ctx;
    try testing.expectEqualStrings("Quantity", check.nameOf(&sem, out.runtime.texts, ctx.strings[ctx.cur].buf[0..ctx.strings[ctx.cur].len], q));

    // The range, the same in both front ends.
    const popover = @import("popover.zig");
    const trees = [2]*const Tree{ t, &h.ui.tables.t };
    for (trees, &number_ranges) |tr, *y| {
        const sm = y.begin();
        semantics(tr, sm, .from("qty"), q - 1, Page.quantity);
        semantics(tr, sm, .from("scale"), tr.find(.from("scale")) - 1, Page.scale);
    }
    const e = number_ranges[0].finish(trees[0], out.runtime.texts, ctx.strings[ctx.cur].buf);
    const c = number_ranges[1].finish(trees[1], &h.ui.tables.tx, h.ui.tables.strings.buf);
    try testing.expect(popover.sameSemantics(e, c));
    for ([2][]const u8{ "qty", "scale" }, [2][3]f32{ .{ 0, 10, 1 }, .{ -1, 1, 0.25 } }) |id, want| {
        const r = popover.exportRow(e, t.find(.hash(id)));
        try testing.expectEqual(want, [3]f32{ e.c.range[0][r], e.c.range[1][r], e.c.range[2][r] });
    }
}

var number_ranges: [2]@import("popover.zig").Semantic(16) = .{ .{}, .{} };

test "number input: steps by keys and wheel, typing taken on Enter, a step or blur" {
    const h = &page;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 140 } };
    var out = try both(h, &in);
    const t = out.runtime.tree;
    const qty = t.rect(t.find(.from("qty")));
    const scale = t.rect(t.find(.from("scale")));
    in.pointer = .{ qty.x1 - 4, (qty.y0 + qty.y1) * 0.5 };
    in.buttons.left = true;
    _ = try both(h, &in);
    in.buttons.left = false;
    for ([_]struct { code: u8, v: f32 }{ .{ .code = keys.up, .v = 4 }, .{ .code = keys.page_up, .v = 10 }, .{ .code = keys.down, .v = 9 }, .{ .code = keys.home, .v = 0 } }) |st| {
        const ev = [_]Input.Event{press(st.code, .{})};
        in.events = &ev;
        out = try both(h, &in);
        try testing.expectEqual(st.v, h.app.qty.value);
        try testing.expectEqual(st.v, out.runtime.tree.c.value[t.find(.from("qty"))]);
        try testing.expectEqual(@as(?Page.Ui.Events.Event, .{ .qty = st.v }), out.comptime_.event);
    }
    // Select all, type 7, Enter: taken.
    var seven = "7".*;
    const typed = [_]Input.Event{ press(0x04, .{ .ctrl = true }), .{ .kind = .text, .at = 0, .len = 1 }, press(keys.enter, .{}) };
    in.text = &seven;
    in.events = &typed;
    _ = try both(h, &in);
    try testing.expectEqual(@as(f32, 7), h.app.qty.value);
    // Typed 5 then Up: the step starts from what was typed.
    var five = "5".*;
    const up = [_]Input.Event{ press(0x04, .{ .ctrl = true }), .{ .kind = .text, .at = 0, .len = 1 }, press(keys.up, .{}) };
    in.text = &five;
    in.events = &up;
    _ = try both(h, &in);
    try testing.expectEqual(@as(f32, 6), h.app.qty.value);
    try testing.expectEqualStrings("6", h.app.qty.text.text());
    // Garbage, then a click on Scale: Quantity keeps 6; the wheel over Scale steps it.
    var junk = "x".*;
    const j = [_]Input.Event{.{ .kind = .text, .at = 0, .len = 1 }};
    in.text = &junk;
    in.events = &j;
    _ = try both(h, &in);
    try testing.expectEqualStrings("6x", h.app.qty.text.text());
    in.text = "";
    in.events = &.{};
    in.pointer = .{ scale.x1 - 4, (scale.y0 + scale.y1) * 0.5 };
    in.buttons.left = true;
    _ = try both(h, &in);
    in.buttons.left = false;
    try testing.expectEqual(@as(f32, 6), h.app.qty.value);
    try testing.expectEqualStrings("6", h.app.qty.text.text());
    in.wheel = .{ 0, 1 };
    _ = try both(h, &in);
    try testing.expectEqual(@as(f32, 0.75), h.app.scale.value);
    in.wheel = .{ 0, -3 };
    _ = try both(h, &in);
    try testing.expectEqual(@as(f32, 0), h.app.scale.value);
}

test "Page: the number replay steps, types and scrolls, in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &page;
    h.init();
    var text: [32]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = Page.replay };
    const want_q = [_]f32{ 3, 3, 3, 5, 10, 10, 2, 2, 2, 2 };
    const want_s = [_]f32{ 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 1, 0.75 };
    const want_text = [_][]const u8{ "3", "3", "3", "5", "10", "102", "2", "2", "2", "2" };
    while (try replay.next(buf)) |in| {
        const k = h.frames;
        const out = try both(h, in);
        try testing.expectEqual(want_q[k], h.app.qty.value);
        try testing.expectEqual(want_s[k], h.app.scale.value);
        try testing.expectEqualStrings(want_text[k], h.app.qty.text.text());
        const t = out.runtime.tree;
        try testing.expectEqual(want_q[k], t.c.value[t.find(.from("qty"))]);
    }
    try testing.expectEqual(@as(u32, 10), h.frames);
    const t = &h.ctx.trees[h.ctx.cur];
    // The rects the replay's comment gives.
    try testing.expectEqual(Rect{ .x0 = 12, .y0 = 38, .x1 = 308, .y1 = 63 }, t.rect(t.find(.from("qty"))));
    try testing.expectEqual(Rect{ .x0 = 12, .y0 = 97, .x1 = 308, .y1 = 122 }, t.rect(t.find(.from("scale"))));
    inline for (Page.golden_frames) |g| try testing.expect(g[1] < 10);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
