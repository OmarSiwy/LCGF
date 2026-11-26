//! Whitespace preparation with reversible source offsets. Tier 0, caller-owned bytes and
//! offset columns. Normalization is explicit: shaped clusters index `Buffer.bytes`, and
//! editor/selection offsets convert through `sourceOffset` and `displayOffset`.

const std = @import("std");

pub const Mode = enum {
    /// Leave every byte intact; tabs are positioned later by the line breaker.
    preserve,
    /// Collapse ASCII spaces, tabs and segment breaks to one space, trimming both ends.
    collapse,
    /// Collapse spaces and tabs, normalize CR/CRLF to LF, and preserve explicit newlines.
    preserve_breaks,
};

pub const Buffer = struct {
    bytes: []u8,
    /// At least output bytes + 1 entries. The final entry maps the end caret to source.len.
    source: []u32,
    len: u32 = 0,

    /// Writes the normalized text and byte-to-source map. A short buffer returns NoSpace
    /// after a valid prefix; no out-of-bounds writes and no allocation or retained source.
    pub fn prepare(b: *Buffer, text: []const u8, mode: Mode) error{NoSpace}![]const u8 {
        b.len = 0;
        var i: usize = 0;
        var pending: ?u32 = null;
        while (i < text.len) {
            const cp = text[i];
            if (mode != .preserve and (cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r' or cp == 0x0c)) {
                const at: u32 = @intCast(i);
                const newline = cp == '\n' or cp == '\r';
                i += 1;
                if (cp == '\r' and i < text.len and text[i] == '\n') i += 1;
                if (mode == .preserve_breaks and newline) {
                    pending = null;
                    try b.append('\n', at);
                } else if (pending == null) pending = at;
                continue;
            }
            if (pending) |at| {
                if (b.len > 0 and b.bytes[b.len - 1] != '\n') try b.append(' ', at);
                pending = null;
            }
            try b.append(cp, @intCast(i));
            i += 1;
        }
        if (b.source.len <= b.len) return error.NoSpace;
        b.source[b.len] = @intCast(text.len);
        return b.bytes[0..b.len];
    }

    fn append(b: *Buffer, byte: u8, source: u32) error{NoSpace}!void {
        if (b.len == b.bytes.len or b.len + 1 >= b.source.len) return error.NoSpace;
        b.bytes[b.len] = byte;
        b.source[b.len] = source;
        b.len += 1;
    }

    /// The original byte at a displayed byte/caret, clamped to the output end.
    pub fn sourceOffset(b: *const Buffer, display: u32) u32 {
        return b.source[@min(display, b.len)];
    }

    /// First displayed byte/caret at or after an original offset. Collapsed source bytes
    /// map to the following displayed position, so moving through a collapsed gap terminates.
    pub fn displayOffset(b: *const Buffer, source: u32) u32 {
        var lo: u32 = 0;
        var hi = b.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (b.source[mid] < source) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
};

test "collapsed and preserved segment breaks keep source selection offsets" {
    var bytes: [64]u8 = undefined;
    var source: [65]u32 = undefined;
    var b: Buffer = .{ .bytes = &bytes, .source = &source };
    const text = "  one\t \r\n two  \n\nthree  ";
    try std.testing.expectEqualStrings("one two three", try b.prepare(text, .collapse));
    try std.testing.expectEqual(2, b.sourceOffset(0));
    try std.testing.expectEqual(std.mem.indexOf(u8, text, "two").?, b.sourceOffset(4));
    try std.testing.expectEqual(4, b.displayOffset(@intCast(std.mem.indexOf(u8, text, "two").?)));
    try std.testing.expectEqual(text.len, b.sourceOffset(1000));
    try std.testing.expectEqualStrings("one\ntwo\n\nthree", try b.prepare(text, .preserve_breaks));
    try std.testing.expectEqualStrings(text, try b.prepare(text, .preserve));
    try std.testing.expectEqual(5, b.sourceOffset(5));
    var small: [2]u8 = undefined;
    b.bytes = &small;
    try std.testing.expectError(error.NoSpace, b.prepare("abc", .preserve));
    try std.testing.expectEqual(2, b.len);
}
