//! Text editing: a buffer and a caret driven by the keyboard input of one widget. Tier 0.
//!
//! The editing state belongs to the application, as DVUI's text entry keeps its text in a
//! caller's buffer: `Editor` is a plain struct over bytes the caller owns, and `update` applies
//! one frame of the focused widget's input (src/interact/keyboard.zig) to it. Nothing is
//! retained between frames but the struct itself, and the caller decides when to lay the text
//! out again (src/text/layout/) and where to draw it.

const std = @import("std");
const types = @import("../../core/types.zig");
const Input = @import("../../core/input.zig").Input;
const keyboard = @import("../../interact/keyboard.zig");
const Buffer = @import("buffer.zig").Buffer;
const moves = @import("moves.zig");
const History = @import("history.zig").History;
const Graphemes = @import("../unicode/grapheme.zig").Graphemes;

const Id = types.Id;
const Keyboard = keyboard.Keyboard;
const Interaction = @import("../../interact/interaction.zig").Interaction;

/// The keys the editor reads, as USB HID scancodes (`Input.Keys`).
pub const Keys = struct {
    backspace: u8 = 0x2a,
    delete: u8 = 0x4c,
    enter: u8 = 0x28,
    keypad_enter: u8 = 0x58,
    left: u8 = 0x50,
    right: u8 = 0x4f,
    up: u8 = 0x52,
    down: u8 = 0x51,
    home: u8 = 0x4a,
    end: u8 = 0x4d,
    /// Held with Left, Right, Backspace or Delete, moves and deletes by word; with Home and End,
    /// to the text's start and end. Ctrl on Windows and Linux; a macOS host sets `.alt` (and
    /// maps Cmd+Left and Right to Home and End itself).
    word: Input.Mods = .{ .ctrl = true },
    /// Select all, cut, copy and paste, as `Keyboard.commands` reads them.
    clipboard: keyboard.ClipboardKeys = .{},
    /// Undo, and redo, with `clipboard.mods`; undo with Shift added also redoes.
    undo: u8 = 0x1d,
    redo: u8 = 0x1c,
};

/// The pointer over the editor this frame, in px from the laid-out paragraph's top left.
pub const Pointer = struct {
    at: [2]f32 = .{ 0, 0 },
    /// The left button went down on the editor: the caret goes there.
    press: bool = false,
    /// The button is held since a press on the editor: the caret follows, the anchor stays.
    held: bool = false,
    /// A double click on the editor: the word under the pointer is selected.
    double: bool = false,
    /// Shift was held: a press extends the selection instead of starting one.
    shift: bool = false,

    /// The pointer for widget `id` from this frame's `Interaction`, with the paragraph's top
    /// left at `origin` (logical px, as `Input.pointer`).
    pub fn of(it: *const Interaction, id: Id, origin: [2]f32, mods: Input.Mods) Pointer {
        const n = @backingInt(id);
        const mine = n != 0;
        return .{
            .at = .{ it.pointer[0] - origin[0], it.pointer[1] - origin[1] },
            .press = mine and it.pressed == n,
            .held = mine and it.active == n,
            .double = mine and it.double_clicked == n,
            .shift = mods.shift,
        };
    }
};

/// How the editor treats its text (Iced 0.14 `text_input` and its `secure` flag, DVUI's
/// `TextEntryWidget` `multiline` and `password_char`).
pub const Mode = struct {
    /// One line: Enter submits (`Result.submitted`) instead of inserting a newline, typed and
    /// pasted newlines become spaces, Up and Down go to the start and end.
    single_line: bool = false,
    /// A password: one line, shown as one `bullet` per grapheme (`display`), never copied or
    /// cut, word moves and word deletes go to the start or end (they would show where its words
    /// are), and the host is asked for secure input.
    password: bool = false,
    bullet: []const u8 = "\u{2022}",
};

/// What `update` reads besides the keyboard.
pub const Context = struct {
    /// The layout of `Editor.text()` as it is before this update, for Home, End, Up and Down
    /// on laid-out lines. Without one (or once an edit this frame has made it stale), those
    /// keys work on the lines between newlines, and Up and Down go to the text's start and end.
    view: ?moves.View = null,
    /// Clicks and drags place the caret and select; they need `view`.
    pointer: Pointer = .{},
    /// Where cut, copy and paste go (prototype/ui.zig `Platform.clipboard`): copy and cut set
    /// `clipboard.set`, paste sets `clipboard.paste`, and the host answers a paste with typed
    /// text next frame, which replaces the selection then. Null: the three keys do nothing.
    clipboard: ?*keyboard.Clipboard = null,
    /// Caller-owned bytes the copied text is put in. `clipboard.set` points into them, so it
    /// stays valid after a cut and after later edits, until the host reads it after the frame.
    copy_buf: []u8 = &.{},
    /// What the input method is composing for this widget: `Keyboard.composition(id, ...)`,
    /// so it is empty unless the widget is focused, and its range is clamped. Its text is
    /// shown at the caret as a preedit range of the buffer until the IME commits it (as typed
    /// text, which ends the composition) or drops it.
    composition: keyboard.Composition = .{},
    /// Scratch for Left and Right in visual order on lines with right-to-left text
    /// (`moves.visual`). Without it they move in logical order.
    bidi: ?moves.BidiScratch = null,
    /// The base direction of the text's paragraphs, as laid out (`lines.Align.direction`).
    direction: @import("../unicode/bidi.zig").Direction = .auto,
};

/// What one `update` did.
pub const Result = struct {
    /// The text changed.
    changed: bool = false,
    /// Typed or pasted text did not fit in the buffer; what fitted was inserted.
    full: bool = false,
    /// A selection to cut or copy was longer than `Context.copy_buf`: it was neither copied nor
    /// cut.
    copy_full: bool = false,
    /// Enter was pressed in a single-line editor.
    submitted: bool = false,
};

pub const Editor = struct {
    b: Buffer,
    /// Byte offset of the caret, at a grapheme boundary.
    caret: u32 = 0,
    /// The other end of the selection: the selection is the text between `anchor` and `caret`,
    /// empty when they are equal. Shift with a move, or a drag, moves only the caret.
    anchor: u32 = 0,
    /// The x, px, that Up and Down aim for: kept across a run of vertical moves, so a caret
    /// passing a short line returns to its column. NaN when the next vertical move starts one.
    goal: f32 = std.math.nan(f32),
    keys: Keys = .{},
    mode: Mode = .{},
    /// Undo and redo; records nothing until the caller gives it rows (`History.init`).
    history: History = .{},
    /// What the last edit was, so that a run of typing or of deleting is one undo step. Any
    /// other key, a click, undo and redo end the run.
    run: Run = .none,
    /// The IME's preedit text in the buffer, as a byte range (empty when not composing). It is
    /// in `text()` so layout shows it, and taken out again at the start of every `update`, so
    /// edits, undo and the history never see it.
    preedit: [2]u32 = .{ 0, 0 },
    /// The part of the preedit the IME highlights, as a byte range of the buffer.
    preedit_sel: [2]u32 = .{ 0, 0 },

    pub const Run = enum(u8) { none, typing, deleting };

    /// An editor over `buf` holding `initial`, with the caret at its end.
    pub fn init(buf: []u8, initial: []const u8) Buffer.Error!Editor {
        const b = try Buffer.init(buf, initial);
        return .{ .b = b, .caret = b.len(), .anchor = b.len() };
    }

    /// The selection as an ordered byte range.
    pub fn selection(ed: *const Editor) [2]u32 {
        return .{ @min(ed.anchor, ed.caret), @max(ed.anchor, ed.caret) };
    }

    /// The selected text, valid until the next edit.
    pub fn selected(ed: *Editor) []const u8 {
        const s = ed.selection();
        return ed.text()[s[0]..s[1]];
    }

    pub fn composing(ed: *const Editor) bool {
        return ed.preedit[0] < ed.preedit[1];
    }

    /// Where the caret is drawn: the end of the IME's highlight while composing, else `caret`.
    pub fn shownCaret(ed: *const Editor) u32 {
        return if (ed.composing()) ed.preedit_sel[1] else ed.caret;
    }

    /// Asks the host for text input (prototype/ui.zig `Platform.wants_text`, `ime_rect`), with
    /// the IME's window placed at the caret, or at the start of the preedit while composing
    /// so the window does not follow every keystroke. `v` is the layout of `text()`, drawn
    /// with its top left at `origin`, logical px.
    pub fn requestInput(ed: *Editor, out: *keyboard.TextInput, v: moves.View, origin: [2]f32) void {
        const at = if (ed.composing()) ed.preedit[0] else ed.caret;
        var rect = v.caretRect(ed.toDisplay(at));
        rect.x0 += origin[0];
        rect.x1 += origin[0];
        rect.y0 += origin[1];
        rect.y1 += origin[1];
        out.request(rect, if (ed.mode.password) .secure else .normal);
    }

    /// What to lay out and draw: the text, or for a password one `mode.bullet` per grapheme,
    /// written to `out` (at least `bullet.len` bytes per byte of text). Valid until the next
    /// edit. The layout of it is the `View` that `update` and `requestInput` take; offsets in
    /// it and in the text convert with `toDisplay` and `fromDisplay`.
    pub fn display(ed: *Editor, out: []u8) []const u8 {
        const t = ed.text();
        if (!ed.mode.password) return t;
        const bullet = ed.mode.bullet;
        var it: Graphemes = .{ .text = t };
        var n: usize = 0;
        while (it.next()) |_| : (n += bullet.len) @memcpy(out[n..][0..bullet.len], bullet);
        return out[0..n];
    }

    /// The offset in `display` of text offset `at` (a grapheme boundary).
    pub fn toDisplay(ed: *Editor, at: u32) u32 {
        if (!ed.mode.password) return at;
        var it: Graphemes = .{ .text = ed.text()[0..at] };
        var n: u32 = 0;
        while (it.next()) |_| n += 1;
        return n * @as(u32, @intCast(ed.mode.bullet.len));
    }

    /// The text offset of offset `at` in `display` (rounded down to a whole bullet).
    pub fn fromDisplay(ed: *Editor, at: u32) u32 {
        if (!ed.mode.password) return at;
        var it: Graphemes = .{ .text = ed.text() };
        var left = at / @as(u32, @intCast(ed.mode.bullet.len));
        var off: u32 = 0;
        while (left > 0) : (left -= 1) off = @intCast(it.next() orelse break);
        return off;
    }

    /// Puts the caret at `at` with nothing selected.
    pub fn place(ed: *Editor, at: u32) void {
        ed.caret = at;
        ed.anchor = at;
    }

    /// The text, contiguous, valid until the next edit.
    pub fn text(ed: *Editor) []const u8 {
        return ed.b.text();
    }

    /// Applies this frame's input for widget `id` from `k`: typed text replaces the selection
    /// or is inserted at the caret, Backspace and Delete remove the selection or the grapheme
    /// (with `keys.word`, the word) before and after the caret, Enter inserts a newline, the
    /// arrows, Home and End move the caret (with Shift, select), and select-all selects all.
    /// The pointer is applied first, from `cx.pointer` over `cx.view`. Keys do nothing unless
    /// `id` is focused; the pointer is the caller's to fill for `id` only.
    pub fn update(ed: *Editor, k: *const Keyboard, id: Id, cx: Context) Result {
        var r: Result = .{};
        // Last frame's preedit leaves first; the layout of the text with it is then stale.
        const was = ed.composing();
        if (was) {
            ed.b.delete(ed.preedit[0], ed.preedit[1]);
            ed.place(ed.preedit[0]);
            ed.preedit = .{ 0, 0 };
            ed.preedit_sel = .{ 0, 0 };
            r.changed = true;
        }
        const fresh = if (was) null else cx.view;
        if (fresh) |v| ed.point(v, cx.pointer);
        var it = k.events(id);
        while (it.next()) |e| {
            if (e.kind == .text) {
                ed.typeText(k.in.typed(e), &r);
                ed.goal = std.math.nan(f32);
                continue;
            }
            if (e.kind == .release) continue;
            const view = if (r.changed) null else fresh;
            ed.key(e, view, cx, &r);
        }
        ed.compose(cx.composition, &r);
        return r;
    }

    /// Shows `c` at the caret as the preedit, in place of the selection (whose removal is
    /// recorded, the preedit is not). A preedit that does not fit is cut at a code point.
    fn compose(ed: *Editor, c: keyboard.Composition, r: *Result) void {
        if (c.text.len == 0) return;
        const sel = ed.selection();
        if (sel[0] < sel[1]) ed.remove(sel[0], sel[1], false, r);
        ed.run = .none;
        var n: u32 = @intCast(@min(c.text.len, ed.b.free()));
        while (n < c.text.len and n > 0 and c.text[n] & 0xc0 == 0x80) n -= 1;
        r.full = r.full or n < c.text.len;
        if (n == 0) return;
        const at = ed.caret;
        ed.b.insert(at, c.text[0..n]) catch unreachable;
        ed.preedit = .{ at, at + n };
        ed.preedit_sel = .{ at + @min(c.range[0], n), at + @min(c.range[1], n) };
        r.changed = true;
    }

    /// A press places the caret (with Shift, extends the selection), a held button drags the
    /// caret, a double click selects the word under the pointer.
    fn point(ed: *Editor, v: moves.View, p: Pointer) void {
        if (!(p.press or p.held or p.double)) return;
        const at = ed.fromDisplay(v.hit(p.at[0], p.at[1]));
        ed.goal = std.math.nan(f32);
        ed.run = .none;
        if (p.double) {
            const w: [2]u32 = if (ed.mode.password) .{ 0, ed.b.len() } else moves.wordAt(v.text, at);
            ed.anchor = w[0];
            ed.caret = w[1];
        } else if (p.press) {
            ed.caret = at;
            if (!p.shift) ed.anchor = at;
        } else {
            ed.caret = at;
        }
    }

    fn key(ed: *Editor, e: Input.Event, laid_out: ?moves.View, cx: Context, r: *Result) void {
        const ks = &ed.keys;
        const single = ed.mode.single_line or ed.mode.password;
        // One line has no lines to move between, and a password's layout is of its bullets.
        const view = if (single) null else laid_out;
        const t = ed.text();
        const at = ed.caret;
        const shift = e.mods.shift;
        // Shift selects (it does not change what a key does); compare the rest exactly.
        var m = e.mods;
        m.shift = false;
        const mods: u8 = @bitCast(m);
        const word = mods == @as(u8, @bitCast(ks.word));
        const c = e.code;
        const sel = ed.selection();
        const some = sel[0] < sel[1];
        const vertical = c == ks.up or c == ks.down;
        if (!vertical) ed.goal = std.math.nan(f32);
        if (c == ks.backspace) {
            if (some) return ed.remove(sel[0], sel[1], false, r);
            const from = if (word) ed.wordBefore(t, at) else moves.prevGrapheme(t, at);
            return ed.remove(from, at, ed.run == .deleting, r);
        }
        if (c == ks.delete) {
            if (some) return ed.remove(sel[0], sel[1], false, r);
            const to = if (word) ed.wordAfter(t, at) else moves.nextGrapheme(t, at);
            return ed.remove(at, to, ed.run == .deleting, r);
        }
        if (c == ks.enter or c == ks.keypad_enter) {
            if (!single) return ed.insert("\n", r);
            ed.run = .none;
            r.submitted = true;
            return;
        }
        ed.run = .none;
        const cmd = @as(u8, @bitCast(e.mods)) == @as(u8, @bitCast(ks.clipboard.mods));
        var cmd_shift = ks.clipboard.mods;
        cmd_shift.shift = true;
        const redo = (cmd and c == ks.redo) or (c == ks.undo and @as(u8, @bitCast(e.mods)) == @as(u8, @bitCast(cmd_shift)));
        if ((cmd and c == ks.undo) or redo) {
            const s = (if (redo) ed.history.redo(&ed.b) else ed.history.undo(&ed.b)) orelse return;
            ed.caret = s.caret;
            ed.anchor = s.anchor;
            r.changed = true;
            return;
        }
        if (cmd and c == ks.clipboard.select_all) {
            ed.anchor = 0;
            ed.caret = @intCast(t.len);
            return;
        }
        if (cmd and (c == ks.clipboard.copy or c == ks.clipboard.cut)) {
            const clip = cx.clipboard orelse return;
            if (!some or ed.mode.password) return;
            if (sel[1] - sel[0] > cx.copy_buf.len) {
                r.copy_full = true;
                return;
            }
            clip.copy(ed.b.copy(sel[0], sel[1], cx.copy_buf));
            if (c == ks.clipboard.cut) {
                ed.remove(sel[0], sel[1], false, r);
                ed.run = .none;
            }
            return;
        }
        if (cmd and c == ks.clipboard.paste) {
            if (cx.clipboard) |clip| clip.requestPaste();
            return;
        }
        // Left and Right without Shift collapse a selection to its edge.
        const shown = if (ed.mode.password) null else cx.bidi;
        if (c == ks.left) {
            const v = if (shown) |b| moves.visual(t, at, -1, cx.direction, b) else null;
            ed.caret = if (some and !shift and !word) sel[0] else if (word) ed.wordBefore(t, at) else v orelse moves.prevGrapheme(t, at);
        } else if (c == ks.right) {
            const v = if (shown) |b| moves.visual(t, at, 1, cx.direction, b) else null;
            ed.caret = if (some and !shift and !word) sel[1] else if (word) ed.wordAfter(t, at) else v orelse moves.nextGrapheme(t, at);
        } else if (c == ks.home) {
            ed.caret = if (word) 0 else if (view) |v| v.home(at) else moves.lineStart(t, at);
        } else if (c == ks.end) {
            ed.caret = if (word) @intCast(t.len) else if (view) |v| v.end(at) else moves.lineEnd(t, at);
        } else if (vertical) {
            const down = c == ks.down;
            if (view) |v| {
                if (std.math.isNan(ed.goal)) ed.goal = v.x(at);
                ed.caret = v.vertical(at, if (down) 1 else -1, ed.goal);
            } else {
                ed.caret = if (down) @intCast(t.len) else 0;
            }
        } else return;
        // A move without Shift drops the selection; one with Shift keeps the anchor.
        if (!shift) ed.anchor = ed.caret;
    }

    fn wordBefore(ed: *const Editor, t: []const u8, at: u32) u32 {
        return if (ed.mode.password) 0 else moves.prevWord(t, at);
    }
    fn wordAfter(ed: *const Editor, t: []const u8, at: u32) u32 {
        return if (ed.mode.password) @intCast(t.len) else moves.nextWord(t, at);
    }

    /// Inserts typed text in place of the selection, leaving out control characters other than
    /// newline and tab (Enter arrives as a key, and some hosts also type it as "\r"). One line
    /// takes a newline as a space.
    fn typeText(ed: *Editor, typed: []const u8, r: *Result) void {
        const single = ed.mode.single_line or ed.mode.password;
        var i: usize = 0;
        while (i < typed.len) {
            var j = i;
            while (j < typed.len and allowed(typed[j]) and !(single and typed[j] == '\n')) j += 1;
            ed.insert(typed[i..j], r);
            if (j < typed.len and single and typed[j] == '\n') ed.insert(" ", r);
            i = j + 1;
        }
    }

    fn allowed(c: u8) bool {
        return (c >= 0x20 and c != 0x7f) or c == '\n' or c == '\t';
    }

    /// Inserts `bytes` in place of the selection and moves the caret past them, recorded as
    /// part of a typing run or of the selection's removal. What does not fit is cut at a code
    /// point boundary and dropped.
    fn insert(ed: *Editor, bytes: []const u8, r: *Result) void {
        const sel = ed.selection();
        var join = ed.run == .typing;
        if (sel[0] < sel[1]) {
            ed.remove(sel[0], sel[1], false, r);
            join = true;
        }
        ed.run = .typing;
        var n: usize = @min(bytes.len, ed.b.free());
        // Back off a cut inside a UTF-8 sequence.
        while (n < bytes.len and n > 0 and bytes[n] & 0xc0 == 0x80) n -= 1;
        r.full = r.full or n < bytes.len;
        if (n == 0) return;
        if (ed.history.push(.insert, ed.caret, @intCast(n), ed.caret, ed.anchor, join)) |d| @memcpy(d, bytes[0..n]);
        ed.b.insert(ed.caret, bytes[0..n]) catch unreachable;
        ed.caret += @intCast(n);
        ed.anchor = ed.caret;
        r.changed = true;
    }

    /// Removes `[from, to)`, recorded in the last undo step when `join`; the caret goes to
    /// `from`, with nothing selected.
    fn remove(ed: *Editor, from: u32, to: u32, join: bool, r: *Result) void {
        ed.run = .deleting;
        if (from == to) return ed.place(from);
        if (ed.history.push(.delete, from, to - from, ed.caret, ed.anchor, join)) |d| _ = ed.b.copy(from, to, d);
        ed.b.delete(from, to);
        ed.place(from);
        r.changed = r.changed or from < to;
    }
};

// ---------------------------------------------------------------------------------------------

const testing = std.testing;
const Focus = @import("../../interact/focus.zig").Focus;
const Replay = @import("../../core/input.zig").Replay;

pub const field = Id.from("field");

/// Replays `src` into `ed` as the focused widget `field`, one `update` per frame. Returns the
/// results of the frames, OR-ed.
pub fn replay(ed: *Editor, src: []const u8) !Result {
    return replayWith(ed, src, .{});
}

/// How `replayWith` runs the editor.
pub const Replayed = struct {
    /// Lay the text out before every frame in a box this many px wide, each byte one 10 px
    /// glyph and each line 10 px high (ASCII only), and pass the layout as the view.
    width: ?f32 = null,
    /// Passed as `Context.clipboard` and reset before every frame, as a host does once it has
    /// read it: after the replay it holds the last frame's requests.
    clipboard: ?*keyboard.Clipboard = null,
    copy_buf: []u8 = &.{},
    /// The IME's composition in each frame, by frame number; none past the end.
    compositions: []const keyboard.Composition = &.{},
    bidi: ?moves.BidiScratch = null,
};

/// As `replay`, run as `opt` says. The editor is one focusable node covering (0, 0) to
/// (1000, 1000), stepped through a real `Interaction`, so `pointer` and `buttons` lines
/// click, drag and double-click it.
pub fn replayWith(ed: *Editor, src: []const u8, opt: Replayed) !Result {
    const golden = @import("../layout/golden.zig");
    const lines = @import("../layout/lines.zig");
    const mem = @import("../../core/mem.zig");
    const Tree = @import("../../core/tree.zig").Tree;
    var raw: [16 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var tree = Tree.init(&carver, 2);
    const root = tree.push(0, .none, &.{});
    const n = tree.push(root, field, &.{});
    tree.seal(n);
    tree.seal(root);
    tree.c.sense[n] = @bitCast(types.Sense.button);
    for (tree.c.vis, [4]f32{ 0, 0, 1000, 1000 }) |col, v| col[n] = v;

    var para: golden.Para = .{};
    var shown: [256]u8 = undefined;
    var text_buf: [256]u8 = undefined;
    var events: [64]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text_buf, .events = &events, .contacts = &contacts };
    var r: Replay = .{ .src = src };
    var it: Interaction = .{ .focus = @backingInt(field) };
    const fo: Focus = .{};
    var all: Result = .{};
    var frame: usize = 0;
    while (try r.next(buf)) |in| : (frame += 1) {
        it.step(&tree, in);
        const k = Keyboard.route(&it, &fo, in);
        var cx: Context = .{ .pointer = .of(&it, field, .{ 0, 0 }, in.mods), .clipboard = opt.clipboard, .copy_buf = opt.copy_buf, .bidi = opt.bidi };
        if (opt.clipboard) |c| c.reset();
        if (frame < opt.compositions.len) cx.composition = k.composition(field, &opt.compositions[frame]);
        if (opt.width) |w| {
            const t = ed.display(&shown);
            para.fixed(t, 10);
            try lines.breakLines(&para.g, t, w, &para.l);
            lines.place(&para.l, &para.g, t, &.{.{ .ascent = 8, .descent = 2 }}, .{ .width = w });
            cx.view = .{ .l = &para.l, .g = &para.g, .text = t };
        }
        const one = ed.update(&k, field, cx);
        all.changed = all.changed or one.changed;
        all.full = all.full or one.full;
        all.copy_full = all.copy_full or one.copy_full;
        all.submitted = all.submitted or one.submitted;
    }
    return all;
}

test "replayed input: typing, Backspace and Delete by grapheme, Enter" {
    var raw: [64]u8 = undefined;
    var ed = try Editor.init(&raw, "");
    const r = try replay(&ed,
        \\frame
        \\text he
        \\text llo
        \\press 42
        \\frame
        \\text é
        \\press 40
        \\text x
    );
    try testing.expect(r.changed);
    try testing.expect(!r.full);
    try testing.expectEqualStrings("hell\u{e9}\nx", ed.text());
    try testing.expectEqual(ed.text().len, ed.caret);

    var raw2: [32]u8 = undefined;
    var ed2 = try Editor.init(&raw2, "ae\u{301}b");
    ed2.place(4); // after e + combining acute
    _ = try replay(&ed2,
        \\frame
        \\press 42
    );
    try testing.expectEqualStrings("ab", ed2.text());
    try testing.expectEqual(1, ed2.caret);
    ed2.place(0);
    _ = try replay(&ed2,
        \\frame
        \\press 76
        \\repeat 76
        \\press 76
        \\release 76
    );
    try testing.expectEqualStrings("", ed2.text());
    // Backspace at the start and Delete at the end change nothing.
    try testing.expect(!(try replay(&ed2,
        \\frame
        \\press 42
        \\press 76
    )).changed);
}

test "replayed input: control characters are dropped, a full buffer keeps whole code points" {
    var raw: [6]u8 = undefined;
    var ed = try Editor.init(&raw, "");
    // "a", a tab, "b" then "é" and "日" (3 bytes) which no longer fits whole.
    const typed = "a\r\tb\x7f\xc3\xa9\xe6\x97\xa5";
    const ev = [_]Input.Event{.{ .kind = .text, .at = 0, .len = typed.len }};
    const in: Input = .{ .text = typed, .events = &ev };
    const it: Interaction = .{ .focus = @backingInt(field) };
    const fo: Focus = .{};
    const k = Keyboard.route(&it, &fo, &in);
    const r = ed.update(&k, field, .{});
    try testing.expect(r.full);
    try testing.expectEqualStrings("a\tb\xc3\xa9", ed.text());
    try testing.expectEqual(5, ed.caret);
    // Another widget's input does nothing.
    try testing.expect(!ed.update(&k, Id.from("other"), .{}).changed);
}

test "replayed input: the caret moves by grapheme, word and line" {
    var raw: [64]u8 = undefined;
    var ed = try Editor.init(&raw, "one two\nthree");
    // Ctrl+Home, Ctrl+Right twice, Left: after "tw".
    _ = try replay(&ed,
        \\frame
        \\press 74 ctrl
        \\press 79 ctrl
        \\press 79 ctrl
        \\press 80
        \\text _
    );
    try testing.expectEqualStrings("one tw_o\nthree", ed.text());
    // Ctrl+Backspace deletes "tw_", Ctrl+Delete the "o" after it; End, Home on the line.
    _ = try replay(&ed,
        \\frame
        \\press 42 ctrl
        \\press 76 ctrl
        \\press 77
        \\text !
        \\press 74
        \\text >
    );
    try testing.expectEqualStrings(">one !\nthree", ed.text());
    // Without a layout Down goes to the end and Up to the start.
    _ = try replay(&ed,
        \\frame
        \\press 81
        \\text .
        \\press 82
        \\text <
    );
    try testing.expectEqualStrings("<>one !\nthree.", ed.text());
}

test "replayed input: Up and Down on laid-out lines keep the column across a short line" {
    var raw: [64]u8 = undefined;
    // Lines in a 60 px box: "abcde " | "x\n" | "fghij".
    var ed = try Editor.init(&raw, "abcde x\nfghij");
    ed.place(4); // after "abcd", x = 40
    _ = try replayWith(&ed,
        \\frame
        \\press 81
    , .{ .width = 60 });
    try testing.expectEqual(7, ed.caret); // "x" is short: its end, before the newline
    _ = try replayWith(&ed,
        \\frame
        \\press 81
        \\text _
    , .{ .width = 60 });
    // Back at x = 40 on the last line, not at x = 10.
    try testing.expectEqualStrings("abcde x\nfghi_j", ed.text());
    // End then Home on a laid-out line; Up past the first line goes to the start.
    _ = try replayWith(&ed,
        \\frame
        \\press 82
        \\press 82
        \\press 77
    , .{ .width = 60 });
    try testing.expectEqual(5, ed.caret); // before the hanging space
    _ = try replayWith(&ed,
        \\frame
        \\press 82
    , .{ .width = 60 });
    try testing.expectEqual(0, ed.caret);
}

test "replayed input: Shift with moves selects, typing and Backspace replace the selection" {
    var raw: [64]u8 = undefined;
    var ed = try Editor.init(&raw, "hello world");
    // Shift+Ctrl+Left selects "world"; typing replaces it.
    _ = try replay(&ed,
        \\frame
        \\press 80 shift ctrl
        \\text there
    );
    try testing.expectEqualStrings("hello there", ed.text());
    // Shift+Home selects back to the start; Left collapses to the selection's start.
    _ = try replay(&ed,
        \\frame
        \\press 80 shift
        \\press 80 shift
    );
    try testing.expectEqualStrings("re", ed.selected());
    _ = try replay(&ed,
        \\frame
        \\press 80
        \\text _
    );
    try testing.expectEqualStrings("hello the_re", ed.text());
    // Ctrl+A selects all, Backspace deletes it; Ctrl+A on empty text selects nothing.
    _ = try replay(&ed,
        \\frame
        \\press 4 ctrl
    );
    try testing.expectEqual([2]u32{ 0, 12 }, ed.selection());
    _ = try replay(&ed,
        \\frame
        \\press 42
    );
    try testing.expectEqualStrings("", ed.text());
    try testing.expectEqual([2]u32{ 0, 0 }, ed.selection());
    // Shift+End then Delete.
    var ed2 = try Editor.init(&raw, "ab\ncd");
    ed2.place(1);
    _ = try replay(&ed2,
        \\frame
        \\press 77 shift
        \\press 76
    );
    try testing.expectEqualStrings("a\ncd", ed2.text());
}

test "replayed input: click places the caret, drag and Shift+click select, double click a word" {
    var raw: [64]u8 = undefined;
    // "one two " | "three" in an 80 px box; glyphs are 10 px, lines 10 px.
    var ed = try Editor.init(&raw, "one two three");
    _ = try replayWith(&ed,
        \\frame
        \\pointer 21 5
        \\buttons left
        \\frame
        \\buttons
    , .{ .width = 80 });
    try testing.expectEqual([2]u32{ 2, 2 }, ed.selection());
    // Press after "t" of "two", drag to after "th" on the second line.
    _ = try replayWith(&ed,
        \\frame
        \\pointer 49 4
        \\buttons left
        \\frame
        \\pointer 20 15
        \\frame
        \\buttons
    , .{ .width = 80 });
    try testing.expectEqual(5, ed.anchor);
    try testing.expectEqualStrings("wo th", ed.selected());
    // Shift+click extends from the anchor.
    _ = try replayWith(&ed,
        \\frame
        \\mods shift
        \\pointer 0 5
        \\buttons left
        \\frame
        \\mods
        \\buttons
    , .{ .width = 80 });
    try testing.expectEqualStrings("one t", ed.selected());
    // Two quick clicks on "three" select it.
    _ = try replayWith(&ed,
        \\frame
        \\pointer 25 15
        \\buttons left
        \\frame
        \\buttons
        \\frame
        \\buttons left
        \\frame
        \\buttons
    , .{ .width = 80 });
    try testing.expectEqualStrings("three", ed.selected());
    try testing.expectEqual(13, ed.caret);
}

test "replayed input: cut, copy and paste through the clipboard rows" {
    var raw: [64]u8 = undefined;
    var ed = try Editor.init(&raw, "copy this");
    var clip: keyboard.Clipboard = .{};
    var copied: [16]u8 = undefined;
    const opt: Replayed = .{ .clipboard = &clip, .copy_buf = &copied };
    // Nothing selected: copy asks for nothing.
    _ = try replayWith(&ed,
        \\frame
        \\press 6 ctrl
    , opt);
    try testing.expectEqualStrings("", clip.set);
    // Select "this", copy it; the text stays.
    _ = try replayWith(&ed,
        \\frame
        \\press 80 ctrl shift
        \\press 6 ctrl
    , opt);
    try testing.expectEqualStrings("this", clip.set);
    try testing.expectEqualStrings("copy this", ed.text());
    // Cut "copy " (Shift+Home after collapsing): it leaves the text; the copy survives the edit.
    _ = try replayWith(&ed,
        \\frame
        \\press 80
        \\press 74 shift
        \\press 27 ctrl
        \\text >
    , opt);
    try testing.expectEqualStrings("copy ", clip.set);
    try testing.expectEqualStrings(">this", ed.text());
    // Paste asks the host; the host types the clipboard next frame, replacing the selection.
    _ = try replayWith(&ed,
        \\frame
        \\press 4 ctrl
        \\press 25 ctrl
    , opt);
    try testing.expect(clip.paste);
    try testing.expectEqualStrings("", clip.set);
    _ = try replayWith(&ed,
        \\frame
        \\text copy_
    , opt);
    try testing.expect(!clip.paste);
    try testing.expectEqualStrings("copy_", ed.text());
    // Ctrl+Shift+C is not copy; a selection longer than the copy buffer is not cut.
    var small: [2]u8 = undefined;
    const r = try replayWith(&ed,
        \\frame
        \\press 4 ctrl
        \\press 6 ctrl shift
        \\press 27 ctrl
    , .{ .clipboard = &clip, .copy_buf = &small });
    try testing.expect(r.copy_full);
    try testing.expectEqualStrings("", clip.set);
    try testing.expectEqualStrings("copy_", ed.text());
    // Without clipboard rows the keys do nothing.
    _ = try replay(&ed,
        \\frame
        \\press 27 ctrl
    );
    try testing.expectEqualStrings("copy_", ed.text());
}

test "replayed input: undo and redo whole runs of typing and deleting" {
    const mem = @import("../../core/mem.zig");
    var cols: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &cols };
    var raw: [64]u8 = undefined;
    var ed = try Editor.init(&raw, "");
    ed.history = History.init(&carver, 16, 64);
    // Two runs of typing, split by a move; then a run of Backspace.
    _ = try replay(&ed,
        \\frame
        \\text hello
        \\text  world
        \\press 80
        \\press 79
        \\text !
        \\frame
        \\press 42
        \\press 42
    );
    try testing.expectEqualStrings("hello worl", ed.text());
    // Undo the Backspaces, then the "!", in one frame.
    _ = try replay(&ed,
        \\frame
        \\press 29 ctrl
        \\press 29 ctrl
    );
    try testing.expectEqualStrings("hello world", ed.text());
    try testing.expectEqual(11, ed.caret);
    // Redo with Ctrl+Y, and with Ctrl+Shift+Z.
    _ = try replay(&ed,
        \\frame
        \\press 28 ctrl
    );
    try testing.expectEqualStrings("hello world!", ed.text());
    _ = try replay(&ed,
        \\frame
        \\press 29 ctrl shift
    );
    try testing.expectEqualStrings("hello worl", ed.text());
    // Typing over a selection is one step: undo brings the selection back.
    _ = try replay(&ed,
        \\frame
        \\press 80 shift ctrl
        \\text there
    );
    try testing.expectEqualStrings("hello there", ed.text());
    _ = try replay(&ed,
        \\frame
        \\press 29 ctrl
    );
    try testing.expectEqualStrings("hello worl", ed.text());
    try testing.expectEqualStrings("worl", ed.selected());
    // A new edit after an undo drops the redo.
    _ = try replay(&ed,
        \\frame
        \\text X
        \\press 28 ctrl
    );
    try testing.expectEqualStrings("hello X", ed.text());
    // Undo everything, past the first step: nothing more happens.
    for (0..6) |_| _ = try replay(&ed,
        \\frame
        \\press 29 ctrl
    );
    try testing.expectEqualStrings("", ed.text());
    try testing.expect(!(try replay(&ed,
        \\frame
        \\press 29 ctrl
    )).changed);
}

test "replayed input: IME composition shows a preedit range; the commit is one undo step" {
    const mem = @import("../../core/mem.zig");
    var cols: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &cols };
    var raw: [64]u8 = undefined;
    var ed = try Editor.init(&raw, "aXb");
    ed.history = History.init(&carver, 16, 64);
    ed.anchor = 1;
    ed.caret = 2; // "X" selected
    // Composing "ni", then "nihon" with "hon" highlighted, then the IME commits.
    const comps = [_]keyboard.Composition{
        .{ .text = "ni", .range = .{ 2, 2 } },
        .{ .text = "nihon", .range = .{ 2, 5 } },
        .{},
    };
    _ = try replayWith(&ed,
        \\frame
    , .{ .compositions = comps[0..1] });
    try testing.expectEqualStrings("anib", ed.text());
    try testing.expectEqual([2]u32{ 1, 3 }, ed.preedit);
    try testing.expectEqual(3, ed.shownCaret());
    var out: keyboard.TextInput = .{};
    var rect_x: f32 = 0;
    {
        const golden = @import("../layout/golden.zig");
        const lines = @import("../layout/lines.zig");
        var para: golden.Para = .{};
        const t = ed.text();
        para.fixed(t, 10);
        try lines.breakLines(&para.g, t, 1000, &para.l);
        lines.place(&para.l, &para.g, t, &.{.{ .ascent = 8, .descent = 2 }}, .{ .width = 1000 });
        ed.requestInput(&out, .{ .l = &para.l, .g = &para.g, .text = t }, .{ 100, 50 });
        rect_x = out.rect.x0;
    }
    try testing.expect(out.wants_text);
    try testing.expectEqual(@as(f32, 110), rect_x); // at the preedit's start, after "a"
    try testing.expectEqual(@as(f32, 60), out.rect.y1);
    _ = try replayWith(&ed,
        \\frame
    , .{ .compositions = comps[1..2] });
    try testing.expectEqualStrings("anihonb", ed.text());
    try testing.expectEqual([2]u32{ 3, 6 }, ed.preedit_sel);
    _ = try replayWith(&ed,
        \\frame
        \\text 日本
    , .{ .compositions = comps[2..3] });
    try testing.expectEqualStrings("a日本b", ed.text());
    try testing.expect(!ed.composing());
    try testing.expectEqual(7, ed.caret);
    // One undo takes the commit out, the next puts the "X" back: the preedit never was a step.
    _ = try replay(&ed,
        \\frame
        \\press 29 ctrl
    );
    try testing.expectEqualStrings("ab", ed.text());
    _ = try replay(&ed,
        \\frame
        \\press 29 ctrl
    );
    try testing.expectEqualStrings("aXb", ed.text());
    try testing.expectEqualStrings("X", ed.selected());
    // A composition the IME drops leaves only the removal of the selection it replaced.
    _ = try replayWith(&ed,
        \\frame
        \\frame
    , .{ .compositions = comps[0..1] });
    try testing.expectEqualStrings("ab", ed.text());
}

/// One frame in which the focused `field` is typed `typed`, then the keys `press` pressed.
fn typeIn(ed: *Editor, typed: []const u8, press: []const u8) Result {
    var ev: [8]Input.Event = undefined;
    ev[0] = .{ .kind = .text, .at = 0, .len = @intCast(typed.len) };
    for (press, ev[1..][0..press.len]) |code, *e| e.* = .{ .kind = .press, .code = code };
    const in: Input = .{ .text = typed, .events = ev[0 .. press.len + 1] };
    const it: Interaction = .{ .focus = @backingInt(field) };
    const fo: Focus = .{};
    const k = Keyboard.route(&it, &fo, &in);
    return ed.update(&k, field, .{});
}

test "replayed input: single-line mode submits on Enter and keeps to one line" {
    var raw: [64]u8 = undefined;
    var ed = try Editor.init(&raw, "");
    ed.mode = .{ .single_line = true };
    const r = try replay(&ed,
        \\frame
        \\text one
        \\press 40
        \\press 88
    );
    try testing.expect(r.submitted);
    try testing.expectEqualStrings("one", ed.text());
    // A pasted newline becomes a space; Up goes to the start, Down to the end.
    try testing.expect(!typeIn(&ed, "a\nb", &.{0x52}).submitted);
    try testing.expectEqualStrings("onea b", ed.text());
    try testing.expectEqual(0, ed.caret);
    _ = typeIn(&ed, "", &.{0x51});
    try testing.expectEqual(6, ed.caret);
}

test "replayed input: password mode shows bullets, hides words and is never copied" {
    var raw: [64]u8 = undefined;
    var ed = try Editor.init(&raw, "");
    ed.mode = .{ .password = true };
    var clip: keyboard.Clipboard = .{};
    var copied: [64]u8 = undefined;
    _ = try replayWith(&ed,
        \\frame
        \\text hunter 2
        \\press 4 ctrl
        \\press 6 ctrl
        \\press 27 ctrl
    , .{ .clipboard = &clip, .copy_buf = &copied });
    try testing.expectEqualStrings("", clip.set);
    try testing.expectEqualStrings("hunter 2", ed.text());
    var shown: [64]u8 = undefined;
    try testing.expectEqualStrings("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}", ed.display(&shown));
    // Ctrl+Left goes to the start, not to the start of "2"; Ctrl+Delete deletes to the end.
    _ = try replay(&ed,
        \\frame
        \\press 79
        \\press 80 ctrl
        \\text >
        \\press 79
        \\press 76 ctrl
    );
    try testing.expectEqualStrings(">h", ed.text());
    // A grapheme is one bullet: e + combining acute shows as one, and offsets convert.
    _ = typeIn(&ed, "e\u{301}", &.{});
    ed.mode.bullet = "*"; // one byte, so the test layout's one glyph per byte holds
    try testing.expectEqualStrings("***", ed.display(&shown));
    try testing.expectEqual(3, ed.toDisplay(5));
    try testing.expectEqual(5, ed.fromDisplay(3));
    try testing.expectEqual(2, ed.fromDisplay(2));
    // Clicks land on the bullets; a double click selects everything.
    _ = try replayWith(&ed,
        \\frame
        \\pointer 11 5
        \\buttons left
        \\frame
        \\buttons
    , .{ .width = 200 });
    try testing.expectEqual(1, ed.caret);
    _ = try replayWith(&ed,
        \\frame
        \\pointer 11 5
        \\buttons left
        \\frame
        \\buttons
        \\frame
        \\buttons left
        \\frame
        \\buttons
    , .{ .width = 200 });
    try testing.expectEqual([2]u32{ 0, 5 }, ed.selection());
    // The host is asked for secure input, at the bullet after the caret's grapheme.
    const golden = @import("../layout/golden.zig");
    const lines = @import("../layout/lines.zig");
    var para: golden.Para = .{};
    const t = ed.display(&shown);
    para.fixed(t, 10);
    try lines.breakLines(&para.g, t, 200, &para.l);
    lines.place(&para.l, &para.g, t, &.{.{ .ascent = 8, .descent = 2 }}, .{ .width = 200 });
    var out: keyboard.TextInput = .{};
    ed.requestInput(&out, .{ .l = &para.l, .g = &para.g, .text = t }, .{ 0, 0 });
    try testing.expectEqual(keyboard.Purpose.secure, out.purpose);
    try testing.expectEqual(@as(f32, 30), out.rect.x0);
}

test "replayed input: Right and Left follow the screen over right-to-left text" {
    const mem = @import("../../core/mem.zig");
    var cols: [8192]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &cols };
    const bidi_cols = carver.columns(moves.BidiScratch, 32);
    var raw: [64]u8 = undefined;
    // "ab " and Hebrew alef bet: on screen "ab בא".
    var ed = try Editor.init(&raw, "ab \u{5D0}\u{5D1}");
    ed.place(2);
    // Right from after "b" crosses the space and lands left of bet, the text's end (the caret
    // stop after a right-to-left letter is its left edge); typing there appends.
    _ = try replayWith(&ed,
        \\frame
        \\press 79
        \\text !
    , .{ .bidi = bidi_cols });
    try testing.expectEqualStrings("ab \u{5D0}\u{5D1}!", ed.text());
    // Without the scratch, Right is logical: from after "b" to after the space.
    var ed2 = try Editor.init(&raw, "ab \u{5D0}\u{5D1}");
    ed2.place(2);
    _ = try replay(&ed2,
        \\frame
        \\press 79
    );
    try testing.expectEqual(3, ed2.caret);
    // Shift+Right selects visually too: from 2 to the end, which on screen is the space.
    ed2.place(2);
    _ = try replayWith(&ed2,
        \\frame
        \\press 79 shift
    , .{ .bidi = bidi_cols });
    try testing.expectEqual([2]u32{ 2, 7 }, ed2.selection());
    // Left from the visual right end (offset 3, right of alef) walks into the Hebrew.
    ed2.place(3);
    _ = try replayWith(&ed2,
        \\frame
        \\press 80
    , .{ .bidi = bidi_cols });
    try testing.expectEqual(5, ed2.caret);
}
