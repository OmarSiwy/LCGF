//! Where the caret goes: byte offsets of the next and previous stop in a text. Tier 0.
//!
//! Every function reads one contiguous text (`Buffer.text`) and an offset at a grapheme
//! boundary, and returns another boundary; nothing is stored. Grapheme boundaries come from
//! src/text/unicode/grapheme.zig (UAX #29 3.1.1). A boundary depends only on the text before it
//! and the code point after it, so the walk back starts at a line start, not at the text's
//! start (a newline is always a boundary, GB4/GB5).

const std = @import("std");
const Graphemes = @import("../unicode/grapheme.zig").Graphemes;
const Words = @import("../unicode/word.zig").Words;
const property = @import("../unicode/property.zig");
const utf8 = @import("../unicode/utf8.zig");
const lines = @import("../layout/lines.zig");
const query = @import("../layout/query.zig");

/// The grapheme boundary after `at`, or `text.len` at the end.
pub fn nextGrapheme(text: []const u8, at: u32) u32 {
    var it: Graphemes = .{ .text = text[at..] };
    const e = it.next() orelse 0;
    return at + @as(u32, @intCast(e));
}

/// The grapheme boundary before `at`, or 0 at the start.
pub fn prevGrapheme(text: []const u8, at: u32) u32 {
    // A newline before `at - 1` ends a grapheme: start the walk after it.
    const from: u32 = if (at < 2) 0 else if (std.mem.lastIndexOfScalar(u8, text[0 .. at - 1], '\n')) |nl| @intCast(nl + 1) else 0;
    var it: Graphemes = .{ .text = text[from..at] };
    var prev: u32 = from;
    var last: u32 = from;
    while (it.next()) |e| {
        prev = last;
        last = from + @as(u32, @intCast(e));
    }
    return prev;
}

/// A word segment (UAX #29 4.1.1) is a word to stop at unless it is white space or a newline.
fn isWord(text: []const u8, start: usize) bool {
    const cp = utf8.decode(text, start).cp;
    return switch (property.word(cp).wb) {
        .WSegSpace, .Newline, .CR, .LF => false,
        else => cp != '\t',
    };
}

// ponytail: both word walks scan the text from its start, O(n) per keystroke; start at the
// paragraph's start if fields get long enough for it to show.

/// The end of the word at or after `at` (Ctrl+Right): spaces are skipped, and a caret inside
/// a word goes to its end. `text.len` when no word follows.
pub fn nextWord(text: []const u8, at: u32) u32 {
    var it: Words = .{ .text = text };
    var start: usize = 0;
    while (it.next()) |e| : (start = e) {
        if (e > at and isWord(text, start)) return @intCast(e);
    }
    return @intCast(text.len);
}

/// The start of the word before `at` (Ctrl+Left): spaces are skipped, and a caret inside a
/// word goes to its start. 0 when no word precedes.
pub fn prevWord(text: []const u8, at: u32) u32 {
    var it: Words = .{ .text = text };
    var start: usize = 0;
    var best: u32 = 0;
    while (it.next()) |e| : (start = e) {
        if (start >= at) break;
        if (isWord(text, start)) best = @intCast(start);
    }
    return best;
}

/// The start of the line (between newlines) holding `at`.
pub fn lineStart(text: []const u8, at: u32) u32 {
    const nl = std.mem.lastIndexOfScalar(u8, text[0..at], '\n') orelse return 0;
    return @intCast(nl + 1);
}

/// The end of the line holding `at`, before its newline.
pub fn lineEnd(text: []const u8, at: u32) u32 {
    const nl = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse return @intCast(text.len);
    return @intCast(nl);
}

/// A paragraph laid out by src/text/layout/ (`lines.place` has run) from `text`.
pub const View = struct {
    l: *const lines.Lines,
    g: *const lines.Glyphs,
    text: []const u8,

    /// The first stop of the laid-out line holding the caret at `at` (Home).
    pub fn home(v: View, at: u32) u32 {
        return v.l.start[query.caret(v.l, v.g, v.text, at).line];
    }

    /// The last stop of the laid-out line holding the caret at `at` (End): before a trailing
    /// space or newline, which belong to the line but are not stops on it.
    pub fn end(v: View, at: u32) u32 {
        var s: query.Stops = .init(v.l, v.g, v.text, query.caret(v.l, v.g, v.text, at).line);
        var last: u32 = at;
        while (s.next()) |stop| last = stop.offset;
        return last;
    }

    /// The stop on the line `dir` lines (-1 up, +1 down) from the caret at `at`, nearest to x
    /// `goal` px; the text's start or end past the first or last line.
    pub fn vertical(v: View, at: u32, dir: i2, goal: f32) u32 {
        const c = query.caret(v.l, v.g, v.text, at);
        const k = @as(i64, c.line) + dir;
        if (k < 0) return 0;
        if (k >= v.l.len) return @intCast(v.text.len);
        const line: u32 = @intCast(k);
        return query.hit(v.l, v.g, v.text, goal, v.l.top[line] + v.l.height[line] / 2);
    }

    /// The caret's x at `at`, px from the paragraph's left edge.
    pub fn x(v: View, at: u32) f32 {
        return query.caret(v.l, v.g, v.text, at).x;
    }
};

const testing = std.testing;

test "grapheme stops: combining marks, flags, CR LF and emoji sequences are one step" {
    const text = "e\u{301}\u{1F1E9}\u{1F1EA}\r\n\u{1F468}\u{200D}\u{1F469}x";
    const stops = [_]u32{ 0, 3, 11, 13, 24, 25 };
    for (stops[0 .. stops.len - 1], stops[1..]) |a, b| {
        try testing.expectEqual(b, nextGrapheme(text, a));
        try testing.expectEqual(a, prevGrapheme(text, b));
    }
    try testing.expectEqual(25, nextGrapheme(text, 25));
    try testing.expectEqual(0, prevGrapheme(text, 0));
    // The walk back from after a newline starts at the line.
    try testing.expectEqual(2, prevGrapheme("a\nb", 3));
    try testing.expectEqual(1, prevGrapheme("a\nb", 2));
}

test "word stops skip spaces and punctuation stays a word of its own" {
    const text = "Can't stop  3.14, now";
    // Right: to the end of each word in turn.
    const ends = [_]u32{ 5, 10, 16, 17, 21, 21 };
    var at: u32 = 0;
    for (ends) |e| {
        at = nextWord(text, at);
        try testing.expectEqual(e, at);
    }
    // Left: to the start of each word, from inside one to its own start.
    const starts = [_]u32{ 18, 16, 12, 6, 0, 0 };
    for (starts) |s| {
        at = prevWord(text, at);
        try testing.expectEqual(s, at);
    }
    try testing.expectEqual(6, prevWord(text, 8));
    try testing.expectEqual(10, nextWord(text, 8));
    try testing.expectEqual(0, nextWord("", 0));
    try testing.expectEqual(3, nextWord("  \n", 0));
}

test "line stops: between newlines, and on laid-out lines with Up and Down" {
    const text = "ab cd\nef";
    try testing.expectEqual(0, lineStart(text, 5));
    try testing.expectEqual(5, lineEnd(text, 1));
    try testing.expectEqual(6, lineStart(text, 8));
    try testing.expectEqual(8, lineEnd(text, 6));

    const golden = @import("../layout/golden.zig");
    var t: golden.Para = .{};
    t.fixed(text, 10);
    try lines.breakLines(&t.g, text, 25, &t.l);
    lines.place(&t.l, &t.g, text, &.{.{ .ascent = 8, .descent = 2 }}, .{ .width = 25 });
    // "ab " | "cd\n" | "ef"
    const v: View = .{ .l = &t.l, .g = &t.g, .text = text };
    try testing.expectEqual(0, v.home(1));
    try testing.expectEqual(2, v.end(1)); // before the hanging space
    try testing.expectEqual(3, v.home(4));
    try testing.expectEqual(5, v.end(3)); // before the newline
    try testing.expectEqual(8, v.end(6));
    try testing.expectEqual(4, v.vertical(1, 1, v.x(1)));
    try testing.expectEqual(7, v.vertical(4, 1, v.x(4)));
    try testing.expectEqual(8, v.vertical(7, 1, v.x(7)));
    try testing.expectEqual(0, v.vertical(1, -1, v.x(1)));
    try testing.expectEqual(1, v.vertical(4, -1, v.x(4)));
}
