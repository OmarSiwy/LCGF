//! Text area: several lines of editable text, scrolled by whole lines. Tier 2, written against
//! the public API of tiers 0 and 1 (the recipe in base.zig). Built from the text field's parts
//! (textfield.zig): the same state type, look and editor; it adds lines, Up and Down between
//! them, and a vertical scroll that keeps the caret in view and follows the wheel.
//!
//! State: a `textfield.Text(cap)`, whose `scroll` is the first line shown. Given a row count
//! (both front ends; a compile-time count in the comptime one, so its rows are fixed), a text
//! area shows that many lines: one text leaf per line shown, each line the text between two
//! newlines. Those lines are not wrapped; one longer than the box is clipped. With the host's
//! layout in `Text.view` (unwrapped, one laid-out line per line), the caret, clicks and
//! selection follow it, the selection as up to `textfield.bands` bands per line, one per
//! direction run.
//!
//! Given `Options` instead (the runtime front end), it wraps: each line between newlines is
//! one text leaf that wraps at the box's content width, at the text protocol's wrap point, so
//! the font that draws it breaks it and the box grows with it in the same frame, from
//! `rows.min` to `rows.max` lines, then scrolls. The caret, clicks, the selection, Up and Down
//! (keeping the caret's x) and Home and End follow the visual lines (`Wrap`): with `Mono`,
//! broken every so many bytes as `Mono.wrap` breaks them; with a shaper, as it laid each line
//! out (the host keeps the runs, `Context.enableKept`, src/runtime/kept.zig), the caret placed
//! on its line in the same frame. `enter = .submit` makes Enter submit and Shift+Enter a
//! newline, for a chat input or a commit message.

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
const kept_mod = @import("../runtime/kept.zig");
const Kept = kept_mod.Kept;
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
/// comptime twin, if any), the placeholder `hint` on its first line while empty; or, given
/// `Options` for `rows`, wrapping and growing with its text (`textarea_zig` header). Returns
/// its response; what the input did is `s.result`.
pub fn textarea(f: *Frame, th: *const Theme, id: Id, s: anytype, rows: anytype, hint: []const u8) Response {
    if (@TypeOf(rows) == Options) {
        const face = wrapStyle(th, rows, tf.lineHeight(th), 0);
        return wrappedRows(f, th, id, s, rows, hint, face);
    }
    return textareaFace(f, th, id, s, rows, hint, areaStyle(th, rows, false));
}

/// `textarea` with its root laid out by `face` instead of `areaStyle(th, rows, false)` (or
/// `wrapStyle`, whose height it keeps), as `spec.styled` restyles `ct.textarea`; focus still
/// sets the border (`textfield.focusFace`).
pub fn textareaFace(f: *Frame, th: *const Theme, id: Id, s: anytype, rows: anytype, hint: []const u8, face: Style) Response {
    if (@TypeOf(rows) == Options) return wrappedRows(f, th, id, s, rows, hint, face);
    return fixedRows(f, th, id, s, rows, hint, face);
}

// tidy: allow(too-many-parameters) `textareaFace`'s, with the row count
fn fixedRows(
    f: *Frame,
    th: *const Theme,
    id: Id,
    s: anytype,
    rows: u32,
    hint: []const u8,
    face: Style,
) Response {
    std.debug.assert(rows > 0);
    const r0 = f.ctx.inter.response(id);
    behave(s, th, id, r0, f.lastRect(id), rows, f.in);
    tf.platform(f, s);
    const node = f.open(id, tf.focusFace(th, face, r0.focused));
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

// ---- a text area that wraps (runtime front end) ---------------------------------------------

/// How a text area that wraps its lines grows and what Enter does: pass it to `textarea` in
/// place of a row count. It shows `clamp(visual lines, rows.min, rows.max)` lines, scrolls
/// past `rows.max` with the caret kept in view, and with `enter = .submit` Enter submits
/// (`result.submitted`) and Shift+Enter inserts a newline.
pub const Options = struct {
    rows: Rows = .{},
    enter: Enter = .newline,

    pub const Rows = struct { min: u32 = 1, max: u32 = 8 };
    pub const Enter = enum { newline, submit };
};

/// The box of a text area that wraps: as wide as it is given (at least 80), as tall as its
/// lines between `o.rows.min` and `o.rows.max` lines of `line_h` px, scrolled down `scroll` px.
pub fn wrapStyle(th: *const Theme, o: Options, line_h: f32, scroll: f32) Style {
    std.debug.assert(line_h > 0);
    var s = areaStyle(th, o.rows.min, false);
    const pad = tf.padding(th);
    s.size = .{ .fill, .fit };
    s.min[1] = @as(f32, @floatFromInt(o.rows.min)) * line_h + pad[1] + pad[3];
    s.max[1] = @as(f32, @floatFromInt(@max(o.rows.max, o.rows.min))) * line_h + pad[1] + pad[3];
    s.scroll = .{ 0, scroll };
    return s;
}

/// The key a hard line's run is kept under (`Frame.keepText`): the area's id and the line.
fn keyOf(id: Id, hard: u32) u64 {
    return (@as(u64, @backingInt(id)) << 32) | hard;
}

/// The visual lines of a text area's text as the font that draws it breaks them: each line
/// between newlines from the run a shaper laid out last frame (`Frame.keptRun`), or broken
/// every `per` bytes as `Mono.wrap` breaks it.
pub const Wrap = struct {
    t: []const u8,
    /// Last frame's kept runs, or null (no host keeps them).
    f: ?*const Frame,
    id: Id,
    adv: f32,
    lh: f32,
    /// Bytes on a full line, as `Mono.wrap` counts them for a content `width` px wide.
    per: u32,

    pub fn of(t: []const u8, f: ?*const Frame, id: Id, th: *const Theme, width: f32) Wrap {
        const adv = tf.advance(th);
        const per: u32 = @intFromFloat(@min(@max(@floor(width / adv + 0.5), 1), 1e6));
        return .{ .t = t, .f = f, .id = id, .adv = adv, .lh = tf.lineHeight(th), .per = per };
    }

    /// A visual line: its bytes `start..end` (`end` before a newline or at the text's end, else
    /// the next line's start), whether it ends its line between newlines, its top, height and
    /// right end px from the text's top left, and where its hard line starts and how it was
    /// laid out.
    pub const Visual = struct {
        start: u32,
        end: u32,
        last: bool,
        top: f32,
        height: f32,
        end_x: f32,
        hard: u32,
        hard_start: u32,
        run: ?Kept.Run,
    };

    pub const Iterator = struct {
        w: *const Wrap,
        hard: u32 = 0,
        hard_start: u32 = 0,
        hard_end: u32 = 0,
        run: ?Kept.Run = null,
        j: u32 = 0,
        count: u32 = 0,
        top: f32 = 0,
        done: bool = false,

        /// Moves on to the next line between newlines, false past the last.
        fn nextHard(it: *Iterator) bool {
            const w = it.w;
            if (it.count != 0) {
                if (it.hard_end >= w.t.len) return false;
                it.hard += 1;
                it.hard_start = it.hard_end + 1;
            }
            it.hard_end = moves.lineEnd(w.t, it.hard_start);
            const bytes = w.t[it.hard_start..it.hard_end];
            it.run = if (w.f) |f| f.keptRun(keyOf(w.id, it.hard), bytes) else null;
            const n: u32 = @intCast(bytes.len);
            const mono = @max(std.math.divCeil(u32, n, w.per) catch 1, 1);
            it.count = if (it.run) |r| @intCast(r.starts.len) else mono;
            it.j = 0;
            return true;
        }

        pub fn next(it: *Iterator) ?Visual {
            std.debug.assert(it.j <= it.count);
            if (it.done) return null;
            const w = it.w;
            if (it.j == it.count and !it.nextHard()) {
                it.done = true;
                return null;
            }
            const j = it.j;
            it.j += 1;
            const last = it.j == it.count;
            const a = it.hard_start;
            const r = it.run;
            const start = if (r) |k| a + k.starts[j] else a + j * w.per;
            const kept_after = if (r) |k| (if (last) 0 else a + k.starts[j + 1]) else 0;
            const after = if (r != null) kept_after else a + (j + 1) * w.per;
            const end = if (last) it.hard_end else after;
            const mono_x = @as(f32, @floatFromInt(end - start)) * w.adv;
            const l: Visual = .{
                .start = start,
                .end = end,
                .last = last,
                .top = it.top,
                .height = if (r) |k| kept_mod.lineHeight(k, j) else w.lh,
                .end_x = if (r) |k| k.ends[j] else mono_x,
                .hard = it.hard,
                .hard_start = a,
                .run = r,
            };
            it.top += l.height;
            return l;
        }
    };

    pub fn lines(w: *const Wrap) Iterator {
        return .{ .w = w };
    }

    /// How many visual lines there are.
    pub fn count(w: *const Wrap) u32 {
        var it = w.lines();
        var n: u32 = 0;
        while (it.next()) |_| n += 1;
        return n;
    }

    /// The visual line holding the caret at `at`, and its index: a byte where a line breaks
    /// is the next line's start.
    pub fn find(w: *const Wrap, at: u32) struct { k: u32, line: Visual } {
        var it = w.lines();
        var best = it.next().?;
        var best_k: u32 = 0;
        var k: u32 = 0;
        while (it.next()) |l| {
            k += 1;
            if (l.start > at) break;
            best = l;
            best_k = k;
        }
        return .{ .k = best_k, .line = best };
    }

    /// Visual line `k`, or the last past it.
    pub fn nth(w: *const Wrap, k: u32) Visual {
        var it = w.lines();
        var l = it.next().?;
        for (0..k) |_| l = it.next() orelse return l;
        return l;
    }

    /// The x of byte `at` on line `l`, px from the line's left edge; its end, where a line
    /// breaks, is its right end.
    pub fn x(w: *const Wrap, l: Visual, at: u32) f32 {
        std.debug.assert(at >= l.start);
        if (at == l.end) return l.end_x;
        if (l.run) |r| return r.xs[at - l.hard_start];
        return @as(f32, @floatFromInt(at - l.start)) * w.adv;
    }

    /// The grapheme boundary on line `l` nearest to x `px`: on a line that does not end its
    /// line between newlines, not past its last grapheme (its end is the next line's start).
    pub fn hit(w: *const Wrap, l: Visual, px: f32) u32 {
        std.debug.assert(l.start <= l.end);
        const stop = if (l.last) l.end else moves.prevGrapheme(w.t, l.end);
        const end = @max(stop, l.start);
        if (l.run == null) return l.start + tf.stopNear(w.t[l.start..end], px / w.adv);
        var best = l.start;
        var dist = std.math.inf(f32);
        var at = l.start;
        // One stop a grapheme, at most a byte apart.
        for (0..end - l.start + 1) |_| {
            const d = @abs(w.x(l, at) - px);
            if (d < dist) {
                dist = d;
                best = at;
            }
            if (at >= end) break;
            at = moves.nextGrapheme(w.t, at);
        }
        return best;
    }

    /// The caret after Home, End, Up or Down (`code`) from `at`, keeping x `goal` px (NaN:
    /// from `at`'s) on Up and Down; `goal` is set for a run of them.
    pub fn move(w: *const Wrap, at: u32, code: u8, goal: *f32) u32 {
        const here = w.find(at);
        if (code == keys.home or code == keys.end) goal.* = std.math.nan(f32);
        if (code == keys.home) return here.line.start;
        if (code == keys.end) {
            if (here.line.last) return here.line.end;
            return @max(moves.prevGrapheme(w.t, here.line.end), here.line.start);
        }
        std.debug.assert(code == keys.up or code == keys.down);
        if (std.math.isNan(goal.*)) goal.* = w.x(here.line, at);
        const k = @as(i64, here.k) + @as(i64, if (code == keys.up) -1 else 1);
        if (k < 0) return 0;
        if (k >= w.count()) return @intCast(w.t.len);
        return w.hit(w.nth(@intCast(k)), goal.*);
    }

    /// The px a scroll of `first` whole visual lines moves the text up by.
    pub fn scrollPx(w: *const Wrap, first: u32) f32 {
        if (first == 0) return 0;
        return w.nth(first).top;
    }

    /// The byte a press at (`px`, `py`) px from the text's top left hits.
    pub fn press(w: *const Wrap, px: f32, py: f32) u32 {
        var it = w.lines();
        var line = it.next().?;
        while (it.next()) |l| {
            if (l.top > py) break;
            line = l;
        }
        return w.hit(line, px);
    }
};

/// The content width of last frame's box `last`.
fn contentWidth(th: *const Theme, last: Rect) f32 {
    const pad = tf.padding(th);
    return @max(last.w() - pad[0] - pad[2], 1);
}

/// What a text area that wraps is given each frame: last frame's box and layout, its options.
pub const Wrapped = struct { f: *const Frame, th: *const Theme, id: Id, last: Rect, o: Options };

// tidy: allow-fn(large-generic-function) one instance per Text(cap), as `behave`
/// `behave` for a text area that wraps: clicks, Up and Down, Home and End on its visual lines
/// (`Wrap` over last frame's layout), Enter as `o.enter` says, and the view following the caret
/// by visual lines.
pub fn behaveWrapped(s: anytype, g: Wrapped, r: Response, in: *const Input) void {
    std.debug.assert(g.o.rows.min > 0);
    const ed = s.editor();
    ed.mode.single_line = false;
    s.clipboard.reset();
    s.input.reset();
    const pad = tf.padding(g.th);
    const origin = [2]f32{ g.last.x0 + pad[0], g.last.y0 + pad[1] };
    const width = contentWidth(g.th, g.last);
    var scroll: u32 = @intFromFloat(s.scroll);
    const before = ed.caret;
    if (r.held) {
        const w = Wrap.of(ed.text(), g.f, g.id, g.th, width);
        const py = in.pointer[1] - origin[1] + w.scrollPx(scroll);
        const at = w.press(in.pointer[0] - origin[0], py);
        ed.caret = at;
        if (!s.held and !in.mods.shift) ed.anchor = at;
        ed.goal = std.math.nan(f32);
        ed.run = .none;
    }
    s.held = r.held;
    const cx: edit.Context = .{ .clipboard = &s.clipboard, .copy_buf = &s.copied };
    var res: edit.Result = .{};
    for (in.events, 0..) |e, i| {
        if (!r.focused or i >= 64) break;
        const pressed = e.kind == .press or e.kind == .repeat;
        const plain = @as(u8, @bitCast(e.mods)) & 0xe == 0;
        const enter = pressed and (e.code == keys.enter or e.code == 0x58);
        // Submitting: Enter submits; Shift+Enter is left to the editor, a newline.
        const bare = !e.mods.shift and !e.mods.ctrl and !e.mods.cmd;
        if (enter and g.o.enter == .submit and bare) {
            res.submitted = true;
            ed.run = .none;
            continue;
        }
        const c = e.code;
        const lines = c == keys.up or c == keys.down or c == keys.home or c == keys.end;
        if (!(pressed and plain and lines)) {
            tf.orResult(&res, tf.feed(ed, in, g.id, i, cx));
            continue;
        }
        const w = Wrap.of(ed.text(), g.f, g.id, g.th, width);
        ed.caret = w.move(ed.caret, c, &ed.goal);
        if (!e.mods.shift) ed.anchor = ed.caret;
        ed.run = .none;
    }
    const k = tf.keyboardOf(in, g.id, r.focused);
    var last_cx = cx;
    last_cx.composition = k.composition(g.id, &s.ime);
    tf.orResult(&res, tf.feed(ed, in, g.id, null, last_cx));
    s.result = res;
    const w = Wrap.of(ed.text(), g.f, g.id, g.th, width);
    const n = w.count();
    const rows = std.math.clamp(n, g.o.rows.min, @max(g.o.rows.max, g.o.rows.min));
    const hovered: f32 = @floatFromInt(@intFromBool(r.hovered));
    const wheel: i64 = @intFromFloat(@round(in.wheel[1] * hovered));
    scroll = @intCast(std.math.clamp(@as(i64, scroll) - wheel, 0, n -| rows));
    const caret = ed.shownCaret();
    const here = w.find(caret);
    if (caret != before or res.changed) scroll = revealLine(scroll, here.k, rows, n);
    s.scroll = @floatFromInt(scroll);
    if (r.focused) {
        const x = origin[0] + w.x(here.line, caret);
        const y = origin[1] + here.line.top - w.scrollPx(scroll);
        s.input.request(.{ .x0 = x, .y0 = y, .x1 = x + 1, .y1 = y + here.line.height }, .normal);
    }
}

/// The rows of a text area that wraps, under `face`: a band per visual line the selection
/// covers, a text leaf per line between newlines, wrapping (each kept for the next frame),
/// and the caret, placed on its line as the font laid it out.
// tidy: allow-fn(large-generic-function) one instance per Text(cap), as `textareaFace`
// tidy: allow(too-many-parameters) `textareaFace`'s own, passed through
fn wrappedRows(
    f: *Frame,
    th: *const Theme,
    id: Id,
    s: anytype,
    o: Options,
    hint: []const u8,
    face: Style,
) Response {
    const r0 = f.ctx.inter.response(id);
    const last = f.lastRect(id);
    behaveWrapped(s, .{ .f = f, .th = th, .id = id, .last = last, .o = o }, r0, f.in);
    tf.platform(f, s);
    const ed = s.editor();
    const t = ed.text();
    const w = Wrap.of(t, f, id, th, contentWidth(th, last));
    // The box's rows counted in its first line's height: the font's, else Mono's.
    var box = face;
    const style = wrapStyle(th, o, w.nth(0).height, w.scrollPx(@intFromFloat(s.scroll)));
    box.min[1] = style.min[1];
    box.max[1] = style.max[1];
    box.scroll = style.scroll;
    const node = f.open(id, tf.focusFace(th, box, r0.focused));
    const r = f.interact(node, types.Sense.any);
    f.setCursor(.text, r.hovered);
    wrappedBands(f, th, &w, ed.selection());
    const empty = t.len == 0;
    var start: u32 = 0;
    for (0..t.len + 1) |hard| {
        const end = moves.lineEnd(t, start);
        var ts = tf.textStyle(th, empty);
        ts.wrap = true;
        const leaf = f.textStyled(if (empty) hint else t[start..end], ts, .{ .shrink = true });
        if (!empty) f.keepText(leaf, keyOf(id, @intCast(hard)));
        if (end >= t.len) break;
        start = end + 1;
    }
    const caret = ed.shownCaret();
    const here = w.find(caret);
    const look = tf.caretStyle(th, w.x(here.line, caret), here.line.top, r0.focused);
    const cn = f.leaf(.none, look);
    if (!empty) f.keepCaret(cn, keyOf(id, here.line.hard), caret - here.line.hard_start);
    f.close();
    return r;
}

/// A band behind each visual line of `w` the selection `sel` covers; a selection running
/// past a line between newlines takes one advance more, for the newline.
fn wrappedBands(f: *Frame, th: *const Theme, w: *const Wrap, sel: [2]u32) void {
    std.debug.assert(sel[0] <= sel[1]);
    if (sel[0] == sel[1]) return;
    var it = w.lines();
    while (it.next()) |l| {
        const a = std.math.clamp(sel[0], l.start, l.end);
        const b = std.math.clamp(sel[1], l.start, l.end);
        const past = l.last and sel[0] <= l.end and sel[1] > l.end;
        if (a == b and !past) continue;
        const x0 = w.x(l, a);
        const x1 = w.x(l, b) + @as(f32, @floatFromInt(@intFromBool(past))) * w.adv;
        var band = tf.selectionStyle(th, .{ x0, @max(x1, x0) }, l.top);
        band.size[1] = .px(l.height);
        _ = f.leaf(.none, band);
    }
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A text area named `id` over the `Text(cap)` field `bind`, showing `rows` lines and
    /// `hint` while empty, a literal or a string field (`textfield.hintSpec`). Its events
    /// carry the `edit.Result` of a frame that changed the text.
    pub fn textarea(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime rows: u32, comptime hint: anytype) Spec {
        const sel: [rows * tf.bands]Spec = @splat(.{ .kind = .col });
        const lines: [rows]Spec = @splat(.{ .kind = .label });
        const kids = sel ++ lines ++ [1]Spec{.{ .kind = .col }};
        var s = spec_zig.col(areaStyle(&th, rows, false), kids);
        s.id = @tagName(id);
        s.bind = @tagName(bind);
        s.widget = Comptime(@tagName(id), @tagName(bind), rows, tf.hintSpec(hint));
        return s;
    }
};

/// The comptime text area named `name` over field `bind`, showing `rows` lines, placeholder
/// `hint` (`textfield.hintSpec`; `Spec.widget`): the same rows as `textarea`, the same input
/// applied (`behave`).
pub fn Comptime(comptime name: [:0]const u8, comptime bind: []const u8, comptime rows: u32, comptime hint: Spec) type {
    return struct {
        pub const focusable = true;
        pub const Payload = edit.Result;

        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            return textarea_zig.bindError(State, field, rows) orelse tf.hintError(State, "textarea", hint);
        }

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            _ = in;
            const Ui = @TypeOf(ui.*);
            const th = &Ui.theme;
            const s = &@field(ui.signals.state, bind);
            const focused = ui.focus == @field(Ui.Events.Widget, name);
            const t = &ui.tables.t;
            next.* += (tf.bands + 1) * rows + 2; // box, bands per line, lines, caret
            const i = t.push(parent, .hash(name), &tf.focusFace(th, n.style, focused));
            const v = view(s, th, rows, focused);
            for (0..rows) |k| {
                const l = shownLine(v.t, v.scroll, @intCast(k), v.sel, v.adv);
                const top = @as(f32, @floatFromInt(k)) * v.lh;
                for (lineBands(v.fresh, v.scroll + @as(u32, @intCast(k)), v.sel, l.sel)) |b| _ = t.push(i, .none, &tf.selectionStyle(th, b, top));
            }
            for (0..rows) |k| {
                const l = shownLine(v.t, v.scroll, @intCast(k), v.sel, v.adv);
                const hint_line = v.empty and k == 0;
                tf.pushText(ui, i, if (hint_line) spec_zig.labelBytes(hint, &ui.signals.state) else l.str, tf.textStyle(th, hint_line));
            }
            _ = t.push(i, .none, &tf.caretStyle(th, v.caret.x, v.caret.y, v.caret.shown and focused));
            t.seal(i);
        }

        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) @TypeOf(event) {
            const Ui = @TypeOf(ui.*);
            const r = base.ctResponse(ui, row, event, in);
            const last: Rect = ui.lastRect(row);
            const s = &@field(ui.signals.state, bind);
            behave(s, &Ui.theme, .hash(name), r, last, rows, in);
            if (!(s.result.changed or s.result.submitted)) return null;
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
    /// Frames kept as golden images, by name: tools/golden/ref/widgets/textarea-<name>.png.
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

/// A text area that wraps, alone in a column ten advances wide inside its padding, in `Mono`:
/// ten bytes a line.
const WrapFixture = struct {
    const context = @import("../runtime/context.zig");
    const mem = @import("../core/mem.zig");
    const limits: context.Limits = .{
        .nodes = 64,
        .texts = 16,
        .customs = 1,
        .strings = 1024,
        .depth = 8,
    };
    const th = Theme.default;
    var raw: [context.Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
    ctx: context.Context,
    s: Text(128) = .{},
    o: Options = .{ .rows = .{ .min = 1, .max = 3 } },
    in: Input = .{ .viewport = .{ 400, 300 } },
    out: context.Output = undefined,

    fn init(w: *WrapFixture) !void {
        w.* = .{ .ctx = try context.Context.init(&raw, limits) };
    }

    fn width() f32 {
        const pad = tf.padding(&th);
        return 10 * tf.advance(&th) + pad[0] + pad[2];
    }

    fn frame(w: *WrapFixture) void {
        var f = w.ctx.begin(&w.in);
        _ = f.open(.none, .{ .dir = .y, .size = .{ .px(width()), .fit } });
        _ = textarea(&f, &th, .from("chat"), &w.s, w.o, "Message");
        f.close();
        w.out = f.end(.{});
        w.in.events = &.{};
        w.in.text = "";
        w.in.buttons.left = false;
    }

    fn box(w: *const WrapFixture) Rect {
        return w.out.tree.rect(w.out.tree.find(.from("chat")));
    }

    /// The caret leaf: the area's last row.
    fn caret(w: *const WrapFixture) Rect {
        const t = w.out.tree;
        const a = t.find(.from("chat"));
        return t.rect(t.c.end[a] - 1);
    }

    fn lines(w: *const WrapFixture, n: f32) f32 {
        _ = w;
        const pad = tf.padding(&th);
        return n * tf.lineHeight(&th) + pad[1] + pad[3];
    }

    fn press(w: *WrapFixture, code: u8, mods: Input.Mods) void {
        const S = struct {
            var ev: [1]Input.Event = undefined;
        };
        S.ev[0] = .{ .kind = .press, .code = code, .mods = mods };
        w.in.events = &S.ev;
        w.frame();
    }

    fn focus(w: *WrapFixture) void {
        w.frame();
        const b = w.box();
        w.in.pointer = .{ b.x0 + 2, b.y0 + 2 };
        w.in.buttons.left = true;
        w.frame();
        w.frame();
    }
};

var wrapped: WrapFixture = undefined;

test "wrapped: one line tall empty, growing a line per ten bytes in Mono to three, then scrolling" {
    const w = &wrapped;
    try w.init();
    w.frame();
    w.frame();
    try testing.expectApproxEqAbs(w.lines(1), w.box().h(), 0.5);
    w.s.set("abcdefghijklmnopqrstuvwxy");
    w.frame();
    // Three visual lines of a 25-byte line between newlines: the box grew in the same frame.
    try testing.expectApproxEqAbs(w.lines(3), w.box().h(), 0.5);
    const lh = tf.lineHeight(&WrapFixture.th);
    const run = w.out.tree.rect(w.out.tree.find(.from("chat")) + 1);
    try testing.expectApproxEqAbs(3 * lh, run.h(), 0.5);
    // Five lines, three shown: scrolled to the caret at the end, on the last line shown.
    w.focus();
    w.s.set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRS");
    w.press(keys.home, .{});
    w.press(keys.end, .{});
    try testing.expectApproxEqAbs(w.lines(3), w.box().h(), 0.5);
    try testing.expectEqual(@as(f32, 2), w.s.scroll);
    const b = w.box();
    const pad = tf.padding(&WrapFixture.th);
    try testing.expectApproxEqAbs(b.y0 + pad[1] + 2 * lh, w.caret().y0, 0.5);
    const adv = tf.advance(&WrapFixture.th);
    try testing.expectApproxEqAbs(b.x0 + pad[0] + 5 * adv, w.caret().x0, 0.5);
}

test "wrapped: the caret, a click, Up and Down keeping x, Home and End on visual lines" {
    const w = &wrapped;
    try w.init();
    w.s.set("abcdefghijklmnopqrstuvwxy\nshort");
    w.focus();
    const th = &WrapFixture.th;
    const adv = tf.advance(th);
    const lh = tf.lineHeight(th);
    const pad = tf.padding(th);
    const b = w.box();
    // A click on the second visual line, nearest byte 13.
    w.in.pointer = .{ b.x0 + pad[0] + 3.4 * adv, b.y0 + pad[1] + 1.5 * lh };
    w.in.buttons.left = true;
    w.frame();
    w.frame();
    try testing.expectEqual(@as(u32, 13), w.s.ed.caret);
    try testing.expectApproxEqAbs(b.x0 + pad[0] + 3 * adv, w.caret().x0, 0.5);
    try testing.expectApproxEqAbs(b.y0 + pad[1] + lh, w.caret().y0, 0.5);
    // Up keeps the x: byte 3; Down twice: 13, 23; Down again: the short line's end, as its
    // x (3 advances) is past nothing, then the text's end.
    for ([_]struct { code: u8, caret: u32 }{
        .{ .code = keys.up, .caret = 3 },
        .{ .code = keys.down, .caret = 13 },
        .{ .code = keys.down, .caret = 23 },
        .{ .code = keys.down, .caret = 29 },
        .{ .code = keys.down, .caret = 31 },
    }) |st| {
        w.press(st.code, .{});
        try testing.expectEqual(st.caret, w.s.ed.caret);
    }
    // Home and End on a wrapped line: its first byte, and before its last (its end is the
    // next line's start); on the line's last visual line, the end before the newline.
    w.s.ed.caret = 13;
    w.s.ed.anchor = 13;
    w.press(keys.home, .{});
    try testing.expectEqual(@as(u32, 10), w.s.ed.caret);
    w.press(keys.end, .{});
    try testing.expectEqual(@as(u32, 19), w.s.ed.caret);
    w.press(keys.down, .{});
    w.press(keys.end, .{});
    try testing.expectEqual(@as(u32, 25), w.s.ed.caret);
}

test "wrapped: Enter submits and Shift+Enter is a newline with the option; by default a newline" {
    const w = &wrapped;
    try w.init();
    w.o.enter = .submit;
    w.s.set("hi");
    w.focus();
    w.press(keys.end, .{});
    w.press(keys.enter, .{});
    try testing.expect(w.s.result.submitted);
    try testing.expectEqualStrings("hi", w.s.text());
    w.press(keys.enter, .{ .shift = true });
    try testing.expect(!w.s.result.submitted);
    try testing.expectEqualStrings("hi\n", w.s.text());
    w.o.enter = .newline;
    w.press(keys.enter, .{});
    try testing.expect(!w.s.result.submitted);
    try testing.expectEqualStrings("hi\n\n", w.s.text());
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
