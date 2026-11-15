//! Strings: frame-lifetime byte storage for text, so callers may pass temporaries. Text runs
//! refer to their bytes by `Span`, a u32 range into this buffer, not by pointer. Tier 0: the
//! caller owns the buffer. Ported from prototype/ui.zig ("Strings").

const std = @import("std");

/// A byte range in a frame's `Strings`.
pub const Span = struct { start: u32 = 0, bytes: u32 = 0 };

pub const Strings = struct {
    buf: []u8,
    len: u32 = 0,

    /// Copies `bytes` to the end of the buffer and returns where they landed.
    pub fn add(s: *Strings, bytes: []const u8) Span {
        std.debug.assert(bytes.len <= s.buf.len - s.len);
        const n: u32 = @intCast(bytes.len);
        @memcpy(s.buf[s.len..][0..n], bytes);
        const span: Span = .{ .start = s.len, .bytes = n };
        s.len += n;
        return span;
    }
    pub fn get(s: *const Strings, span: Span) []const u8 {
        return s.buf[span.start..][0..span.bytes];
    }
    /// Empties the storage for the next frame. Spans from the previous frame are invalid.
    pub fn reset(s: *Strings) void {
        s.len = 0;
    }
};

const testing = std.testing;

test "add copies bytes so the caller may pass a temporary; get returns them" {
    var buf: [32]u8 = undefined;
    var s: Strings = .{ .buf = &buf };
    var tmp = "hello".*;
    const a = s.add(&tmp);
    tmp = "XXXXX".*;
    const b = s.add("world!");
    try testing.expectEqual(Span{ .start = 0, .bytes = 5 }, a);
    try testing.expectEqual(Span{ .start = 5, .bytes = 6 }, b);
    try testing.expectEqualStrings("hello", s.get(a));
    try testing.expectEqualStrings("world!", s.get(b));
    try testing.expectEqual(11, s.len);
    try testing.expectEqual(Span{ .start = 11, .bytes = 0 }, s.add(""));
    s.reset();
    try testing.expectEqual(0, s.len);
    try testing.expectEqual(Span{ .start = 0, .bytes = 2 }, s.add("ok"));
}
