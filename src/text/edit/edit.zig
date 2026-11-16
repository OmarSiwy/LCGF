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

const Id = types.Id;
const Keyboard = keyboard.Keyboard;

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
};

/// What `update` reads besides the keyboard.
pub const Context = struct {
    /// The layout of `Editor.text()` as it is before this update, for Home, End, Up and Down
    /// on laid-out lines. Without one (or once an edit this frame has made it stale), those
    /// keys work on the lines between newlines, and Up and Down go to the text's start and end.
    view: ?moves.View = null,
};

/// What one `update` did.
pub const Result = struct {
    /// The text changed.
    changed: bool = false,
    /// Typed or pasted text did not fit in the buffer; what fitted was inserted.
    full: bool = false,
};

pub const Editor = struct {
    b: Buffer,
    /// Byte offset of the caret, at a grapheme boundary.
    caret: u32 = 0,
    /// The x, px, that Up and Down aim for: kept across a run of vertical moves, so a caret
    /// passing a short line returns to its column. NaN when the next vertical move starts one.
    goal: f32 = std.math.nan(f32),
    keys: Keys = .{},

    /// An editor over `buf` holding `initial`, with the caret at its end.
    pub fn init(buf: []u8, initial: []const u8) Buffer.Error!Editor {
        const b = try Buffer.init(buf, initial);
        return .{ .b = b, .caret = b.len() };
    }

    /// The text, contiguous, valid until the next edit.
    pub fn text(ed: *Editor) []const u8 {
        return ed.b.text();
    }

    /// Applies this frame's input for widget `id` from `k`: typed text is inserted at the
    /// caret, Backspace and Delete remove the grapheme (with `keys.word`, the word) before and
    /// after it, Enter inserts a newline, and the arrows, Home and End move the caret. Nothing
    /// happens unless `id` is focused.
    pub fn update(ed: *Editor, k: *const Keyboard, id: Id, cx: Context) Result {
        var r: Result = .{};
        var it = k.events(id);
        while (it.next()) |e| {
            if (e.kind == .text) {
                ed.typeText(k.in.typed(e), &r);
                ed.goal = std.math.nan(f32);
                continue;
            }
            if (e.kind == .release) continue;
            const view = if (r.changed) null else cx.view;
            ed.key(e, view, &r);
        }
        return r;
    }

    fn key(ed: *Editor, e: Input.Event, view: ?moves.View, r: *Result) void {
        const ks = &ed.keys;
        const t = ed.text();
        const at = ed.caret;
        // Shift selects (it does not change what a key does); compare the rest exactly.
        var m = e.mods;
        m.shift = false;
        const word = @as(u8, @bitCast(m)) == @as(u8, @bitCast(ks.word));
        const c = e.code;
        const vertical = c == ks.up or c == ks.down;
        if (!vertical) ed.goal = std.math.nan(f32);
        if (c == ks.backspace) {
            ed.remove(if (word) moves.prevWord(t, at) else moves.prevGrapheme(t, at), at, r);
        } else if (c == ks.delete) {
            ed.remove(at, if (word) moves.nextWord(t, at) else moves.nextGrapheme(t, at), r);
        } else if (c == ks.enter or c == ks.keypad_enter) {
            ed.insert("\n", r);
        } else if (c == ks.left) {
            ed.caret = if (word) moves.prevWord(t, at) else moves.prevGrapheme(t, at);
        } else if (c == ks.right) {
            ed.caret = if (word) moves.nextWord(t, at) else moves.nextGrapheme(t, at);
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
        }
    }

    /// Inserts typed text, leaving out control characters other than newline and tab (Enter
    /// arrives as a key, and some hosts also type it as "\r").
    fn typeText(ed: *Editor, typed: []const u8, r: *Result) void {
        var i: usize = 0;
        while (i < typed.len) {
            var j = i;
            while (j < typed.len and allowed(typed[j])) j += 1;
            ed.insert(typed[i..j], r);
            i = j + 1;
        }
    }

    fn allowed(c: u8) bool {
        return (c >= 0x20 and c != 0x7f) or c == '\n' or c == '\t';
    }

    /// Inserts `bytes` at the caret and moves the caret past them. What does not fit is cut at
    /// a code point boundary and dropped.
    fn insert(ed: *Editor, bytes: []const u8, r: *Result) void {
        var n: usize = @min(bytes.len, ed.b.free());
        // Back off a cut inside a UTF-8 sequence.
        while (n < bytes.len and n > 0 and bytes[n] & 0xc0 == 0x80) n -= 1;
        r.full = r.full or n < bytes.len;
        if (n == 0) return;
        ed.b.insert(ed.caret, bytes[0..n]) catch unreachable;
        ed.caret += @intCast(n);
        r.changed = true;
    }

    /// Removes `[from, to)`; the caret goes to `from`.
    fn remove(ed: *Editor, from: u32, to: u32, r: *Result) void {
        ed.b.delete(from, to);
        ed.caret = from;
        r.changed = r.changed or from < to;
    }
};

// ---------------------------------------------------------------------------------------------

const testing = std.testing;
const Interaction = @import("../../interact/interaction.zig").Interaction;
const Focus = @import("../../interact/focus.zig").Focus;
const Replay = @import("../../core/input.zig").Replay;

pub const field = Id.from("field");

/// Replays `src` into `ed` as the focused widget `field`, one `update` per frame. Returns the
/// results of the frames, OR-ed.
pub fn replay(ed: *Editor, src: []const u8) !Result {
    return replayLaidOut(ed, src, null);
}

/// As `replay`, with the text laid out before every frame in a box `width` px wide, each byte
/// one 10 px glyph and each line 10 px high (ASCII only), and the layout passed as the view.
pub fn replayLaidOut(ed: *Editor, src: []const u8, width: ?f32) !Result {
    const golden = @import("../layout/golden.zig");
    const lines = @import("../layout/lines.zig");
    var para: golden.Para = .{};
    var text_buf: [256]u8 = undefined;
    var events: [64]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text_buf, .events = &events, .contacts = &contacts };
    var r: Replay = .{ .src = src };
    const it: Interaction = .{ .focus = @backingInt(field) };
    const fo: Focus = .{};
    var all: Result = .{};
    while (try r.next(buf)) |in| {
        const k = Keyboard.route(&it, &fo, in);
        var cx: Context = .{};
        if (width) |w| {
            const t = ed.text();
            para.fixed(t, 10);
            try lines.breakLines(&para.g, t, w, &para.l);
            lines.place(&para.l, &para.g, t, &.{.{ .ascent = 8, .descent = 2 }}, .{ .width = w });
            cx.view = .{ .l = &para.l, .g = &para.g, .text = t };
        }
        const one = ed.update(&k, field, cx);
        all.changed = all.changed or one.changed;
        all.full = all.full or one.full;
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
    ed2.caret = 4; // after e + combining acute
    _ = try replay(&ed2,
        \\frame
        \\press 42
    );
    try testing.expectEqualStrings("ab", ed2.text());
    try testing.expectEqual(1, ed2.caret);
    ed2.caret = 0;
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
        \\press 74 shift
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
    ed.caret = 4; // after "abcd", x = 40
    _ = try replayLaidOut(&ed,
        \\frame
        \\press 81
    , 60);
    try testing.expectEqual(7, ed.caret); // "x" is short: its end, before the newline
    _ = try replayLaidOut(&ed,
        \\frame
        \\press 81
        \\text _
    , 60);
    // Back at x = 40 on the last line, not at x = 10.
    try testing.expectEqualStrings("abcde x\nfghi_j", ed.text());
    // End then Home on a laid-out line; Up past the first line goes to the start.
    _ = try replayLaidOut(&ed,
        \\frame
        \\press 82
        \\press 82
        \\press 77
    , 60);
    try testing.expectEqual(5, ed.caret); // before the hanging space
    _ = try replayLaidOut(&ed,
        \\frame
        \\press 82
    , 60);
    try testing.expectEqual(0, ed.caret);
}
