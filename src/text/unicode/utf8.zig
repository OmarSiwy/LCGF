//! UTF-8 decoding for the Unicode algorithms. Tier 0.

const std = @import("std");

pub const Decoded = struct { cp: u21, len: u3 };

/// The code point starting at `text[i]`. A byte that does not start a well-formed sequence
/// (truncated, overlong, a surrogate, above U+10FFFF) decodes as U+FFFD of length 1, so every
/// byte offset reached by stepping is inside `text` and decoding never fails.
pub fn decode(text: []const u8, i: usize) Decoded {
    const bad: Decoded = .{ .cp = 0xFFFD, .len = 1 };
    const b0 = text[i];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    const len: u3 = if (b0 & 0xE0 == 0xC0) 2 else if (b0 & 0xF0 == 0xE0) 3 else if (b0 & 0xF8 == 0xF0) 4 else return bad;
    if (text.len - i < len) return bad;
    var cp: u21 = b0 & (@as(u8, 0x7F) >> len);
    for (text[i + 1 ..][0 .. len - 1]) |c| {
        if (c & 0xC0 != 0x80) return bad;
        cp = cp << 6 | (c & 0x3F);
    }
    const min = [5]u21{ 0, 0, 0x80, 0x800, 0x10000 };
    if (cp < min[len] or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return bad;
    return .{ .cp = cp, .len = len };
}

test decode {
    try std.testing.expectEqual(Decoded{ .cp = 'a', .len = 1 }, decode("a", 0));
    try std.testing.expectEqual(Decoded{ .cp = 0xE9, .len = 2 }, decode("\xC3\xA9", 0));
    try std.testing.expectEqual(Decoded{ .cp = 0x1F600, .len = 4 }, decode("\xF0\x9F\x98\x80", 0));
    try std.testing.expectEqual(Decoded{ .cp = 0xFFFD, .len = 1 }, decode("\xC3", 0)); // truncated
    try std.testing.expectEqual(Decoded{ .cp = 0xFFFD, .len = 1 }, decode("\xC0\x80", 0)); // overlong
    try std.testing.expectEqual(Decoded{ .cp = 0xFFFD, .len = 1 }, decode("\xED\xA0\x80", 0)); // surrogate
    try std.testing.expectEqual(Decoded{ .cp = 0xFFFD, .len = 1 }, decode("\xF4\x90\x80\x80", 0)); // > 10FFFF
    try std.testing.expectEqual(Decoded{ .cp = 0xFFFD, .len = 1 }, decode("\xFF", 0));
}
