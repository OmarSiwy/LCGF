//! Columns carved from a caller-owned buffer. The library never allocates: the caller hands over
//! one buffer and every column is a slice of it.
//!
//! Tier 0: imports only `std`.

const std = @import("std");

/// Each column starts on its own cache line.
pub const column_align = 64;

/// Bump pointer over a caller-owned buffer.
pub const Carver = struct {
    buf: []align(column_align) u8,
    off: usize = 0,

    /// Next `n` rows of `T`, zeroed. The carved size is rounded up to `column_align`, so the
    /// next column starts on a fresh cache line. Asserts the buffer is large enough.
    pub fn slice(c: *Carver, comptime T: type, n: usize) []T {
        const bytes = std.mem.alignForward(usize, n * @sizeOf(T), column_align);
        const start = c.off;
        c.off += bytes;
        std.debug.assert(c.off <= c.buf.len);
        @memset(c.buf[start..c.off], 0);
        const p: [*]T = @ptrCast(@alignCast(c.buf.ptr + start));
        return p[0..n];
    }
};

test "Carver.slice carves zeroed, cache-line aligned slices in order" {
    var buf: [256]u8 align(column_align) = @splat(0xaa);
    var c: Carver = .{ .buf = &buf };

    const a = c.slice(u32, 3);
    try std.testing.expectEqual(3, a.len);
    try std.testing.expectEqual(@intFromPtr(&buf), @intFromPtr(a.ptr));
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, a);
    try std.testing.expectEqual(64, c.off);

    const b = c.slice(f32, 20); // 80 bytes rounds up to 128
    try std.testing.expectEqual(@intFromPtr(&buf) + 64, @intFromPtr(b.ptr));
    try std.testing.expectEqual(192, c.off);
    for (b) |x| try std.testing.expectEqual(0, x);

    const empty = c.slice(u64, 0);
    try std.testing.expectEqual(0, empty.len);
    try std.testing.expectEqual(192, c.off);

    // Bytes past the carved, rounded-up size are untouched.
    try std.testing.expectEqual(0xaa, buf[192]);
}
