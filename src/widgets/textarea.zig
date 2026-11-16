//! Text area: several lines of editable text, scrolled by whole lines. Tier 2, written against
//! the public API of tiers 0 and 1 (the recipe in base.zig). Built from the text field's parts
//! (textfield.zig): the same state type, look and editor; it adds lines, Up and Down between
//! them, and a vertical scroll that keeps the caret in view and follows the wheel.
//!
//! State: a `textfield.Text(cap)`, whose `scroll` is the first line shown. A text area shows
//! `rows` lines (a compile-time count in the comptime front end, so its rows are fixed): one
//! text leaf per line shown, each line the text between two newlines. Lines are not wrapped;
//! one longer than the box is clipped.

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

/// The box: as wide as it is given (at least 80), `rows` lines tall; it clips its lines.
/// Not yet painted.
pub fn areaStyle(th: *const Theme, rows: u32, focused: bool) Style {
    _ = focused;
    const pad = tf.padding(th);
    const h = @as(f32, @floatFromInt(rows)) * tf.lineHeight(th) + pad[1] + pad[3];
    return .{
        .dir = .y,
        .size = .{ .fill, .px(h) },
        .min = .{ 80, 0 },
        .pad = pad,
        .clip = true,
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

/// Where the caret is drawn, px from the first shown line's left edge, and whether it is on a
/// line that is shown.
pub fn caretAt(t: []const u8, at: u32, scroll: u32, rows: u32, th: *const Theme) struct { x: f32, y: f32, shown: bool } {
    const line = lineOf(t, at);
    const col = at - moves.lineStart(t, at);
    const k = @as(i64, line) - scroll;
    return .{
        .x = @as(f32, @floatFromInt(col)) * tf.advance(th),
        .y = @as(f32, @floatFromInt(k)) * tf.lineHeight(th),
        .shown = k >= 0 and k < rows,
    };
}

// ---- runtime front end ----------------------------------------------------------------------

/// A text area named `id` over `s` (a `*Text(cap)`) showing `rows` lines (as many as its
/// comptime twin, if any), the placeholder `hint` on its first line while empty. Returns its
/// response.
pub fn textarea(f: *Frame, th: *const Theme, id: Id, s: anytype, rows: u32, hint: []const u8) Response {
    const r0 = f.ctx.inter.response(id);
    const node = f.open(id, areaStyle(th, rows, r0.focused));
    const r = f.interact(node, types.Sense.any);
    f.setCursor(.text, r.hovered);
    const v = view(s, th, rows, r0.focused);
    for (0..rows) |k| {
        const l = shownLine(v.t, v.scroll, @intCast(k), v.sel, v.adv);
        _ = f.leaf(.none, tf.selectionStyle(th, l.sel, @as(f32, @floatFromInt(k)) * v.lh));
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
        .caret = caretAt(t, ed.shownCaret(), scroll, rows, th),
    };
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A text area named `id` over the `Text(cap)` field `bind`, showing `rows` lines and the
    /// string field `hint` while empty.
    pub fn textarea(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime rows: u32, comptime hint: @EnumLiteral()) Spec {
        const sel: [rows]Spec = @splat(.{ .kind = .col });
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
/// field `hint` (`Spec.widget`): the same rows as `textarea`.
pub fn Comptime(comptime name: [:0]const u8, comptime bind: []const u8, comptime rows: u32, comptime hint: []const u8) type {
    return struct {
        pub const focusable = true;

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
            next.* += 2 * rows + 2;
            const i = t.push(parent, .hash(name), &areaStyle(th, rows, focused));
            const v = view(s, th, rows, focused);
            for (0..rows) |k| {
                const l = shownLine(v.t, v.scroll, @intCast(k), v.sel, v.adv);
                _ = t.push(i, .none, &tf.selectionStyle(th, l.sel, @as(f32, @floatFromInt(k)) * v.lh));
            }
            for (0..rows) |k| {
                const l = shownLine(v.t, v.scroll, @intCast(k), v.sel, v.adv);
                const hint_line = v.empty and k == 0;
                tf.pushText(ui, i, if (hint_line) @field(ui.signals.state, hint) else l.str, tf.textStyle(th, hint_line));
            }
            _ = t.push(i, .none, &tf.caretStyle(th, v.caret.x, v.caret.y, v.caret.shown and focused));
            t.seal(i);
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
    pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 8, .customs = 1, .strings = 512, .depth = 8 });
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

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
    // root, panel, caption, the area and its 3 + 3 + 1 rows.
    try testing.expectEqual(@as(u32, 3 + 1 + 7), t.len);
    const th = Theme.default;
    try testing.expectApproxEqAbs(3 * tf.lineHeight(&th) + th.pad, t.rect(a).h(), 0.5);
    // The lines, one leaf each: "one", "two", "".
    const strs = &h.ctx.strings[h.ctx.cur];
    for ([_][]const u8{ "one", "two", "" }, 0..) |want, k| {
        const run = t.c.text[a + 4 + @as(u32, @intCast(k))];
        try testing.expectEqualStrings(want, strs.buf[out.runtime.texts.c.start[run]..][0..out.runtime.texts.c.bytes[run]]);
    }
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
