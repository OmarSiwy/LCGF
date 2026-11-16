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
const types = @import("../../core/types.zig");
const bidi = @import("../unicode/bidi.zig");

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

/// The word segment holding `at` (a double click): from its start to its end, spaces being a
/// segment of their own. At the end of the text, the last segment.
pub fn wordAt(text: []const u8, at: u32) [2]u32 {
    var it: Words = .{ .text = text };
    var seg: [2]u32 = .{ 0, 0 };
    while (it.next()) |e| {
        seg = .{ seg[1], @intCast(e) };
        if (e > at) break;
    }
    return seg;
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

    /// The stop nearest a click at (`px`, `py`), px from the paragraph's top left.
    pub fn hit(v: View, px: f32, py: f32) u32 {
        return query.hit(v.l, v.g, v.text, px, py);
    }

    /// A caret at `at` as a 1 px wide rectangle the height of its line, px from the
    /// paragraph's top left.
    pub fn caretRect(v: View, at: u32) types.Rect {
        const c = query.caret(v.l, v.g, v.text, at);
        return .{ .x0 = c.x, .y0 = c.top, .x1 = c.x + 1, .y1 = c.top + c.height };
    }

    /// The caret's x at `at`, px from the paragraph's left edge.
    pub fn x(v: View, at: u32) f32 {
        return query.caret(v.l, v.g, v.text, at).x;
    }
};

/// Columns for `visual`, each as long as the longest line it moves over in code points, plus
/// one row (`mem.Carver.columns` carves them all at once). A longer line moves logically.
pub const BidiScratch = struct {
    cps: []u21,
    orig: []property.BidiClass,
    levels: []u8,
    cls: []property.BidiClass,
    next: []u32,
    pair: []u32,
    /// Per grapheme of the line: its byte offset (one row more for the line's end), its first
    /// code point, its level, and the visual order and its inverse.
    start: []u32,
    first: []u32,
    glevel: []u8,
    order: []u32,
    inv: []u32,
};

/// Left and Right in visual order (UAX #9 L1, L2), for a line with right-to-left text in it:
/// the caret at `at` moves to the stop next to it on screen in direction `dir` (+1 right, -1
/// left), not to the next offset. Lines are those between newlines, each a bidi paragraph.
///
/// Each caret stop has one place on screen, taken from the grapheme after it: the left edge of
/// a left-to-right grapheme, the right edge of a right-to-left one (at the line's end, the
/// trailing edge of the last grapheme). A move goes to the stop whose place is the nearest one
/// in `dir`, so repeated moves visit places strictly left to right, never stall, and stop at
/// the line's visual end; past it they go to the next line in the paragraph's direction, or
/// the previous line against it. Two offsets with one place (at a direction change) are one
/// stop. `base` is the paragraph's direction, as given to `lines.reorder`. Returns null when
/// the line is all left to right (logical moves are the same) or too long for `s`.
pub fn visual(text: []const u8, at: u32, dir: i2, base: bidi.Direction, s: BidiScratch) ?u32 {
    const from = lineStart(text, at);
    const to = lineEnd(text, at);
    // Graphemes of the line and their code points.
    var it: Graphemes = .{ .text = text[from..to] };
    var n: u32 = 0; // code points
    var ng: u32 = 0; // graphemes
    var pos: u32 = from;
    while (it.next()) |e| {
        if (ng + 1 >= s.start.len) return null;
        s.start[ng] = pos;
        s.first[ng] = n;
        ng += 1;
        const end = from + @as(u32, @intCast(e));
        while (pos < end) {
            if (n >= s.cps.len) return null;
            const d = utf8.decode(text, pos);
            s.cps[n] = d.cp;
            n += 1;
            pos += d.len;
        }
    }
    s.start[ng] = to;
    const orig = s.orig[0..n];
    bidi.classes(s.cps[0..n], orig);
    const scratch: bidi.Scratch = .{ .cls = s.cls, .next = s.next, .pair = s.pair };
    const para = bidi.baseLevel(orig, scratch, base);
    bidi.resolve(orig, s.cps[0..n], para, s.levels, scratch);
    bidi.lineLevels(orig, s.levels[0..n], para);
    var odd = para;
    for (s.first[0..ng], s.glevel[0..ng]) |f, *l| {
        l.* = s.levels[f];
        odd |= l.*;
    }
    if (odd & 1 == 0) return null;
    bidi.reorder(s.glevel[0..ng], s.order);
    for (s.order[0..ng], 0..) |g, v| s.inv[g] = @intCast(v);

    var here: u32 = 0;
    for (s.start[0 .. ng + 1], 0..) |off, b| {
        if (off == at) here = place(s, ng, @intCast(b));
    }
    // The nearest place in `dir`, and the stop holding it.
    var best: ?u32 = null;
    var best_place: u32 = 0;
    for (s.start[0 .. ng + 1], 0..) |off, b| {
        const p = place(s, ng, @intCast(b));
        const ahead = if (dir > 0) p > here else p < here;
        const nearer = best == null or (if (dir > 0) p < best_place else p > best_place);
        if (ahead and nearer) {
            best = off;
            best_place = p;
        }
    }
    if (best) |b| return b;
    // At the line's visual end: on to the next line along the paragraph's direction.
    const forward = (dir > 0) == (para & 1 == 0);
    if (forward) return if (to < text.len) to + 1 else at;
    return if (from > 0) from - 1 else at;
}

/// Where stop `b` (0 to `ng`) of the line is on screen, as a boundary between visual
/// positions 0 to `ng`.
fn place(s: BidiScratch, ng: u32, b: u32) u32 {
    if (ng == 0) return 0;
    if (b < ng) return s.inv[b] + (s.glevel[b] & 1);
    const g = ng - 1;
    return s.inv[g] + 1 - (s.glevel[g] & 1);
}

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

test "wordAt: the segment under a double click" {
    const text = "one  two";
    try testing.expectEqual([2]u32{ 0, 3 }, wordAt(text, 0));
    try testing.expectEqual([2]u32{ 0, 3 }, wordAt(text, 2));
    try testing.expectEqual([2]u32{ 3, 5 }, wordAt(text, 3));
    try testing.expectEqual([2]u32{ 5, 8 }, wordAt(text, 7));
    try testing.expectEqual([2]u32{ 5, 8 }, wordAt(text, 8));
    try testing.expectEqual([2]u32{ 0, 0 }, wordAt("", 0));
}

fn walk(text: []const u8, from: u32, dir: i2, steps: []u32, s: BidiScratch) void {
    var at = from;
    for (steps) |*st| {
        at = visual(text, at, dir, .auto, s) orelse at;
        st.* = at;
    }
}

test "visual: Right and Left in screen order over mixed directions" {
    const mem = @import("../../core/mem.zig");
    var raw: [8192]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    const s = carver.columns(BidiScratch, 16);
    // "abc " then Hebrew alef bet gimel, two bytes each: on screen "abc גבא".
    const ltr = "abc \u{5D0}\u{5D1}\u{5D2}";
    var got: [8]u32 = undefined;
    walk(ltr, 0, 1, &got, s);
    // Right: over "abc " (0 to 3), then into the Hebrew from its left end (10 is the text's end,
    // left of gimel), right to left in offsets, and it stays at the line's end (4).
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 10, 8, 6, 4, 4 }, &got);
    walk(ltr, 4, -1, &got, s);
    try testing.expectEqualSlices(u32, &.{ 6, 8, 10, 3, 2, 1, 0, 0 }, &got);
    // A right-to-left paragraph: "\u{5D0}\u{5D1} ab" shows as "ab בא", the caret starting at
    // the right. Left walks to the left end.
    const rtl = "\u{5D0}\u{5D1} ab";
    var got2: [6]u32 = undefined;
    walk(rtl, 0, -1, &got2, s);
    try testing.expectEqualSlices(u32, &.{ 2, 4, 7, 6, 5, 5 }, &got2);
    walk(rtl, 5, 1, &got2, s);
    try testing.expectEqualSlices(u32, &.{ 6, 7, 4, 2, 0, 0 }, &got2);
    // All left to right: no visual move, the caller moves logically.
    try testing.expectEqual(null, visual("abc", 1, 1, .auto, s));
    // Too long for the scratch: logical too.
    try testing.expectEqual(null, visual("\u{5D0}bcdefghijklmnopqrstu", 0, 1, .auto, s));
    // Past the visual end of a line: on to the next line, or back to the previous one.
    const two = "a\u{5D0}\nb";
    try testing.expectEqual(4, visual(two, 1, 1, .auto, s).?);
    try testing.expectEqual(0, visual(two, 3, -1, .auto, s).?);
    // A given direction: "abc" in a right-to-left paragraph is all left to right but its
    // line ends are swapped, so Right from the end goes on to the previous line.
    try testing.expectEqual(null, visual("abc", 1, 1, .ltr, s));
    try testing.expectEqual(2, visual("abc", 1, 1, .rtl, s).?);
    try testing.expectEqual(1, visual("a\nbc", 4, 1, .rtl, s).?);
}
