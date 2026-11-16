//! A text buffer with a gap, over bytes the caller owns. Tier 0: no allocator.
//!
//! The text is `buf[0..gap]` followed by `buf[buf.len - after..]`; the bytes between are free.
//! An edit moves the gap to where it happens (one `memmove` of the bytes in between) and then
//! writes into it, so a run of keystrokes at one caret costs a copy per keystroke of only what
//! was typed. Layout, shaping and the Unicode iterators read one contiguous slice: `text()`
//! moves the gap to the end and returns `buf[0..len]`. Offsets are bytes into the text, as
//! everywhere in src/text/; UTF-8 is the caller's to keep whole (the editor only cuts at
//! grapheme boundaries).

const std = @import("std");

pub const Buffer = struct {
    /// The storage, and its capacity in bytes.
    buf: []u8,
    /// Bytes of text before the gap (the gap starts here).
    gap: u32 = 0,
    /// Bytes of text after the gap, at the end of `buf`.
    after: u32 = 0,

    pub const Error = error{NoSpace};

    /// A buffer over `buf` holding a copy of `initial`.
    pub fn init(buf: []u8, initial: []const u8) Error!Buffer {
        std.debug.assert(buf.len <= std.math.maxInt(u32));
        if (initial.len > buf.len) return error.NoSpace;
        @memcpy(buf[0..initial.len], initial);
        return .{ .buf = buf, .gap = @intCast(initial.len) };
    }

    pub fn len(b: *const Buffer) u32 {
        return b.gap + b.after;
    }

    /// Free bytes.
    pub fn free(b: *const Buffer) u32 {
        return @as(u32, @intCast(b.buf.len)) - b.len();
    }

    /// Moves the gap so that it starts at text offset `at`.
    pub fn moveGap(b: *Buffer, at: u32) void {
        std.debug.assert(at <= b.len());
        const cap: u32 = @intCast(b.buf.len);
        if (at < b.gap) {
            // Text [at, gap) moves to just before the bytes after the gap.
            const n = b.gap - at;
            const to = cap - b.after - n;
            std.mem.copyBackwards(u8, b.buf[to..][0..n], b.buf[at..][0..n]);
            b.gap = at;
            b.after += n;
        } else if (at > b.gap) {
            // Text [gap, at) moves from after the gap to before it.
            const n = at - b.gap;
            const from = cap - b.after;
            std.mem.copyForwards(u8, b.buf[b.gap..][0..n], b.buf[from..][0..n]);
            b.gap = at;
            b.after -= n;
        }
    }

    /// Inserts `bytes` at offset `at`. Nothing changes on `error.NoSpace`.
    pub fn insert(b: *Buffer, at: u32, bytes: []const u8) Error!void {
        if (bytes.len > b.free()) return error.NoSpace;
        b.moveGap(at);
        @memcpy(b.buf[b.gap..][0..bytes.len], bytes);
        b.gap += @intCast(bytes.len);
    }

    /// Removes the text in `[from, to)`.
    pub fn delete(b: *Buffer, from: u32, to: u32) void {
        std.debug.assert(from <= to and to <= b.len());
        b.moveGap(to);
        b.gap = from;
    }

    /// Replaces `[from, to)` with `bytes`. Nothing changes on `error.NoSpace`.
    pub fn replace(b: *Buffer, from: u32, to: u32, bytes: []const u8) Error!void {
        std.debug.assert(from <= to and to <= b.len());
        if (bytes.len > b.free() + (to - from)) return error.NoSpace;
        b.delete(from, to);
        b.insert(from, bytes) catch unreachable;
    }

    /// The whole text as one slice, valid until the next edit. Moves the gap to the end.
    pub fn text(b: *Buffer) []const u8 {
        b.moveGap(b.len());
        return b.buf[0..b.gap];
    }

    /// The text `[from, to)` copied to `out`, which must be large enough. The gap stays.
    pub fn copy(b: *const Buffer, from: u32, to: u32, out: []u8) []u8 {
        std.debug.assert(from <= to and to <= b.len());
        const n = to - from;
        const head = @min(to, b.gap) -| from; // bytes of the range before the gap
        const tail_from = @max(from, b.gap) - b.gap; // where the rest starts after the gap
        const after_at = @as(u32, @intCast(b.buf.len)) - b.after;
        @memcpy(out[0..head], b.buf[from..][0..head]);
        @memcpy(out[head..n], b.buf[after_at + tail_from ..][0 .. n - head]);
        return out[0..n];
    }
};

const testing = std.testing;

test "insert and delete around a moving gap keep the text" {
    var raw: [16]u8 = undefined;
    var b = try Buffer.init(&raw, "hello");
    try b.insert(5, " world");
    try testing.expectEqualStrings("hello world", b.text());
    try b.insert(0, ">");
    b.delete(6, 7); // the space
    try b.insert(6, "_");
    try testing.expectEqual(7, b.gap);
    var out: [16]u8 = undefined;
    // A copy across the gap, before it and after it.
    try testing.expectEqualStrings("lo_wo", b.copy(4, 9, &out));
    try testing.expectEqualStrings(">he", b.copy(0, 3, &out));
    try testing.expectEqualStrings("rld", b.copy(9, 12, &out));
    try testing.expectEqualStrings(">hello_world", b.text());
    try testing.expectEqual(4, b.free());
    try testing.expectError(error.NoSpace, b.insert(3, "12345"));
    try testing.expectEqualStrings(">hello_world", b.text());
    try b.replace(1, 6, "bye");
    try testing.expectEqualStrings(">bye_world", b.text());
    try testing.expectError(error.NoSpace, b.replace(0, 1, "12345678"));
    try b.replace(0, 1, "1234567");
    try testing.expectEqualStrings("1234567bye_world", b.text());
    try testing.expectEqual(0, b.free());
    try testing.expectError(error.NoSpace, Buffer.init(raw[0..2], "abc"));
}

test "moveGap against a reference over random edits" {
    var prng = std.Random.DefaultPrng.init(7);
    const rng = prng.random();
    var raw: [64]u8 = undefined;
    var b = try Buffer.init(&raw, "");
    var ref: [64]u8 = undefined;
    var n: usize = 0;
    for (0..2000) |_| {
        const at = rng.uintAtMost(u32, b.len());
        if (rng.boolean() and n < 60) {
            const c: u8 = 'a' + rng.uintLessThan(u8, 26);
            try b.insert(at, &.{c});
            std.mem.copyBackwards(u8, ref[at + 1 .. n + 1], ref[at..n]);
            ref[at] = c;
            n += 1;
        } else {
            const to = at + @min(rng.uintAtMost(u32, 3), b.len() - at);
            b.delete(at, to);
            std.mem.copyForwards(u8, ref[at .. n - (to - at)], ref[to..n]);
            n -= to - at;
        }
        var out: [64]u8 = undefined;
        try testing.expectEqualStrings(ref[0..n], b.copy(0, b.len(), &out));
    }
    try testing.expectEqualStrings(ref[0..n], b.text());
}
