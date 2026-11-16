//! Text area: several lines of editable text, scrolled by whole lines. Tier 2, written against
//! the public API of tiers 0 and 1 (the recipe in base.zig). Built from the text field's parts
//! (textfield.zig): the same state type, look and editor; it adds lines, Up and Down between
//! them, and a vertical scroll that keeps the caret in view and follows the wheel.
//!
//! State: a `textfield.Text(cap)`, whose `scroll` is the first line shown. A text area shows
//! `rows` lines (a compile-time count in the comptime front end, so its rows are fixed): one
//! text leaf per line shown, each line the text between two newlines. Lines are not wrapped;
//! one longer than the box is clipped. With the host's layout in `Text.view` (unwrapped, one
//! laid-out line per line), the caret, clicks and selection follow it, the selection as up to
//! `textfield.bands` bands per line, one per direction run.

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
const moves = @import("../text/edit/moves.zig");
const query = @import("../text/layout/query.zig");
const a11y = @import("../a11y/tree.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Rect = types.Rect;
const Color = types.Color;
const Response = types.Response;
const Style = types.Style;

// ---- spec -----------------------------------------------------------------------------------

/// The state type: a text field's (`textfield.Text(cap)`).
pub const Text = tf.Text;

/// Why `State` cannot hold a text area over `name`, showing `rows` lines, or null when it can.
pub fn bindError(comptime State: type, comptime name: []const u8, comptime rows: u32) ?[]const u8 {
    if (rows == 0) return "textarea '" ++ name ++ "' must show at least one row";
    return tf.textError(State, "textarea", name);
}

// ---- look -----------------------------------------------------------------------------------

/// The box: as wide as it is given (at least 80), `rows` lines tall, inset, its border the
/// accent while focused; it clips its lines. Role text input (ARIA textbox, multiline).
pub fn areaStyle(th: *const Theme, rows: u32, focused: bool) Style {
    const border = base.OnOff{ th.control_hot, th.accent };
    const pad = tf.padding(th);
    const h = @as(f32, @floatFromInt(rows)) * tf.lineHeight(th) + pad[1] + pad[3];
    return .{
        .dir = .y,
        .size = .{ .fill, .px(h) },
        .min = .{ 80, 0 },
        .pad = pad,
        .radius = th.radius,
        .fill = th.control_held,
        .border = 1,
        .border_color = border[@intFromBool(focused)],
        .clip = true,
        .role = .text_input,
    };
}

/// One line shown: its bytes, and the selection on it as x px from the line's left edge.
pub const Line = struct { str: []const u8, sel: [2]f32 };

/// Line `k` of `t` (counting from 0, lines end at newlines), or null past the last. A text of
/// n newlines has n + 1 lines.
pub fn lineAt(t: []const u8, k: u32) ?[2]u32 {
    var start: u32 = 0;
    var i: u32 = 0;
    while (i < k) : (i += 1) {
        const nl = std.mem.indexOfScalarPos(u8, t, start, '\n') orelse return null;
        start = @intCast(nl + 1);
    }
    return .{ start, moves.lineEnd(t, start) };
}

/// The line holding byte offset `at`.
pub fn lineOf(t: []const u8, at: u32) u32 {
    return @intCast(std.mem.count(u8, t[0..at], "\n"));
}

/// What line `k` from the top of the view shows: the text's line `scroll + k`, and the part of
/// the selection `sel` on it (a selection running past its end takes one more advance, for the
/// newline).
pub fn shownLine(t: []const u8, scroll: u32, k: u32, sel: [2]u32, adv: f32) Line {
    const l = lineAt(t, scroll + k) orelse return .{ .str = "", .sel = .{ 0, 0 } };
    const a = std.math.clamp(sel[0], l[0], l[1]);
    const b = std.math.clamp(sel[1], l[0], l[1]);
    const past: f32 = @floatFromInt(@intFromBool(sel[0] <= l[1] and sel[1] > l[1]));
    const x0 = @as(f32, @floatFromInt(a - l[0])) * adv;
    const x1 = @as(f32, @floatFromInt(b - l[0])) * adv + past * adv;
    return .{ .str = t[l[0]..l[1]], .sel = .{ x0, @max(x1, x0) } };
}

/// The selection `sel` on the text's line `line` as bands, x px from the line's left edge:
/// one per direction run from the layout `v` (`query.selection`), or the one `Mono` band
/// `mono` without it.
pub fn lineBands(v: ?moves.View, line: u32, sel: [2]u32, mono: [2]f32) [tf.bands][2]f32 {
    var out: [tf.bands][2]f32 = @splat(.{ 0, 0 });
    const lv = v orelse {
        out[0] = mono;
        return out;
    };
    const l = lineAt(lv.text, line) orelse return out;
    // The line's bytes and its newline, which the layout gives a glyph of its own.
    const a = @max(sel[0], l[0]);
    const b = @min(sel[1], l[1] + 1);
    if (a >= b) return out;
    var rects: [tf.bands]Rect = undefined;
    const n = query.selection(lv.l, lv.g, lv.text, a, b, &rects);
    for (rects[0..n], 0..) |r, k| out[k] = .{ r.x0, r.x1 };
    return out;
}

/// Where the caret is drawn, px from the first shown line's left edge, and whether it is on a
/// line that is shown: its x from the layout `v` when given, else its column in advances.
pub fn caretAt(t: []const u8, at: u32, scroll: u32, rows: u32, th: *const Theme, v: ?moves.View) struct { x: f32, y: f32, shown: bool } {
    const line = lineOf(t, at);
    const col = at - moves.lineStart(t, at);
    const k = @as(i64, line) - scroll;
    return .{
        .x = if (v) |lv| lv.caretRect(at).x0 else @as(f32, @floatFromInt(col)) * tf.advance(th),
        .y = @as(f32, @floatFromInt(k)) * tf.lineHeight(th),
        .shown = k >= 0 and k < rows,
    };
}

// ---- behaviour ------------------------------------------------------------------------------

/// The caret `dir` lines (-1 up, +1 down) from `at`, in the column `goal` (in bytes, the column
/// a run of vertical moves started from), at the nearest grapheme boundary; the text's start
/// or end past the first or last line.
pub fn vertical(t: []const u8, at: u32, dir: i2, goal: f32) u32 {
    const line = @as(i64, lineOf(t, at)) + dir;
    if (line < 0) return 0;
    const l = lineAt(t, @intCast(line)) orelse return @intCast(t.len);
    return l[0] + tf.stopNear(t[l[0]..l[1]], goal);
}

/// The first line shown after the caret moved to line `line`: as little scrolling as keeps it
/// among the `rows` lines shown, never past the last line.
pub fn revealLine(scroll: u32, line: u32, rows: u32, lines: u32) u32 {
    const in_view = @max(@min(scroll, line), (line + 1) -| rows);
    return @min(in_view, lines -| rows);
}

/// Applies a frame's input to text area `s` (a `*Text(cap)`) named `id` showing `rows` lines,
/// laid out last frame at `last`: as `textfield.behave` (pointer, keys, typed text, IME), with
/// Enter inserting a newline, Up and Down moving between lines in their column, and the wheel
/// scrolling by lines while the pointer is over it. The view follows the caret when the caret
/// or the text changed.
pub fn behave(s: anytype, th: *const Theme, id: Id, r: Response, last: Rect, rows: u32, in: *const Input) void {
    const ed = s.editor();
    ed.mode.single_line = false;
    s.clipboard.reset();
    s.input.reset();
    const adv = tf.advance(th);
    const lh = tf.lineHeight(th);
    const pad = tf.padding(th);
    const origin = [2]f32{ last.x0 + pad[0], last.y0 + pad[1] };
    var scroll: u32 = @intFromFloat(s.scroll);
    const before = ed.caret;
    if (r.held) {
        const t = ed.text();
        const lines = lineOf(t, @intCast(t.len)) + 1;
        const row = @max(@floor((in.pointer[1] - origin[1]) / lh), 0);
        const line = @min(@as(u32, @intFromFloat(@min(row, 1e6))) + scroll, lines - 1);
        const l = lineAt(t, line).?;
        const px = in.pointer[0] - origin[0];
        const fresh = tf.fresh(s);
        const laid = if (fresh) |v| line < v.l.len else false;
        const at = if (laid) fresh.?.hit(px, fresh.?.l.top[line] + fresh.?.l.height[line] / 2) else l[0] + tf.stopNear(t[l[0]..l[1]], px / adv);
        ed.caret = at;
        if (!s.held and !in.mods.shift) ed.anchor = at;
        ed.goal = std.math.nan(f32);
        ed.run = .none;
    }
    s.held = r.held;
    const cx: edit.Context = .{ .clipboard = &s.clipboard, .copy_buf = &s.copied };
    var res: edit.Result = .{};
    // Up and Down move here (the editor has no layout to move on); every other event goes to
    // the editor alone and in order, so typing around them lands where it should.
    for (in.events, 0..) |e, i| {
        if (!r.focused or i >= 64) break;
        const plain = @as(u8, @bitCast(e.mods)) & 0xe == 0;
        const down = (e.kind == .press or e.kind == .repeat) and plain;
        const dir: i2 = if (down and e.code == keys.up) -1 else if (down and e.code == keys.down) 1 else 0;
        if (dir == 0) {
            var one = cx;
            one.view = tf.fresh(s);
            tf.orResult(&res, tf.feed(ed, in, id, i, one));
            continue;
        }
        if (std.math.isNan(ed.goal)) ed.goal = @floatFromInt(ed.caret - moves.lineStart(ed.text(), ed.caret));
        ed.caret = vertical(ed.text(), ed.caret, dir, ed.goal);
        if (!e.mods.shift) ed.anchor = ed.caret;
        ed.run = .none;
    }
    const k = tf.keyboardOf(in, id, r.focused);
    var last_cx = cx;
    last_cx.view = tf.fresh(s);
    last_cx.composition = k.composition(id, &s.ime);
    tf.orResult(&res, tf.feed(ed, in, id, null, last_cx));
    s.result = res;
    const t = ed.text();
    const lines = lineOf(t, @intCast(t.len)) + 1;
    const max: u32 = lines -| rows;
    const wheel: i64 = @intFromFloat(@round(in.wheel[1] * @as(f32, @floatFromInt(@intFromBool(r.hovered)))));
    scroll = @intCast(std.math.clamp(@as(i64, scroll) - wheel, 0, max));
    const caret = ed.shownCaret();
    if (caret != before or res.changed) scroll = revealLine(scroll, lineOf(t, caret), rows, lines);
    s.scroll = @floatFromInt(scroll);
    if (r.focused) {
        const c = caretAt(t, caret, scroll, rows, th, tf.fresh(s));
        const x = origin[0] + c.x;
        const y = origin[1] + c.y;
        s.input.request(.{ .x0 = x, .y0 = y, .x1 = x + 1, .y1 = y + lh }, .normal);
    }
}

// ---- accessibility --------------------------------------------------------------------------

/// The semantics the tree columns cannot carry, for text area `name`: its name is the row
/// `label` (its caption, `aria-labelledby`; `none` for none), as for the text field
/// (`textfield.semantics`), and it is multiline (`aria-multiline`).
pub fn semantics(t: *const Tree, s: *a11y.Semantics, name: Id, label: u32) void {
    tf.semantics(t, s, name, label);
    const f = t.find(name);
    if (f != types.none) s.c.state[f] |= a11y.State.bitsOf(.{ .multiline = true });
}

/// Its text and placeholder, as the text field's (`textfield.textValue`).
pub const textValue = tf.textValue;

// ---- runtime front end ----------------------------------------------------------------------

/// A text area named `id` over `s` (a `*Text(cap)`) showing `rows` lines (as many as its
/// comptime twin, if any), the placeholder `hint` on its first line while empty. Returns its
/// response; what the input did is `s.result`.
pub fn textarea(f: *Frame, th: *const Theme, id: Id, s: anytype, rows: u32, hint: []const u8) Response {
    const r0 = f.ctx.inter.response(id);
    behave(s, th, id, r0, f.lastRect(id), rows, f.in);
    tf.platform(f, s);
    const node = f.open(id, areaStyle(th, rows, r0.focused));
    const r = f.interact(node, types.Sense.any);
    f.setCursor(.text, r.hovered);
    const v = view(s, th, rows, r0.focused);
    for (0..rows) |k| {
        const l = shownLine(v.t, v.scroll, @intCast(k), v.sel, v.adv);
        const top = @as(f32, @floatFromInt(k)) * v.lh;
        for (lineBands(v.fresh, v.scroll + @as(u32, @intCast(k)), v.sel, l.sel)) |b| _ = f.leaf(.none, tf.selectionStyle(th, b, top));
    }
    for (0..rows) |k| {
        const l = shownLine(v.t, v.scroll, @intCast(k), v.sel, v.adv);
        const hint_line = v.empty and k == 0;
        _ = f.textStyled(if (hint_line) hint else l.str, tf.textStyle(th, hint_line), .{});
    }
    _ = f.leaf(.none, tf.caretStyle(th, v.caret.x, v.caret.y, v.caret.shown and r0.focused));
    f.close();
    return r;
}

/// What both front ends read of `s` to build a text area's rows.
const View = struct {
    t: []const u8,
    scroll: u32,
    sel: [2]u32,
    adv: f32,
    lh: f32,
    empty: bool,
    caret: @typeInfo(@TypeOf(caretAt)).@"fn".return_type.?,
    /// The host's layout while it is of the current text (`textfield.fresh`).
    fresh: ?moves.View,
};

fn view(s: anytype, th: *const Theme, rows: u32, focused: bool) View {
    _ = focused;
    const ed = s.editor();
    const t = ed.text();
    const scroll: u32 = @intFromFloat(s.scroll);
    return .{
        .t = t,
        .scroll = scroll,
        .sel = ed.selection(),
        .adv = tf.advance(th),
        .lh = tf.lineHeight(th),
        .empty = t.len == 0,
        .caret = caretAt(t, ed.shownCaret(), scroll, rows, th, tf.fresh(s)),
        .fresh = tf.fresh(s),
    };
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A text area named `id` over the `Text(cap)` field `bind`, showing `rows` lines and the
    /// string field `hint` while empty. Its events carry the `edit.Result` of a frame that
    /// changed the text.
    pub fn textarea(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime rows: u32, comptime hint: @EnumLiteral()) Spec {
        const sel: [rows * tf.bands]Spec = @splat(.{ .kind = .col });
        const lines: [rows]Spec = @splat(.{ .kind = .label });
        const kids = sel ++ lines ++ [1]Spec{.{ .kind = .col }};
        var s = spec_zig.col(areaStyle(&th, rows, false), kids);
        s.id = @tagName(id);
        s.bind = @tagName(bind);
        s.widget = Comptime(@tagName(id), @tagName(bind), rows, @tagName(hint));
        return s;
    }
};

/// The comptime text area named `name` over field `bind`, showing `rows` lines, placeholder
/// field `hint` (`Spec.widget`): the same rows as `textarea`, the same input applied (`behave`).
pub fn Comptime(comptime name: [:0]const u8, comptime bind: []const u8, comptime rows: u32, comptime hint: []const u8) type {
    return struct {
        pub const focusable = true;
        pub const Payload = edit.Result;

        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            return textarea_zig.bindError(State, field, rows) orelse base.fieldError(State, "textarea placeholder", hint, []const u8);
        }

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            _ = .{ n, in };
            const Ui = @TypeOf(ui.*);
            const th = &Ui.theme;
            const s = &@field(ui.signals.state, bind);
            const focused = ui.focus == @field(Ui.Events.Widget, name);
            const t = &ui.tables.t;
            next.* += (tf.bands + 1) * rows + 2; // box, bands per line, lines, caret
            const i = t.push(parent, .hash(name), &areaStyle(th, rows, focused));
            const v = view(s, th, rows, focused);
            for (0..rows) |k| {
                const l = shownLine(v.t, v.scroll, @intCast(k), v.sel, v.adv);
                const top = @as(f32, @floatFromInt(k)) * v.lh;
                for (lineBands(v.fresh, v.scroll + @as(u32, @intCast(k)), v.sel, l.sel)) |b| _ = t.push(i, .none, &tf.selectionStyle(th, b, top));
            }
            for (0..rows) |k| {
                const l = shownLine(v.t, v.scroll, @intCast(k), v.sel, v.adv);
                const hint_line = v.empty and k == 0;
                tf.pushText(ui, i, if (hint_line) @field(ui.signals.state, hint) else l.str, tf.textStyle(th, hint_line));
            }
            _ = t.push(i, .none, &tf.caretStyle(th, v.caret.x, v.caret.y, v.caret.shown and focused));
            t.seal(i);
        }

        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) @TypeOf(event) {
            const Ui = @TypeOf(ui.*);
            const r = base.ctResponse(ui, row, event, in);
            const last: Rect = if (ui.built) ui.tables.t.rect(row + 1) else .{};
            const s = &@field(ui.signals.state, bind);
            behave(s, &Ui.theme, .hash(name), r, last, rows, in);
            if (!s.result.changed) return null;
            return @unionInit(Ui.Events.Event, name, s.result);
        }
    };
}

const textarea_zig = @This();

// ---- example page -------------------------------------------------------------------------

/// The text area's example page: Notes, three lines shown, holding "one\ntwo", under its
/// caption on a panel, in both front ends.
pub const Page = struct {
    const th = Theme.default;
    const panel: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(12), .gap = 8, .fill = th.panel };
    pub const Field = Text(128);
    pub const rows = 3;

    pub const App = struct {
        notes: Field = .init("one\ntwo"),
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.from("panel"), panel);
            _ = base.label(f, &th, "Notes");
            _ = textarea(f, &th, .from("notes"), &app.notes, rows, "Write here");
            f.close();
        }
    };
    pub const State = struct {
        notes_text: []const u8 = "Notes",
        notes: Field = .init("one\ntwo"),
        notes_hint: []const u8 = "Write here",
    };
    pub const spec = spec_zig.col(panel, .{
        base.ct.label(th, .notes_text),
        ct.textarea(th, .notes, .notes, rows, .notes_hint),
    });
    pub const Ui = base.ComptimeUi(State, spec, th);
    pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 512, .depth = 8 });
    pub const replay = @embedFile("testdata/textarea.replay");
    /// Frames kept as golden images, by name: tools/widgetgolden/ref/textarea-<name>.png.
    pub const golden_frames = .{ .{ "rest", 0 }, .{ "typed", 3 }, .{ "scrolled", 5 }, .{ "selected", 7 } };
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

/// Rows of the page's text area below its box: the bands, line by line, then the lines, then
/// the caret.
const line_row = 1 + Page.rows * tf.bands;
const caret_row = line_row + Page.rows;

test "bindError: a text area binds a Text(cap) and shows at least one row" {
    const State = struct { t: Text(4) = .{}, n: u32 = 0 };
    try testing.expectEqual(null, comptime bindError(State, "t", 2));
    try testing.expectEqualStrings("textarea 'n' needs a textfield.Text(cap) field, not u32", comptime bindError(State, "n", 2).?);
    try testing.expectEqualStrings("textarea 't' must show at least one row", comptime bindError(State, "t", 0).?);
}

test "lineAt, lineOf: lines between newlines" {
    const t = "ab\n\ncdef";
    try testing.expectEqual([2]u32{ 0, 2 }, lineAt(t, 0).?);
    try testing.expectEqual([2]u32{ 3, 3 }, lineAt(t, 1).?);
    try testing.expectEqual([2]u32{ 4, 8 }, lineAt(t, 2).?);
    try testing.expectEqual(null, lineAt(t, 3));
    try testing.expectEqual(@as(u32, 2), lineOf(t, 6));
}

test "vertical, revealLine: Up and Down in a column, and the view following the caret" {
    const t = "ab\n\ncdef";
    // Down from column 1 of line 0: the empty line, then column 1 of "cdef".
    try testing.expectEqual(@as(u32, 3), vertical(t, 1, 1, 1));
    try testing.expectEqual(@as(u32, 5), vertical(t, 3, 1, 1));
    try testing.expectEqual(@as(u32, 0), vertical(t, 1, -1, 1));
    try testing.expectEqual(@as(u32, 8), vertical(t, 6, 1, 2));
    try testing.expectEqual(@as(u32, 0), revealLine(0, 2, 3, 10));
    try testing.expectEqual(@as(u32, 1), revealLine(0, 3, 3, 10));
    try testing.expectEqual(@as(u32, 2), revealLine(5, 2, 3, 10));
    try testing.expectEqual(@as(u32, 7), revealLine(9, 9, 3, 10));
}

var page: Page.Run = .{};

fn both(h: *Page.Run, in: *const Input) !Page.Run.Pair {
    const out = try h.frame(in);
    const a = &h.app.notes;
    const b = &h.ui.signals.state.notes;
    try testing.expectEqualStrings(a.text(), b.text());
    try testing.expectEqual([2]u32{ a.ed.caret, a.ed.anchor }, [2]u32{ b.ed.caret, b.ed.anchor });
    try testing.expectEqual(a.scroll, b.scroll);
    try testing.expectEqual(a.input, b.input);
    return out;
}

test "textarea: the page agrees in both front ends at rest; rows lines tall" {
    const h = &page;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 140 } };
    const out = try both(h, &in);
    const t = out.runtime.tree;
    const a = t.find(.from("notes"));
    // root, panel, caption, the area and its rows: bands, lines and the caret.
    try testing.expectEqual(@as(u32, 3 + 1 + caret_row), t.len);
    const th = Theme.default;
    try testing.expectApproxEqAbs(3 * tf.lineHeight(&th) + th.pad, t.rect(a).h(), 0.5);
    try testing.expectEqual(@backingInt(types.Role.text_input), t.c.role[a]);
    // The lines, one leaf each: "one", "two", "".
    const strs = &h.ctx.strings[h.ctx.cur];
    for ([_][]const u8{ "one", "two", "" }, 0..) |want, k| {
        const run = t.c.text[a + line_row + @as(u32, @intCast(k))];
        try testing.expectEqualStrings(want, strs.buf[out.runtime.texts.c.start[run]..][0..out.runtime.texts.c.bytes[run]]);
    }
}

test "textarea look: an inset box rows lines tall; the selection on each line, the caret on its line" {
    const h = &page;
    h.init();
    const th = Theme.default;
    var in: Input = .{ .viewport = .{ 320, 140 } };
    var out = try h.frame(&in);
    var t = out.runtime.tree;
    const a = t.find(.from("notes"));
    try testing.expectEqual(th.control_held.bitsOf(), t.c.look[a].fill);
    try testing.expectEqual(th.control_hot.bitsOf(), t.c.look[a].border_color);
    // Lines stacked one line height apart.
    const lh = tf.lineHeight(&th);
    try testing.expectApproxEqAbs(t.rect(a + line_row).y0 + lh, t.rect(a + line_row + 1).y0, 0.5);
    // Focused, the selection from column 3 of "one" to the end of "two": on line 0 one
    // advance wide (the newline), on line 1 three; the caret at the end of "two".
    const box = t.rect(a);
    in.pointer = .{ box.x1 - 4, box.y0 + th.pad / 2 + 1.5 * lh };
    in.buttons.left = true;
    _ = try h.frame(&in);
    in.buttons.left = false;
    in.pointer = .{ 0, 0 };
    for ([2]*Page.Field{ &h.app.notes, &h.ui.signals.state.notes }) |s| {
        s.ed.anchor = 3;
        s.ed.caret = 7;
    }
    out = try h.frame(&in);
    t = out.runtime.tree;
    const adv = tf.advance(&th);
    try testing.expectEqual(th.accent.bitsOf(), t.c.look[a].border_color);
    // Edges snap to whole pixels: within one of the exact width.
    try testing.expectApproxEqAbs(adv, t.rect(a + 1).w(), 1);
    try testing.expectApproxEqAbs(3 * adv, t.rect(a + 1 + tf.bands).w(), 1);
    try testing.expectEqual(@as(f32, 0), t.rect(a + 1 + 2 * tf.bands).w());
    try testing.expectEqual(th.text.bitsOf(), t.c.look[a + caret_row].fill);
    try testing.expectApproxEqAbs(t.rect(a + line_row + 1).y0, t.rect(a + caret_row).y0, 0.5);
    try testing.expectApproxEqAbs(t.rect(a + line_row + 1).x0 + 3 * adv, t.rect(a + caret_row).x0, 0.5);
}

var area_semantics: base.Semantic(32) = .{};

test "textarea a11y: role text input, one node, named by its caption, multiline" {
    const h = &page;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 140 } };
    const out = try h.frame(&in);
    const x = &area_semantics;
    try x.run(h);
    const t = out.runtime.tree;
    const a = t.find(.from("notes"));
    const r = x.row(a).?;
    try testing.expectEqual(@backingInt(a11y.Role.text_input), x.out[0].c.role[r]);
    try testing.expectEqual(@backingInt(Id.from("notes")), x.out[0].c.id[r]);
    for (1..caret_row + 1) |k| try testing.expectEqual(null, x.row(a + @as(u32, @intCast(k))));
    const check = @import("check.zig");
    var sb: check.SemBuf = .{};
    var sem = sb.init();
    semantics(t, &sem, .from("notes"), a - 1);
    a11y.names(t, &sem);
    const ctx = &h.ctx;
    try testing.expectEqualStrings("Notes", check.nameOf(&sem, out.runtime.texts, ctx.strings[ctx.cur].buf[0..ctx.strings[ctx.cur].len], a));
    try testing.expectEqual(a11y.State.bitsOf(.{ .multiline = true }), sem.c.state[a]);
    // The same in the comptime front end's tree.
    var sb2: check.SemBuf = .{};
    var sem2 = sb2.init();
    semantics(&h.ui.tables.t, &sem2, .from("notes"), a - 1);
    try testing.expectEqual(sem.c.state[a], sem2.c.state[a]);
    try testing.expectEqual(sem.c.labelled_by[a], sem2.c.labelled_by[a]);
}

fn press(code: u8, mods: Input.Mods) Input.Event {
    return .{ .kind = .press, .code = code, .mods = mods };
}

test "textarea input: Enter, Up and Down in their column, scrolling to the caret and by wheel" {
    const h = &page;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 140 } };
    var out = try both(h, &in);
    const t = out.runtime.tree;
    const area = t.rect(t.find(.from("notes")));
    const th = Theme.default;
    const adv = tf.advance(&th);
    const lh = tf.lineHeight(&th);
    // Press on line 1 after "tw".
    in.pointer = .{ area.x0 + th.pad + 2 * adv, area.y0 + th.pad / 2 + 1.5 * lh };
    in.buttons.left = true;
    _ = try both(h, &in);
    in.buttons.left = false;
    _ = try both(h, &in);
    try testing.expectEqual(@as(u32, 6), h.app.notes.ed.caret);
    // Up: column 2 of "one"; Down twice: back, then past the last line to the end.
    for ([_]struct { code: u8, caret: u32 }{ .{ .code = keys.up, .caret = 2 }, .{ .code = keys.down, .caret = 6 }, .{ .code = keys.down, .caret = 7 } }) |st| {
        const ev = [_]Input.Event{press(st.code, .{})};
        in.events = &ev;
        _ = try both(h, &in);
        try testing.expectEqual(st.caret, h.app.notes.ed.caret);
    }
    // Typing around Enter keeps the order: "a", Enter, "b", Enter, "c", Enter, "d".
    var txt = "abcd".*;
    const ev = [_]Input.Event{
        .{ .kind = .text, .at = 0, .len = 1 }, press(0x28, .{}), .{ .kind = .text, .at = 1, .len = 1 }, press(0x28, .{}),
        .{ .kind = .text, .at = 2, .len = 1 }, press(0x28, .{}), .{ .kind = .text, .at = 3, .len = 1 },
    };
    in.text = &txt;
    in.events = &ev;
    out = try both(h, &in);
    try testing.expectEqualStrings("one\ntwoa\nb\nc\nd", h.app.notes.text());
    // Five lines, three shown: scrolled so the caret's line is the last shown.
    try testing.expectEqual(@as(f32, 2), h.app.notes.scroll);
    try testing.expect(out.runtime.platform.wants_text);
    // The wheel scrolls back up (positive is up), clamped at the top.
    in.text = "";
    in.events = &.{};
    in.wheel = .{ 0, 5 };
    _ = try both(h, &in);
    try testing.expectEqual(@as(f32, 0), h.app.notes.scroll);
    in.wheel = .{ 0, -1 };
    _ = try both(h, &in);
    try testing.expectEqual(@as(f32, 1), h.app.notes.scroll);
    // Shift+Up selects up a line.
    in.wheel = .{ 0, 0 };
    const sel = [_]Input.Event{press(keys.up, .{ .shift = true })};
    in.events = &sel;
    _ = try both(h, &in);
    try testing.expectEqual([2]u32{ 12, 14 }, h.app.notes.ed.selection());
}

var mixed: tf.Mixed = .{};

test "textarea view: bands per direction run on each line, caret and clicks on the layout" {
    const h = &page;
    h.init();
    const th = Theme.default;
    const adv = tf.advance(&th);
    const lh = tf.lineHeight(&th);
    var in: Input = .{ .viewport = .{ 320, 140 } };
    var out = try both(h, &in);
    const a = out.runtime.tree.find(.from("notes"));
    const box = out.runtime.tree.rect(a);
    const text = tf.Mixed.text ++ "\nxyz";
    const v = try mixed.view(text, adv, lh);
    // From "c" on line 0 to after "x" on line 1.
    for ([2]*Page.Field{ &h.app.notes, &h.ui.signals.state.notes }) |f| {
        f.set(text);
        f.view = v;
        f.ed.anchor = 2;
        f.ed.caret = 16;
    }
    out = try both(h, &in);
    const t = out.runtime.tree;
    const x0 = box.x0 + th.pad;
    const band = struct {
        fn of(tree: *const @import("../core/tree.zig").Tree, area: u32, line: u32, k: u32) Rect {
            return tree.rect(area + 1 + line * tf.bands + k);
        }
    }.of;
    // Line 0: "c " left to right, the Hebrew word right to left, " def" and the newline left
    // to right: three bands side by side. Laid out to whole pixels: within one of the place.
    const want = [_][2]f32{ .{ 2, 4 }, .{ 4, 7 }, .{ 7, 12 } };
    for (want, 0..) |w, k| {
        const r = band(t, a, 0, @intCast(k));
        try testing.expectApproxEqAbs(x0 + w[0] * adv, r.x0, 1);
        try testing.expectApproxEqAbs((w[1] - w[0]) * adv, r.w(), 1);
    }
    try testing.expectEqual(@as(f32, 0), band(t, a, 0, 3).w());
    // Line 1: "x", one band; the caret after it.
    try testing.expectApproxEqAbs(x0, band(t, a, 1, 0).x0, 1);
    try testing.expectApproxEqAbs(adv, band(t, a, 1, 0).w(), 1);
    try testing.expectEqual(@as(f32, 0), band(t, a, 1, 1).w());
    try testing.expectApproxEqAbs(band(t, a, 1, 0).y0, t.rect(a + caret_row).y0, 0.5);
    try testing.expectApproxEqAbs(x0 + adv, t.rect(a + caret_row).x0, 1);
    // A click near the right edge of "א" on line 0 lands on its logical start (4).
    in.pointer = .{ x0 + 6.8 * adv, box.y0 + th.pad / 2 + 0.5 * lh };
    in.buttons.left = true;
    _ = try both(h, &in);
    in.buttons.left = false;
    out = try both(h, &in);
    try testing.expectEqual(@as(u32, 4), h.app.notes.ed.caret);
    try testing.expectApproxEqAbs(x0 + 7 * adv, out.runtime.tree.rect(a + caret_row).x0, 1);
}

test "Page: the text area replay types lines, moves, scrolls and selects, in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &page;
    h.init();
    var text: [32]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = Page.replay };
    const Want = struct { text: []const u8, sel: [2]u32, scroll: f32 };
    const want = [_]Want{
        .{ .text = "one\ntwo", .sel = .{ 7, 7 }, .scroll = 0 },
        .{ .text = "one\ntwo", .sel = .{ 7, 7 }, .scroll = 0 },
        .{ .text = "one\ntwo", .sel = .{ 7, 7 }, .scroll = 0 },
        .{ .text = "one\ntwo\nthree", .sel = .{ 13, 13 }, .scroll = 0 },
        .{ .text = "one\ntwo\nthree", .sel = .{ 7, 7 }, .scroll = 0 },
        .{ .text = "one\ntwo\nthree\nfour", .sel = .{ 18, 18 }, .scroll = 1 },
        .{ .text = "one\ntwo\nthree\nfour", .sel = .{ 18, 18 }, .scroll = 0 },
        .{ .text = "one\ntwo\nthree\nfour", .sel = .{ 3, 18 }, .scroll = 0 },
        .{ .text = "one", .sel = .{ 3, 3 }, .scroll = 0 },
    };
    while (try replay.next(buf)) |in| {
        const k = h.frames;
        _ = try both(h, in);
        try testing.expectEqualStrings(want[k].text, h.app.notes.text());
        try testing.expectEqual(want[k].sel, h.app.notes.ed.selection());
        try testing.expectEqual(want[k].scroll, h.app.notes.scroll);
    }
    try testing.expectEqual(@as(u32, 9), h.frames);
    const t = &h.ctx.trees[h.ctx.cur];
    // The rect the replay's comment gives.
    try testing.expectEqual(Rect{ .x0 = 12, .y0 = 38, .x1 = 308, .y1 = 98 }, t.rect(t.find(.from("notes"))));
    inline for (Page.golden_frames) |g| try testing.expect(g[1] < 9);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
