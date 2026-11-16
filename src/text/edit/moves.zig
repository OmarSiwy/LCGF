//! Where the caret goes: byte offsets of the next and previous stop in a text. Tier 0.
//!
//! Every function reads one contiguous text (`Buffer.text`) and an offset at a grapheme
//! boundary, and returns another boundary; nothing is stored. Grapheme boundaries come from
//! src/text/unicode/grapheme.zig (UAX #29 3.1.1). A boundary depends only on the text before it
//! and the code point after it, so the walk back starts at a line start, not at the text's
//! start (a newline is always a boundary, GB4/GB5).

const std = @import("std");
const Graphemes = @import("../unicode/grapheme.zig").Graphemes;

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
