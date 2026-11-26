//! Text field: one line of editable text. Tier 2, written against the public API of tiers 0 and
//! 1 (the recipe in base.zig). The editing itself is src/text/edit/ (`Editor`); this file gives
//! it a box, a caret and a selection, routes the focused field's keys to it, and asks the host
//! for text input (prototype/ui.zig `Platform.wants_text`, `ime_rect`).
//!
//! State: a `Text(cap)`, the application's: the field's bytes (`cap` of them), its `Editor`, and
//! what passes between the field and the host each frame (the IME's composition in, the
//! clipboard and the text-input request out). The runtime front end takes a `*Text(cap)`; the
//! comptime front end binds a `Text(cap)` field of the state (checked while compiling).
//!
//! Text is measured as the front ends measure it, with `Mono`: every byte is `advance` wide, so
//! the caret's x is its byte offset times the advance, and a click maps back the same way to
//! the nearest grapheme boundary. A host that lays the text out itself (text/layout/, with
//! bidi reordering) hands that layout over as `Text.view`; the caret, clicks and selection
//! then follow it, the selection as one band per direction run (`query.selection`).

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const Tree = @import("../core/tree.zig").Tree;
const edit = @import("../text/edit/edit.zig");
const moves = @import("../text/edit/moves.zig");
const query = @import("../text/layout/query.zig");
const lines_ = @import("../text/layout/lines.zig");
const keyboard = @import("../interact/keyboard.zig");
const Mono = @import("../text/protocol.zig").Mono;
const Graphemes = @import("../text/unicode/grapheme.zig").Graphemes;
const a11y = @import("../a11y/tree.zig");
const Strings = @import("../core/strings.zig").Strings;
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Rect = types.Rect;
const Color = types.Color;
const Response = types.Response;
const Style = types.Style;
const TextStyle = types.TextStyle;

// ---- spec -----------------------------------------------------------------------------------

/// A text field's state, `cap` bytes of text. Plain data with defaults (an empty field); give it
/// text with `init`. It may be copied and moved: the editor is pointed at `bytes` again each
/// time the widget uses it (`editor`).
pub fn Text(comptime cap: u32) type {
    return struct {
        const Self = @This();
        pub const capacity = cap;

        bytes: [cap]u8 = undefined,
        ed: edit.Editor = .{ .b = .{ .buf = &.{} } },
        /// Where copied and cut text goes; `clipboard.set` points into it.
        copied: [cap]u8 = undefined,
        /// Set by the widget each frame, for the host to read after it: text to put on the
        /// clipboard (`set`) and a paste to answer with typed text next frame (`paste`).
        clipboard: keyboard.Clipboard = .{},
        /// Set by the host before the frame: what its input method is composing. Shown at the
        /// caret while the field is focused, until it commits (as typed text) or drops it.
        ime: keyboard.Composition = .{},
        /// Set by the widget each frame: while focused, a request for text input with the IME
        /// window at the caret (the runtime front end also copies it to `Platform`).
        input: keyboard.TextInput = .{},
        /// What this frame's input did to the text (`Result.submitted`: Enter).
        result: edit.Result = .{},
        /// How far the text is scrolled, px (a text area: lines), to keep the caret in view.
        scroll: f32 = 0,
        /// The pointer held the field last frame: a press is the first frame it does.
        held: bool = false,
        /// Set by the host before the frame, or null: the layout of `text()` as the host drew
        /// it (px from the text's top left; for a text area, one laid-out line per line between
        /// newlines, unwrapped). Used only while its text is the field's (`fresh`): after an
        /// edit, until the host lays the text out again, the field falls back to `Mono`.
        view: ?moves.View = null,

        /// A field holding `initial` (cut at `cap` bytes, at a code point), caret at its end.
        pub fn init(initial: []const u8) Self {
            var s: Self = .{};
            s.set(initial);
            // No pointer into a value that is about to be copied (`editor` sets it again).
            s.ed.b.buf = &.{};
            return s;
        }

        /// The editor over this value's own bytes.
        pub fn editor(s: *Self) *edit.Editor {
            s.ed.b.buf = &s.bytes;
            return &s.ed;
        }

        /// The text, valid until the next edit.
        pub fn text(s: *Self) []const u8 {
            return s.editor().text();
        }

        /// Replaces the whole text (not recorded for undo), caret at its end.
        pub fn set(s: *Self, str: []const u8) void {
            var n: usize = @min(str.len, cap);
            while (n < str.len and n > 0 and str[n] & 0xc0 == 0x80) n -= 1;
            @memcpy(s.bytes[0..n], str[0..n]);
            const ed = s.editor();
            ed.b.gap = @intCast(n);
            ed.b.after = 0;
            ed.place(@intCast(n));
            ed.preedit = .{ 0, 0 };
            ed.preedit_sel = .{ 0, 0 };
        }
    };
}

/// Whether `T` is a `Text(cap)`.
pub fn isText(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "capacity") and T == Text(T.capacity);
}

/// Why `State`'s field `name` cannot be the text of a `widget` (a `Text(cap)`), or null.
pub fn textError(comptime State: type, comptime widget: []const u8, comptime name: []const u8) ?[]const u8 {
    comptime {
        if (!@hasField(State, name)) return widget ++ " '" ++ name ++ "': the state has no such field";
        const FT = @FieldType(State, name);
        if (isText(FT)) return null;
        return widget ++ " '" ++ name ++ "' needs a textfield.Text(cap) field, not " ++ @typeName(FT);
    }
}

/// Why `State` cannot hold a text field over `name` with its placeholder in string field
/// `hint`, or null when it can.
pub fn bindError(comptime State: type, comptime name: []const u8, comptime hint: []const u8) ?[]const u8 {
    return textError(State, "textfield", name) orelse base.fieldError(State, "textfield placeholder", hint, []const u8);
}

/// A comptime text control's placeholder, taken as `ct.label` takes its text: a literal
/// (`"Your name"`) or a string field (`.name_hint`). Read it with `spec.labelBytes`.
pub fn hintSpec(comptime hint: anytype) Spec {
    return spec_zig.label(hint);
}

/// Why `State` cannot show the placeholder `hint` (`hintSpec`) of `widget`, or null. A literal
/// always can.
pub fn hintError(comptime State: type, comptime widget: []const u8, comptime hint: Spec) ?[]const u8 {
    const f = hint.bind orelse return null;
    return base.fieldError(State, widget ++ " placeholder", f, []const u8);
}

// ---- look -----------------------------------------------------------------------------------

/// Width of one byte of text, px: the front ends measure with `Mono`.
pub fn advance(th: *const Theme) f32 {
    return th.text_px * (Mono{}).advance;
}

/// Height of one line of text, px.
pub fn lineHeight(th: *const Theme) f32 {
    return th.text_px * (Mono{}).line;
}

/// The field's padding: the theme's `pad` across, half of it up and down.
pub fn padding(th: *const Theme) [4]f32 {
    return .{ th.pad, th.pad / 2, th.pad, th.pad / 2 };
}

/// The box: as wide as it is given (at least 80), one line tall, inset (`control_held`), its
/// border the accent while focused; it clips its text, scrolled by `scroll` px. Role text
/// input (ARIA textbox).
pub fn fieldStyle(th: *const Theme, focused: bool, scroll: f32) Style {
    const border = base.OnOff{ th.control_hot, th.accent };
    return .{
        .dir = .x,
        .size = .{ .fill, .fit },
        .min = .{ 80, 0 },
        .pad = padding(th),
        .radius = th.radius,
        .fill = th.control_held,
        .border = 1,
        .border_color = border[@intFromBool(focused)],
        .clip = true,
        .scroll = .{ scroll, 0 },
        .role = .text_input,
    };
}

/// A text control's root `face` (its theme style, or as CSS restyles it) as the control shows
/// itself: the accent border while focused, `face`'s own otherwise. Both front ends build
/// the root through it, so CSS restyles it in both as `spec.styled` does.
pub fn focusFace(th: *const Theme, face: Style, focused: bool) Style {
    const border = base.OnOff{ face.border_color, th.accent };
    var s = face;
    s.border_color = border[@intFromBool(focused)];
    return s;
}

/// The field's root `face` shown focused or not and scrolled `scroll` across (`fieldStyle`
/// over a restyled root).
pub fn fieldFace(th: *const Theme, face: Style, focused: bool, scroll: f32) Style {
    var s = focusFace(th, face, focused);
    s.scroll = .{ scroll, 0 };
    return s;
}

/// The placeholder's colour: the text colour at half strength.
pub fn hintColor(th: *const Theme) Color {
    return .rgba(th.text.r, th.text.g, th.text.b, 128);
}

/// The text, or the placeholder (`hint`) in its colour when the field is empty.
pub fn textStyle(th: *const Theme, hint: bool) TextStyle {
    const colors = base.OnOff{ th.text, hintColor(th) };
    return .{ .px = th.text_px, .color = colors[@intFromBool(hint)] };
}

/// The selection's colour: the accent at less than half strength.
pub fn selectionColor(th: *const Theme) Color {
    return .rgba(th.accent.r, th.accent.g, th.accent.b, 96);
}

/// The selection behind the text, from x `sel[0]` to `sel[1]` px, one line tall.
pub fn selectionStyle(th: *const Theme, sel: [2]f32, top: f32) Style {
    return .{ .float = true, .offset = .{ sel[0], top }, .size = .{ .px(sel[1] - sel[0]), .px(lineHeight(th)) }, .fill = selectionColor(th) };
}

/// The caret: 1 px wide at x `x`, one line tall, in the text colour while focused and
/// invisible otherwise (it keeps its row, so both front ends have the same rows either way).
pub fn caretStyle(th: *const Theme, x: f32, top: f32, focused: bool) Style {
    const colors = base.OnOff{ .transparent, th.text };
    return .{ .float = true, .offset = .{ x, top }, .size = .{ .px(1), .px(lineHeight(th)) }, .fill = colors[@intFromBool(focused)] };
}

/// Selection bands a text field keeps per line, so that its rows are fixed: one per run of
/// one direction the selection covers. A selection crossing more direction changes on a line
/// than this shows only its first `bands` runs.
pub const bands = 4;

/// What a single-line field shows this frame: its text or placeholder, and where the caret and
/// the selection are, px from the text's left edge. `sel` is the selection as one band in
/// `Mono` (the number and search fields draw it); `band` the text field's bands, from `view`
/// when it is fresh, else `sel` and empty bands.
pub const Shown = struct {
    str: []const u8,
    hint: bool,
    caret: f32,
    sel: [2]f32,
    band: [bands][2]f32,
};

pub fn shown(s: anytype, th: *const Theme, hint: []const u8) Shown {
    return shownAs(false, s, th, hint, &.{});
}

/// `shown`, and for a password field (`secure`) its text as one `mask` per grapheme
/// (`Editor.display`, written to `buf`, at least the field's capacity), with the caret and
/// the selection over the mask.
pub fn shownAs(comptime secure: bool, s: anytype, th: *const Theme, hint: []const u8, buf: []u8) Shown {
    const ed = editorAs(secure, s);
    const t = ed.text();
    const adv = advance(th);
    const sel = ed.selection();
    const empty = t.len == 0;
    const mono = [2]f32{ @as(f32, @floatFromInt(shownAt(secure, ed, sel[0]))) * adv, @as(f32, @floatFromInt(shownAt(secure, ed, sel[1]))) * adv };
    var band: [bands][2]f32 = @splat(.{ 0, 0 });
    band[0] = mono;
    if (if (secure) null else fresh(s)) |v| {
        var rects: [bands]Rect = undefined;
        const n = query.selection(v.l, v.g, v.text, sel[0], sel[1], &rects);
        band = @splat(.{ 0, 0 });
        for (rects[0..n], 0..) |r, k| band[k] = .{ r.x0, r.x1 };
    }
    return .{
        .str = if (empty) hint else if (secure) ed.display(buf) else t,
        .hint = empty,
        .caret = caretXAs(secure, s, th, ed.shownCaret()),
        .sel = mono,
        .band = band,
    };
}

/// `s.view` while it is the layout of the field's current text, else null.
pub fn fresh(s: anytype) ?moves.View {
    const v = s.view orelse return null;
    return if (v.l.len > 0 and std.mem.eql(u8, v.text, s.text())) v else null;
}

/// The caret's x at byte `at`, px from the text's left edge: from the view when fresh, else
/// `at` advances.
pub fn caretX(s: anytype, th: *const Theme, at: u32) f32 {
    return caretXAs(false, s, th, at);
}

fn caretXAs(comptime secure: bool, s: anytype, th: *const Theme, at: u32) f32 {
    if (!secure) if (fresh(s)) |v| return v.caretRect(at).x0;
    const shown_at = if (secure) s.editor().toDisplay(at) else at;
    return @as(f32, @floatFromInt(shown_at)) * advance(th);
}

/// Where text offset `at` is in what the field shows: `at`, or in a password its mask's.
fn shownAt(comptime secure: bool, ed: *edit.Editor, at: u32) u32 {
    return if (secure) ed.toDisplay(at) else at;
}

/// What a password field shows once per grapheme of its text: how long it is, nothing else.
/// One byte, so that it is one `Mono` advance and one atlas cell.
pub const mask = "*";

/// The editor of field `s`, in password mode (`Editor.Mode.password`, `mask`) when `secure`.
/// A password's view never matches its text, so it is always laid out as `Mono`.
fn editorAs(comptime secure: bool, s: anytype) *edit.Editor {
    const ed = s.editor();
    if (secure) {
        ed.mode.password = true;
        ed.mode.bullet = mask;
    }
    return ed;
}

// ---- behaviour ------------------------------------------------------------------------------

/// The grapheme boundary of `t` nearest to `x` advances from its start (a click), clamped.
pub fn stopNear(t: []const u8, x: f32) u32 {
    const b: usize = @intFromFloat(std.math.clamp(@round(x), 0, @as(f32, @floatFromInt(t.len))));
    var it: Graphemes = .{ .text = t };
    var last: u32 = 0;
    while (it.next()) |e| {
        if (e > b) break;
        last = @intCast(e);
    }
    return last;
}

/// The scroll that keeps x `x` (the caret) inside a view `view` px wide, moving as little as
/// it can from `scroll`, never past the content's end (`content` px) or its start.
pub fn reveal(scroll: f32, x: f32, view: f32, content: f32) f32 {
    const in_view = @max(@min(scroll, x), x + 1 - view);
    return @max(@min(in_view, content + 1 - view), 0);
}

/// Applies a frame's input to field `s` (a `*Text(cap)`) named `id`, laid out last frame at
/// `last` (zero before the first frame): while the pointer holds the field, the caret follows
/// it (a press also moves the anchor, unless Shift is held); while focused, its keys, typed text
/// and the IME's composition go to the editor (`Editor.update`), with Enter submitting. Then the
/// view scrolls to the caret, and a focused field asks for text input at it. Both front ends
/// call this with what they know of the frame.
pub fn behave(s: anytype, th: *const Theme, id: Id, r: Response, last: Rect, in: *const Input) void {
    behaveAs(false, s, th, id, r, last, in);
}

/// `behave`, for a password field when `secure`: the editor's password mode, so its text is
/// never copied or cut, word moves go to the ends and the host is asked for secure input.
pub fn behaveAs(comptime secure: bool, s: anytype, th: *const Theme, id: Id, r: Response, last: Rect, in: *const Input) void {
    if (secure) _ = editorAs(true, s);
    const ed = pointAs(secure, s, th, r, last, in);
    const k = keyboardOf(in, id, r.focused);
    s.result = ed.update(&k, id, .{ .view = if (secure) null else fresh(s), .clipboard = &s.clipboard, .copy_buf = &s.copied, .composition = k.composition(id, &s.ime) });
    followAs(secure, s, th, r, last);
}

/// The first part of `behave`: resets what the field asks of the host, and places the caret
/// where the pointer holds the field. Returns the single-line editor, for the keys.
pub fn point(s: anytype, th: *const Theme, r: Response, last: Rect, in: *const Input) *edit.Editor {
    return pointAs(false, s, th, r, last, in);
}

fn pointAs(comptime secure: bool, s: anytype, th: *const Theme, r: Response, last: Rect, in: *const Input) *edit.Editor {
    const ed = s.editor();
    ed.mode.single_line = true;
    s.clipboard.reset();
    s.input.reset();
    if (r.held) {
        const x0 = last.x0 + padding(th)[0];
        const px = in.pointer[0] - x0 + s.scroll;
        // A password's mask is one byte per grapheme: the nearest mask boundary, back to text.
        const at = if (secure)
            ed.fromDisplay(@intFromFloat(std.math.clamp(@round(px / advance(th)), 0, @as(f32, @floatFromInt(ed.toDisplay(@intCast(ed.text().len)))))))
        else if (fresh(s)) |v| v.hit(px, v.l.top[0] + v.l.height[0] / 2) else stopNear(ed.text(), px / advance(th));
        ed.caret = at;
        if (!s.held and !in.mods.shift) ed.anchor = at;
        ed.goal = std.math.nan(f32);
        ed.run = .none;
    }
    s.held = r.held;
    return ed;
}

/// The last part of `behave`, after the keys: scrolls the view to the caret, and asks for text
/// input at it while focused.
pub fn follow(s: anytype, th: *const Theme, r: Response, last: Rect) void {
    followAs(false, s, th, r, last);
}

fn followAs(comptime secure: bool, s: anytype, th: *const Theme, r: Response, last: Rect) void {
    const ed = s.editor();
    const adv = advance(th);
    const pad = padding(th);
    const x = caretXAs(secure, s, th, ed.shownCaret());
    const shown_view = if (secure) null else fresh(s);
    const content = if (shown_view) |v| lines_.widest(v.l) else @as(f32, @floatFromInt(shownAt(secure, ed, @intCast(ed.text().len)))) * adv;
    const view = last.w() - pad[0] - pad[2];
    if (view > 0) s.scroll = reveal(s.scroll, x, view, content);
    if (r.focused) {
        const cx = last.x0 + pad[0] - s.scroll + x;
        const top = last.y0 + pad[1];
        s.input.request(.{ .x0 = cx, .y0 = top, .x1 = cx + 1, .y1 = top + lineHeight(th) }, if (secure) .secure else .normal);
    }
}

/// This frame's keys for field `id`: all of them while it is focused, none otherwise.
pub fn keyboardOf(in: *const Input, id: Id, focused: bool) keyboard.Keyboard {
    return .{ .in = in, .target = if (focused) @backingInt(id) else 0, .taken = 0 };
}

/// `Editor.update` for focused field `id` with only event `only` of `in` delivered (none for
/// null), for a widget that handles some keys itself and passes the rest on in order. Only
/// the first 64 events are seen (`Keyboard.taken` is 64 bits).
pub fn feed(ed: *edit.Editor, in: *const Input, id: Id, only: ?usize, cx: edit.Context) edit.Result {
    var first = in.*;
    first.events = in.events[0..@min(in.events.len, 64)];
    const taken: u64 = if (only) |i| ~(@as(u64, 1) << @intCast(i)) else ~@as(u64, 0);
    const k: keyboard.Keyboard = .{ .in = &first, .target = @backingInt(id), .taken = taken };
    return ed.update(&k, id, cx);
}

/// `into` with what `r` did added.
pub fn orResult(into: *edit.Result, r: edit.Result) void {
    into.changed = into.changed or r.changed;
    into.full = into.full or r.full;
    into.copy_full = into.copy_full or r.copy_full;
    into.submitted = into.submitted or r.submitted;
}

// ---- accessibility --------------------------------------------------------------------------

/// The semantics the tree columns cannot carry, for field `name` in either front end's tree:
/// its name is the row `label` (its caption, `aria-labelledby`; `none` for none). The role is
/// in the tree (text input, ARIA textbox); its text and placeholder are `textValue`'s, as the
/// text leaf drawing them is presentational.
pub fn semantics(t: *const Tree, s: *a11y.Semantics, name: Id, label: u32) void {
    const f = t.find(name);
    if (f == types.none or label == types.none) return;
    s.c.labelled_by[f] = label;
}

/// What field `name` (over `field`, a `*Text(cap)`, showing `hint` while empty) holds, for
/// assistive technology: its text and its placeholder, copied to the frame's strings `str`
/// (`a11y.setText`). Call it after building either front end's tree; a field not in `t` is
/// skipped. A password field, when there is one, must not call it: its text is not to be read
/// out.
pub fn textValue(t: *const Tree, s: *a11y.Semantics, str: *Strings, name: Id, field: anytype, hint: []const u8) void {
    const f = t.find(name);
    if (f == types.none) return;
    a11y.setText(s, f, str, field.text(), hint);
}

// ---- runtime front end ----------------------------------------------------------------------

/// A text field named `id` over `s` (a `*Text(cap)`), showing `hint` while empty. Returns its
/// response; what the input did to the text is `s.result`.
pub fn textfield(f: *Frame, th: *const Theme, id: Id, s: anytype, hint: []const u8) Response {
    return fieldAs(false, f, th, id, s, hint, fieldStyle(th, false, 0));
}

/// `textfield` with its root laid out by `face` instead of `fieldStyle(th, false, 0)`, as
/// `spec.styled` restyles `ct.textfield` (CSS on an `<input type=text>`); focus still sets
/// the border and the text still scrolls (`fieldFace`).
pub fn textfieldFace(f: *Frame, th: *const Theme, id: Id, s: anytype, hint: []const u8, face: Style) Response {
    return fieldAs(false, f, th, id, s, hint, face);
}

/// A password field (`<input type=password>`): a text field that shows one `mask` per
/// grapheme, never puts its text on the clipboard and asks for secure input.
pub fn password(f: *Frame, th: *const Theme, id: Id, s: anytype, hint: []const u8) Response {
    return fieldAs(true, f, th, id, s, hint, fieldStyle(th, false, 0));
}

/// `password` with its root laid out by `face`, as `textfieldFace`.
pub fn passwordFace(f: *Frame, th: *const Theme, id: Id, s: anytype, hint: []const u8, face: Style) Response {
    return fieldAs(true, f, th, id, s, hint, face);
}

fn fieldAs(comptime secure: bool, f: *Frame, th: *const Theme, id: Id, s: anytype, hint: []const u8, face: Style) Response {
    const r0 = f.ctx.inter.response(id);
    behaveAs(secure, s, th, id, r0, f.lastRect(id), f.in);
    platform(f, s);
    const node = f.open(id, fieldFace(th, face, r0.focused, s.scroll));
    const r = f.interact(node, types.Sense.any);
    f.setCursor(.text, r.hovered);
    var buf: [if (secure) @TypeOf(s.*).capacity else 0]u8 = undefined;
    const v = shownAs(secure, s, th, hint, &buf);
    for (v.band) |b| _ = f.leaf(.none, selectionStyle(th, b, 0));
    _ = f.textStyled(v.str, textStyle(th, v.hint), .{});
    _ = f.leaf(.none, caretStyle(th, v.caret, 0, r0.focused));
    f.close();
    return r;
}

/// Copies what field `s` asks of the host this frame to the runtime front end's `Platform`:
/// text input with its purpose and, but for a password, the text and selection around the
/// caret for the IME and autocorrect; the clipboard text it copied, and a paste.
pub fn platform(f: *Frame, s: anytype) void {
    const p = &f.ctx.platform;
    if (s.input.wants_text) {
        p.wants_text = true;
        p.ime_rect = s.input.rect;
        p.purpose = s.input.purpose;
        const ed = s.editor();
        const open = s.input.purpose != .secure;
        p.surrounding = if (open) ed.text() else "";
        p.selection = if (open) .{ ed.anchor, ed.caret } else .{ 0, 0 };
    }
    if (s.clipboard.set.len > 0) p.clipboard = s.clipboard.set;
    p.paste = p.paste or s.clipboard.paste;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A text field named `id` over the `Text(cap)` field `bind`, showing `hint` while empty:
    /// a literal or a string field (`hintSpec`). Its events carry the `edit.Result` of a frame
    /// that changed the text or submitted it.
    pub fn textfield(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime hint: anytype) Spec {
        const band: [bands]Spec = @splat(.{ .kind = .col });
        var s = spec_zig.row(fieldStyle(&th, false, 0), band ++ [2]Spec{ .{ .kind = .label }, .{ .kind = .col } });
        s.id = @tagName(id);
        s.bind = @tagName(bind);
        s.widget = Comptime(@tagName(id), @tagName(bind), hintSpec(hint), false);
        return s;
    }

    /// `textfield` as a password field (`password`).
    pub fn password(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime hint: anytype) Spec {
        var s = ct.textfield(th, id, bind, hint);
        s.widget = Comptime(@tagName(id), @tagName(bind), hintSpec(hint), true);
        return s;
    }
};

/// The comptime text field named `name` over field `bind`, placeholder `hint` (`hintSpec`)
/// (`Spec.widget`): the same rows as `textfield`, and the same input applied (`behave`).
pub fn Comptime(comptime name: [:0]const u8, comptime bind: []const u8, comptime hint: Spec, comptime secure: bool) type {
    return struct {
        pub const focusable = true;
        pub const Payload = edit.Result;

        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            return textError(State, "textfield", field) orelse hintError(State, "textfield", hint);
        }

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            _ = in;
            const Ui = @TypeOf(ui.*);
            const th = &Ui.theme;
            const s = &@field(ui.signals.state, bind);
            const focused = ui.focus == @field(Ui.Events.Widget, name);
            const t = &ui.tables.t;
            next.* += bands + 3; // the box, the selection bands, the text and the caret
            const i = t.push(parent, .hash(name), &fieldFace(th, n.style, focused, s.scroll));
            var buf: [if (secure) @TypeOf(s.*).capacity else 0]u8 = undefined;
            const v = shownAs(secure, s, th, spec_zig.labelBytes(hint, &ui.signals.state), &buf);
            for (v.band) |b| _ = t.push(i, .none, &selectionStyle(th, b, 0));
            pushText(ui, i, v.str, textStyle(th, v.hint));
            _ = t.push(i, .none, &caretStyle(th, v.caret, 0, focused));
            t.seal(i);
        }

        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) @TypeOf(event) {
            const Ui = @TypeOf(ui.*);
            const r = base.ctResponse(ui, row, event, in);
            const last: Rect = ui.lastRect(row);
            const s = &@field(ui.signals.state, bind);
            behaveAs(secure, s, &Ui.theme, .hash(name), r, last, in);
            if (!(s.result.changed or s.result.submitted)) return null;
            return @unionInit(Ui.Events.Event, name, s.result);
        }
    };
}

const textfield_zig = @This();

/// Pushes a text leaf showing `str` under row `parent` of comptime front end `ui`, as
/// `Frame.textStyled(str, ts, .{})` does in the runtime front end.
pub fn pushText(ui: anytype, parent: u32, str: []const u8, ts: TextStyle) void {
    const tb = &ui.tables;
    const k = tb.t.push(parent, .none, &.{});
    tb.t.c.text[k] = tb.tx.push(k, tb.strings.add(str), &ts);
}

// ---- example page -------------------------------------------------------------------------

/// The text field's example page: Name (empty, placeholder "Your name") and City ("Oslo"), each
/// under its caption, on a panel, in both front ends.
pub const Page = struct {
    const th = Theme.default;
    const panel: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(12), .gap = 8, .fill = th.panel };
    pub const Field = Text(64);

    pub const App = struct {
        name: Field = .{},
        city: Field = .init("Oslo"),
        submits: u32 = 0,
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.from("panel"), panel);
            _ = base.label(f, &th, "Name");
            _ = textfield(f, &th, .from("name"), &app.name, "Your name");
            _ = base.label(f, &th, "City");
            _ = textfield(f, &th, .from("city"), &app.city, "");
            app.submits += @intFromBool(app.name.result.submitted) + @intFromBool(app.city.result.submitted);
            f.close();
        }
    };
    pub const State = struct {
        name_text: []const u8 = "Name",
        name: Field = .{},
        name_hint: []const u8 = "Your name",
        city_text: []const u8 = "City",
        city: Field = .init("Oslo"),
        city_hint: []const u8 = "",
    };
    pub const spec = spec_zig.col(panel, .{
        base.ct.label(th, .name_text),
        ct.textfield(th, .name, .name, .name_hint),
        base.ct.label(th, .city_text),
        ct.textfield(th, .city, .city, .city_hint),
    });
    pub const Ui = base.ComptimeUi(State, spec, th);
    pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 4, .customs = 1, .strings = 512, .depth = 8 });
    pub const replay = @embedFile("testdata/textfield.replay");
    /// Frames kept as golden images, by name: tools/golden/ref/widgets/textfield-<name>.png.
    pub const golden_frames = .{ .{ "rest", 0 }, .{ "typed", 2 }, .{ "selected", 3 }, .{ "drag", 8 } };
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

/// Rows of a text field below its box: the bands, then the text, then the caret.
const text_row = 1 + bands;
const caret_row = 2 + bands;

test "Text: init, set and the editor over the value's own bytes, after a move" {
    var a: Text(8) = .init("hello");
    var b = a; // moved: the editor follows the bytes
    try testing.expectEqualStrings("hello", b.text());
    try testing.expectEqual(@as(u32, 5), b.ed.caret);
    b.set("too long for eight");
    try testing.expectEqualStrings("too long", b.text());
    a.set("");
    try testing.expectEqualStrings("", a.text());
    // Cut at a code point: "é" is two bytes and does not fit after seven.
    var c: Text(8) = .init("abcdefg\u{e9}");
    try testing.expectEqualStrings("abcdefg", c.text());
}

test "bindError: a text field binds a Text(cap) and a string placeholder" {
    const State = struct { t: Text(4) = .{}, n: u32 = 0, hint: []const u8 = "" };
    try testing.expectEqual(null, comptime bindError(State, "t", "hint"));
    try testing.expectEqualStrings("textfield 'n' needs a textfield.Text(cap) field, not u32", comptime bindError(State, "n", "hint").?);
    try testing.expectEqualStrings("textfield 'x': the state has no such field", comptime bindError(State, "x", "hint").?);
    try testing.expectEqualStrings("textfield placeholder 'n' needs a []const u8 field, not u32", comptime bindError(State, "t", "n").?);
    try testing.expect(isText(Text(4)));
    try testing.expect(!isText(struct {
        pub const capacity = 4;
    }));
}

test "ct.textfield, ct.search, ct.textarea: a literal placeholder draws as the same text in a field" {
    const th = Theme.default;
    const search = @import("search.zig");
    const textarea = @import("textarea.zig");
    const Lit = struct { a: Text(16) = .{}, b: Text(16) = .{}, c: Text(16) = .{} };
    const Bound = struct { a: Text(16) = .{}, b: Text(16) = .{}, c: Text(16) = .{}, h: []const u8 = "Your name" };
    const lit = comptime spec_zig.col(.{}, .{ ct.textfield(th, .a, .a, "Your name"), search.ct.search(th, .b, .b, "Your name"), textarea.ct.textarea(th, .c, .c, 2, "Your name") });
    const bound = comptime spec_zig.col(.{}, .{ ct.textfield(th, .a, .a, .h), search.ct.search(th, .b, .b, .h), textarea.ct.textarea(th, .c, .c, 2, .h) });
    try testing.expectEqual(null, comptime hintError(Lit, "textfield", hintSpec("Your name")));
    try testing.expectEqualStrings("textfield placeholder 'h': the state has no such field", comptime hintError(Lit, "textfield", hintSpec(.h)).?);
    const S = struct {
        var a: base.ComptimeUi(Lit, lit, th) = .{};
        var b: base.ComptimeUi(Bound, bound, th) = .{};
    };
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const x = S.a.frame(&in);
    const y = S.b.frame(&in);
    try testing.expect(base.sameDraw(x.draw, y.draw));
    try testing.expect(std.mem.count(u8, x.draw.strings, "Your name") == 3);
}

test "ct.textfield: a focusable widget whose events carry an edit.Result" {
    const E = Page.Ui.Events;
    try testing.expectEqual(2, E.widget_count);
    try testing.expectEqual(edit.Result, @FieldType(E.Event, "name"));
    try testing.expectEqualSlices(E.Widget, &.{ .name, .city }, E.focus_order);
}

var page: Page.Run = .{};

test "textfield: the page agrees in both front ends at rest" {
    const h = &page;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 140 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    // root, panel, two captions, two fields of a box, the bands, a text and a caret each.
    try testing.expectEqual(@as(u32, 1 + 1 + 2 + 2 * (bands + 3)), t.len);
    try testing.expectEqual(@backingInt(types.Role.text_input), t.c.role[t.find(.from("name"))]);
}

test "textfield look: an inset box one line tall, the placeholder dimmed, the caret only while focused" {
    const h = &page;
    h.init();
    const th = Theme.default;
    var in: Input = .{ .viewport = .{ 320, 140 } };
    var out = try h.frame(&in);
    var t = out.runtime.tree;
    const f = t.find(.from("name"));
    const box = t.rect(f);
    // Laid out to whole pixels.
    try testing.expectApproxEqAbs(lineHeight(&th) + th.pad, box.h(), 0.5);
    try testing.expectEqual(@as(f32, 320 - 24), box.w());
    try testing.expectEqual(th.control_held.bitsOf(), t.c.look[f].fill);
    try testing.expectEqual(th.control_hot.bitsOf(), t.c.look[f].border_color);
    // The placeholder, in the hint colour; City's text in the text colour.
    const tx = out.runtime.texts;
    try testing.expectEqual(hintColor(&th).bitsOf(), tx.c.color[t.c.text[f + text_row]]);
    const c = t.find(.from("city"));
    try testing.expectEqual(th.text.bitsOf(), tx.c.color[t.c.text[c + text_row]]);
    try testing.expectApproxEqAbs(4 * advance(&th), t.rect(c + text_row).w(), 0.5);
    // The caret is there but clear; no selection.
    try testing.expectEqual(Color.transparent.bitsOf(), t.c.look[f + caret_row].fill);
    try testing.expectEqual(@as(f32, 0), t.rect(f + 1).w());
    // Focused: the accent border, and the caret drawn at the editor's caret.
    in.pointer = .{ box.x0 + 4, (t.rect(c).y0 + t.rect(c).y1) * 0.5 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    in.buttons.left = false;
    in.pointer = .{ 0, 0 };
    out = try h.frame(&in);
    t = out.runtime.tree;
    try testing.expectEqual(th.accent.bitsOf(), t.c.look[c].border_color);
    try testing.expectEqual(th.text.bitsOf(), t.c.look[c + caret_row].fill);
    const at: f32 = @floatFromInt(h.app.city.ed.caret);
    try testing.expectApproxEqAbs(t.rect(c).x0 + th.pad + at * advance(&th), t.rect(c + caret_row).x0, 0.5);
    try testing.expectEqual(@as(f32, 1), t.rect(c + caret_row).w());
}

var field_semantics: base.Semantic(32) = .{};

test "textfield a11y: role text input named by its caption; text and caret presentational" {
    const h = &page;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 140 } };
    const out = try h.frame(&in);
    const x = &field_semantics;
    try x.run(h);
    const t = out.runtime.tree;
    const f = t.find(.from("name"));
    const r = x.row(f).?;
    try testing.expectEqual(@backingInt(a11y.Role.text_input), x.out[0].c.role[r]);
    try testing.expectEqual(@backingInt(Id.from("name")), x.out[0].c.id[r]);
    try testing.expectEqual(@as(u8, 0), x.out[0].c.state[r]);
    // Selection, text and caret are not exported.
    for (1..bands + 3) |k| try testing.expectEqual(null, x.row(f + @as(u32, @intCast(k))));
    // Named by its caption through `semantics`, in either front end's tree.
    const check = @import("check.zig");
    const ctx = &h.ctx;
    const tb = &h.ui.tables;
    const trees = [2]*const Tree{ t, &tb.t };
    const txs = [2]*const @import("../core/texts.zig").Texts{ out.runtime.texts, &tb.tx };
    const strs = [2][]const u8{ ctx.strings[ctx.cur].buf[0..ctx.strings[ctx.cur].len], tb.strings.buf[0..tb.strings.len] };
    for (trees, txs, strs) |tree, tx, str| {
        var sb: check.SemBuf = .{};
        var sem = sb.init();
        semantics(tree, &sem, .from("name"), f - 1);
        a11y.names(tree, &sem);
        try testing.expectEqualStrings("Name", check.nameOf(&sem, tx, str, f));
    }
}

var field_content: [2]@import("popover.zig").Semantic(64) = .{ .{}, .{} };

test "textfield a11y: its text and placeholder, in both front ends" {
    const popover = @import("popover.zig");
    const h = &page;
    h.init();
    _ = try h.frame(&.{ .viewport = .{ 320, 140 } });
    const tb = &h.ui.tables;
    const ctx = &h.ctx;
    const trees = [2]*const Tree{ &ctx.trees[ctx.cur], &tb.t };
    const strs = [2]*Strings{ &ctx.strings[ctx.cur], &tb.strings };
    const st = &h.ui.signals.state;
    for (trees, strs, &field_content, 0..) |t, str, *x, k| {
        const sem = x.begin();
        const fields = [2]*Page.Field{ if (k == 0) &h.app.name else &st.name, if (k == 0) &h.app.city else &st.city };
        textValue(t, sem, str, .from("name"), fields[0], "Your name");
        textValue(t, sem, str, .from("city"), fields[1], "");
    }
    const e = field_content[0].finish(trees[0], &ctx.texts[ctx.cur], strs[0].buf);
    const c = field_content[1].finish(trees[1], &tb.tx, strs[1].buf);
    try testing.expect(popover.sameSemantics(e, c));
    const span = struct {
        fn of(str: *const Strings, sp: @import("../core/strings.zig").Span) []const u8 {
            return str.buf[sp.start..][0..sp.bytes];
        }
    }.of;
    const name = popover.exportRow(e, trees[0].find(.from("name")));
    const city = popover.exportRow(e, trees[0].find(.from("city")));
    for ([2]*const a11y.Export{ e, c }, strs) |x, str| {
        try testing.expectEqualStrings("", span(str, x.c.text[name]));
        try testing.expectEqualStrings("Your name", span(str, x.c.hint[name]));
        try testing.expectEqualStrings("Oslo", span(str, x.c.text[city]));
        try testing.expectEqualStrings("", span(str, x.c.hint[city]));
    }
}

fn press(code: u8, mods: Input.Mods) Input.Event {
    return .{ .kind = .press, .code = code, .mods = mods };
}

/// Runs `in` through `h` and checks that both front ends' fields hold the same text, caret,
/// anchor and scroll.
fn both(h: *Page.Run, in: *const Input) !Page.Run.Pair {
    const out = try h.frame(in);
    const st = &h.ui.signals.state;
    inline for (.{ "name", "city" }) |f| {
        const a = &@field(h.app, f);
        const b = &@field(st, f);
        try testing.expectEqualStrings(a.text(), b.text());
        try testing.expectEqual([3]u32{ a.ed.caret, a.ed.anchor, @intFromBool(a.result.submitted) }, [3]u32{ b.ed.caret, b.ed.anchor, @intFromBool(b.result.submitted) });
        try testing.expectEqual(a.scroll, b.scroll);
        try testing.expectEqual(a.input, b.input);
    }
    return out;
}

test "textfield input: click to focus, type, select by drag and keys, Enter, in both front ends" {
    const h = &page;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 140 } };
    var out = try both(h, &in);
    const t = out.runtime.tree;
    const name = t.rect(t.find(.from("name")));
    const city = t.rect(t.find(.from("city")));
    const adv = advance(&Theme.default);
    const y = (name.y0 + name.y1) * 0.5;
    // Keys before the field is focused go nowhere.
    var txt = "ab".*;
    const typed = [_]Input.Event{.{ .kind = .text, .at = 0, .len = 2 }};
    in.text = &txt;
    in.events = &typed;
    _ = try both(h, &in);
    try testing.expectEqualStrings("", h.app.name.text());
    // Press on Name: focused, the host is asked for text at the caret.
    in.events = &.{};
    in.pointer = .{ name.x0 + 40, y };
    in.buttons.left = true;
    out = try both(h, &in);
    try testing.expect(out.runtime.platform.wants_text);
    try testing.expectEqual(name.x0 + Theme.default.pad, out.runtime.platform.ime_rect.x0);
    in.buttons.left = false;
    _ = try both(h, &in);
    // Type "hello world"; Enter submits and inserts nothing.
    var hello = "hello world".*;
    const ev = [_]Input.Event{ .{ .kind = .text, .at = 0, .len = 11 }, press(0x28, .{}) };
    in.text = &hello;
    in.events = &ev;
    out = try both(h, &in);
    try testing.expectEqualStrings("hello world", h.app.name.text());
    try testing.expect(h.app.name.result.submitted);
    try testing.expectEqual(@as(?Page.Ui.Events.Event, .{ .name = .{ .changed = true, .submitted = true } }), out.comptime_.event);
    try testing.expectEqual(name.x0 + Theme.default.pad + 11 * adv, out.runtime.platform.ime_rect.x0);
    // The IME is told the field's text and caret.
    try testing.expectEqualStrings("hello world", out.runtime.platform.surrounding);
    try testing.expectEqual([2]u32{ 11, 11 }, out.runtime.platform.selection);
    // Shift+Home selects to the start; Shift+Right then Right collapse.
    const sel = [_]Input.Event{ press(0x4a, .{ .shift = true }), press(0x4f, .{ .shift = true }) };
    in.events = &sel;
    in.text = "";
    _ = try both(h, &in);
    try testing.expectEqual([2]u32{ 1, 11 }, h.app.name.ed.selection());
    // Ctrl+C copies the selection for the host.
    const copy = [_]Input.Event{press(0x06, .{ .ctrl = true })};
    in.events = &copy;
    out = try both(h, &in);
    try testing.expectEqualStrings("ello world", h.app.name.clipboard.set);
    try testing.expectEqualStrings("ello world", out.runtime.platform.clipboard);
    // Ctrl+V asks the host for the clipboard's text.
    const paste = [_]Input.Event{press(0x19, .{ .ctrl = true })};
    in.events = &paste;
    out = try both(h, &in);
    try testing.expect(out.runtime.platform.paste);
    in.events = &.{};
    // Drag from the 2nd byte to the 5th: "llo" selected, caret at 5.
    in.pointer = .{ name.x0 + Theme.default.pad + 2 * adv, y };
    in.buttons.left = true;
    _ = try both(h, &in);
    in.pointer[0] += 3 * adv;
    _ = try both(h, &in);
    in.buttons.left = false;
    _ = try both(h, &in);
    try testing.expectEqual([2]u32{ 2, 5 }, h.app.name.ed.selection());
    try testing.expectEqual(@as(u32, 5), h.app.name.ed.caret);
    // Backspace removes it.
    const bs = [_]Input.Event{press(0x2a, .{})};
    in.events = &bs;
    _ = try both(h, &in);
    try testing.expectEqualStrings("he world", h.app.name.text());
    // Clicking City moves focus: Name's keys stop, City's caret goes to the click.
    in.events = &.{};
    in.pointer = .{ city.x0 + Theme.default.pad + 1.2 * adv, (city.y0 + city.y1) * 0.5 };
    in.buttons.left = true;
    _ = try both(h, &in);
    in.buttons.left = false;
    in.events = &bs;
    _ = try both(h, &in);
    try testing.expectEqualStrings("slo", h.app.city.text());
    try testing.expectEqualStrings("he world", h.app.name.text());
}

test "textfield input: the IME's composition shows at the caret until it commits" {
    const h = &page;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 140 } };
    const out = try both(h, &in);
    const t = out.runtime.tree;
    const city = t.rect(t.find(.from("city")));
    in.pointer = .{ city.x1 - 2, (city.y0 + city.y1) * 0.5 };
    in.buttons.left = true;
    _ = try both(h, &in);
    in.buttons.left = false;
    h.app.city.ime = .{ .text = "ka", .range = .{ 0, 2 } };
    h.ui.signals.state.city.ime = h.app.city.ime;
    _ = try both(h, &in);
    try testing.expectEqualStrings("Osloka", h.app.city.text());
    try testing.expect(h.app.city.ed.composing());
    // Committed as typed text: the preedit leaves, the text stays.
    h.app.city.ime = .{};
    h.ui.signals.state.city.ime = .{};
    var ka = "\u{304b}".*;
    const ev = [_]Input.Event{.{ .kind = .text, .at = 0, .len = ka.len }};
    in.text = &ka;
    in.events = &ev;
    _ = try both(h, &in);
    try testing.expectEqualStrings("Oslo\u{304b}", h.app.city.text());
    try testing.expect(!h.app.city.ed.composing());
}

test "textfield input: a long text scrolls to keep the caret in view" {
    const S = struct {
        var h: Page.Run = .{};
    };
    const h = &S.h;
    h.init();
    var in: Input = .{ .viewport = .{ 160, 140 } };
    const out = try both(h, &in);
    const t = out.runtime.tree;
    const name = t.rect(t.find(.from("name")));
    in.pointer = .{ name.x0 + 4, (name.y0 + name.y1) * 0.5 };
    in.buttons.left = true;
    _ = try both(h, &in);
    in.buttons.left = false;
    var long = "abcdefghijklmnopqrstuvwxyz0123456789".*;
    const ev = [_]Input.Event{.{ .kind = .text, .at = 0, .len = long.len }};
    in.text = &long;
    in.events = &ev;
    _ = try both(h, &in);
    const th = Theme.default;
    const view = name.w() - 2 * th.pad;
    const end = 36 * advance(&th);
    try testing.expectEqual(end + 1 - view, h.app.name.scroll);
    // Home scrolls back to the start.
    in.text = "";
    const home = [_]Input.Event{press(0x4a, .{})};
    in.events = &home;
    _ = try both(h, &in);
    try testing.expectEqual(@as(f32, 0), h.app.name.scroll);
}

/// A host's layout of a text as text/layout draws it, reordered, one `adv` per code point, one
/// line per line between newlines: what a host hands over as `Text.view`. For `text` (a
/// left-to-right paragraph with a Hebrew word in it) the glyphs sit at a b c _ ג ב א _ d e f,
/// so "c" and the space before the Hebrew word are one run on screen and "א" another, at the
/// word's right end.
pub const Mixed = struct {
    pub const text = "abc \u{5D0}\u{5D1}\u{5D2} def";
    para: @import("../text/layout/golden.zig").Para = .{},
    raw: [8 * 1024]u8 align(@import("../core/mem.zig").column_align) = undefined,

    /// Lays `str` out; `m` must not move afterwards (the view points into it).
    pub fn view(m: *Mixed, str: []const u8, adv: f32, line: f32) !moves.View {
        var carver: @import("../core/mem.zig").Carver = .{ .buf = &m.raw };
        const scratch = carver.columns(lines_.BidiScratch, 32);
        const p = &m.para;
        p.fixed(str, adv);
        try lines_.breakLines(&p.g, str, std.math.inf(f32), &p.l);
        const a: lines_.Align = .{ .width = @as(f32, @floatFromInt(p.g.len)) * adv };
        lines_.place(&p.l, &p.g, str, &.{.{ .ascent = line * 0.8, .descent = line * 0.2 }}, a);
        try lines_.reorder(&p.l, &p.g, str, a, scratch);
        return .{ .l = &p.l, .g = &p.g, .text = str };
    }
};

var mixed: Mixed = .{};

test "textfield view: a mixed-direction line selects one band per run and clicks on its layout" {
    const h = &page;
    h.init();
    const th = Theme.default;
    const adv = advance(&th);
    var in: Input = .{ .viewport = .{ 320, 140 } };
    var out = try both(h, &in);
    const c = out.runtime.tree.find(.from("city"));
    const box = out.runtime.tree.rect(c);
    const v = try mixed.view(Mixed.text, adv, lineHeight(&th));
    // "c" and the space, then "א": bytes 2 to 6.
    for ([2]*Page.Field{ &h.app.city, &h.ui.signals.state.city }) |f| {
        f.set(Mixed.text);
        f.view = v;
        f.ed.anchor = 2;
        f.ed.caret = 6;
    }
    out = try both(h, &in);
    var t = out.runtime.tree;
    const x0 = box.x0 + th.pad;
    // Laid out to whole pixels: within one of the exact place.
    try testing.expectApproxEqAbs(x0 + 2 * adv, t.rect(c + 1).x0, 1);
    try testing.expectApproxEqAbs(2 * adv, t.rect(c + 1).w(), 1);
    try testing.expectApproxEqAbs(x0 + 6 * adv, t.rect(c + 2).x0, 1);
    try testing.expectApproxEqAbs(adv, t.rect(c + 2).w(), 1);
    try testing.expectEqual(@as(f32, 0), t.rect(c + 3).w());
    try testing.expectEqual(@as(f32, 0), t.rect(c + 4).w());
    // Without the view (Mono): one band, bytes 2 to 6.
    for ([2]*Page.Field{ &h.app.city, &h.ui.signals.state.city }) |f| f.view = null;
    out = try both(h, &in);
    t = out.runtime.tree;
    try testing.expectApproxEqAbs(4 * adv, t.rect(c + 1).w(), 1);
    try testing.expectEqual(@as(f32, 0), t.rect(c + 2).w());
    // A click near the right edge of "א" lands where the layout puts its logical start (4),
    // and the caret is drawn there, at the word's right end.
    for ([2]*Page.Field{ &h.app.city, &h.ui.signals.state.city }) |f| f.view = v;
    const want = v.hit(6.8 * adv, 1);
    try testing.expectEqual(@as(u32, 4), want);
    in.pointer = .{ x0 + 6.8 * adv, (box.y0 + box.y1) * 0.5 };
    in.buttons.left = true;
    _ = try both(h, &in);
    in.buttons.left = false;
    out = try both(h, &in);
    try testing.expectEqual(want, h.app.city.ed.caret);
    t = out.runtime.tree;
    try testing.expectApproxEqAbs(x0 + v.caretRect(4).x0, t.rect(c + caret_row).x0, 1);
    try testing.expectApproxEqAbs(x0 + 7 * adv, t.rect(c + caret_row).x0, 1);
    // An edit makes the view stale: the field falls back to Mono until the host lays it out.
    var z = "z".*;
    const ev = [_]Input.Event{.{ .kind = .text, .at = 0, .len = 1 }};
    in.text = &z;
    in.events = &ev;
    out = try both(h, &in);
    try testing.expectEqual(null, fresh(&h.app.city));
    t = out.runtime.tree;
    try testing.expectApproxEqAbs(x0 + 5 * adv, t.rect(c + caret_row).x0, 1);
}

test "Page: the text field replay types, selects and submits, in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &page;
    h.init();
    var text: [32]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = Page.replay };
    const Want = struct { name: []const u8, city: []const u8, sel: [2]u32 };
    const want = [_]Want{
        .{ .name = "", .city = "Oslo", .sel = .{ 0, 0 } },
        .{ .name = "", .city = "Oslo", .sel = .{ 0, 0 } },
        .{ .name = "Ada Lovelace", .city = "Oslo", .sel = .{ 12, 12 } },
        .{ .name = "Ada Lovelace", .city = "Oslo", .sel = .{ 0, 12 } },
        .{ .name = "Grace", .city = "Oslo", .sel = .{ 5, 5 } },
        .{ .name = "Grace", .city = "Oslo", .sel = .{ 3, 3 } },
        .{ .name = "Grace", .city = "Oslo", .sel = .{ 3, 3 } },
        .{ .name = "Grace", .city = "Oslo", .sel = .{ 2, 2 } },
        .{ .name = "Grace", .city = "Oslo", .sel = .{ 2, 4 } },
        .{ .name = "Grace", .city = "Os", .sel = .{ 2, 2 } },
        .{ .name = "Grace", .city = "Osaka", .sel = .{ 5, 5 } },
    };
    while (try replay.next(buf)) |in| {
        const k = h.frames;
        const out = try both(h, in);
        try testing.expectEqualStrings(want[k].name, h.app.name.text());
        try testing.expectEqualStrings(want[k].city, h.app.city.text());
        const focused = if (k < 7) &h.app.name else &h.app.city;
        try testing.expectEqual(want[k].sel, focused.ed.selection());
        try testing.expectEqual(k >= 1, out.runtime.platform.wants_text);
        try testing.expectEqual(@as(u32, @intFromBool(k >= 6)), h.app.submits);
    }
    try testing.expectEqual(@as(u32, 11), h.frames);
    const t = &h.ctx.trees[h.ctx.cur];
    // The rects the replay's comment gives.
    try testing.expectEqual(Rect{ .x0 = 12, .y0 = 38, .x1 = 308, .y1 = 63 }, t.rect(t.find(.from("name"))));
    try testing.expectEqual(Rect{ .x0 = 12, .y0 = 97, .x1 = 308, .y1 = 122 }, t.rect(t.find(.from("city"))));
    inline for (Page.golden_frames) |g| try testing.expect(g[1] < 11);
}

/// One password field, in both front ends.
const Secret = struct {
    const th = Theme.default;
    const panel: Style = .{ .size = .{ .fill, .fill }, .pad = @splat(12), .fill = th.panel };
    pub const App = struct {
        pin: Text(16) = .{},
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.from("panel"), panel);
            _ = password(f, &th, .from("pin"), &app.pin, "PIN");
            f.close();
        }
    };
    pub const State = struct { pin: Text(16) = .{} };
    pub const spec = spec_zig.col(panel, .{ct.password(th, .pin, .pin, "PIN")});
    pub const Ui = base.ComptimeUi(State, spec, th);
    pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 2, .customs = 1, .strings = 256, .depth = 4 });
};

var secret: Secret.Run = .{};

test "password: one mask per grapheme, never copied, secure input, in both front ends" {
    const h = &secret;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 80 } };
    var out = try h.frame(&in);
    const t = out.runtime.tree;
    const box = t.rect(t.find(.from("pin")));
    const adv = advance(&Theme.default);
    const x0 = box.x0 + Theme.default.pad;
    in.pointer = .{ box.x0 + 4, (box.y0 + box.y1) * 0.5 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    in.buttons.left = false;
    // "é" is two bytes and "e\u{301}" one grapheme of three: four graphemes in all.
    var typed = "p\u{e9}e\u{301}x".*;
    const ev = [_]Input.Event{.{ .kind = .text, .at = 0, .len = typed.len }};
    in.text = &typed;
    in.events = &ev;
    out = try h.frame(&in);
    try testing.expectEqualStrings("p\u{e9}e\u{301}x", h.app.pin.text());
    try testing.expectEqualStrings(h.app.pin.text(), h.ui.signals.state.pin.text());
    const dl = out.runtime.draw;
    try testing.expectEqualStrings("****", dl.strings[dl.runs[0].start..][0..dl.runs[0].bytes]);
    // The caret after the fourth mask; the host is asked for secure input, told no text.
    try testing.expectEqual(x0 + 4 * adv, out.runtime.platform.ime_rect.x0);
    try testing.expectEqual(keyboard.Purpose.secure, out.runtime.platform.purpose);
    try testing.expectEqualStrings("", out.runtime.platform.surrounding);
    // Select all and copy: nothing reaches the clipboard.
    const copy = [_]Input.Event{ press(0x04, .{ .ctrl = true }), press(0x06, .{ .ctrl = true }) };
    in.text = "";
    in.events = &copy;
    out = try h.frame(&in);
    try testing.expectEqualStrings("", h.app.pin.clipboard.set);
    try testing.expectEqualStrings("", out.runtime.platform.clipboard);
    // A click between the second and third masks puts the caret after "pé", byte 3.
    in.events = &.{};
    in.pointer = .{ x0 + 2.2 * adv, in.pointer[1] };
    in.buttons.left = true;
    _ = try h.frame(&in);
    in.buttons.left = false;
    _ = try h.frame(&in);
    try testing.expectEqual(@as(u32, 3), h.app.pin.ed.caret);
    try testing.expectEqual(@as(u32, 3), h.ui.signals.state.pin.ed.caret);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
