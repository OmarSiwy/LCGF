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
    /// caret, Backspace and Delete remove the grapheme before and after it, Enter inserts a
    /// newline. Nothing happens unless `id` is focused.
    pub fn update(ed: *Editor, k: *const Keyboard, id: Id) Result {
        var r: Result = .{};
        var it = k.events(id);
        while (it.next()) |e| {
            if (e.kind == .text) {
                ed.typeText(k.in.typed(e), &r);
                continue;
            }
            if (e.kind == .release) continue;
            const t = ed.text();
            if (e.code == ed.keys.backspace) {
                ed.remove(moves.prevGrapheme(t, ed.caret), ed.caret, &r);
            } else if (e.code == ed.keys.delete) {
                ed.remove(ed.caret, moves.nextGrapheme(t, ed.caret), &r);
            } else if (e.code == ed.keys.enter or e.code == ed.keys.keypad_enter) {
                ed.insert("\n", &r);
            }
        }
        return r;
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
        const one = ed.update(&k, field);
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
    const r = ed.update(&k, field);
    try testing.expect(r.full);
    try testing.expectEqualStrings("a\tb\xc3\xa9", ed.text());
    try testing.expectEqual(5, ed.caret);
    // Another widget's input does nothing.
    try testing.expect(!ed.update(&k, Id.from("other")).changed);
}
