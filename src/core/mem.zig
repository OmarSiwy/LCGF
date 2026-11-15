//! Columns carved from a caller-owned buffer. The library never allocates: the caller hands over
//! one buffer and every column is a slice of it.
//!
//! Tier 0: imports only `std`.

const std = @import("std");

/// Each column starts on its own cache line.
pub const column_align = 64;

/// Bump pointer over a caller-owned buffer. With `buf == null` it only counts: sizing a buffer
/// and carving it run the same code, so the two cannot disagree.
pub const Carver = struct {
    buf: ?[]align(column_align) u8,
    off: usize = 0,

    /// Next `n` rows of `T`, zeroed. The carved size is rounded up to `column_align`, so the
    /// next column starts on a fresh cache line. Asserts the buffer is large enough. When counting
    /// it advances `off` and returns an empty slice.
    pub fn slice(c: *Carver, comptime T: type, n: usize) []T {
        const bytes = std.mem.alignForward(usize, n * @sizeOf(T), column_align);
        const start = c.off;
        c.off += bytes;
        const b = c.buf orelse return &.{};
        std.debug.assert(c.off <= b.len);
        @memset(b[start..c.off], 0);
        const p: [*]T = @ptrCast(@alignCast(b.ptr + start));
        return p[0..n];
    }

    /// Fills a struct whose fields are `[]T` or `[k][]T` with zeroed columns of `n` rows each,
    /// carved in field order.
    pub fn columns(c: *Carver, comptime S: type, n: usize) S {
        var out: S = undefined;
        const info = @typeInfo(S).@"struct";
        inline for (info.field_names, info.field_types) |name, FT| {
            switch (@typeInfo(FT)) {
                .pointer => |p| @field(out, name) = c.slice(p.child, n),
                .array => |a| inline for (0..a.len) |k| {
                    @field(out, name)[k] = c.slice(@typeInfo(a.child).pointer.child, n);
                },
                else => @compileError("column sets hold only []T and [k][]T fields"),
            }
        }
        return out;
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

test "Carver.columns carves every []T and [k][]T field in order" {
    const Cols = struct {
        id: []u32,
        rect: [4][]f32,
        flag: []u8,
    };
    var buf: [64 * 6]u8 align(column_align) = @splat(0xaa);
    var c: Carver = .{ .buf = &buf };
    const cols = c.columns(Cols, 5);

    try std.testing.expectEqual(64 * 6, c.off);
    try std.testing.expectEqual(@intFromPtr(&buf), @intFromPtr(cols.id.ptr));
    for (cols.rect, 0..) |r, k| {
        try std.testing.expectEqual(5, r.len);
        try std.testing.expectEqual(@intFromPtr(&buf) + 64 * (k + 1), @intFromPtr(r.ptr));
        for (r) |x| try std.testing.expectEqual(0, x);
    }
    try std.testing.expectEqual(@intFromPtr(&buf) + 64 * 5, @intFromPtr(cols.flag.ptr));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0 }, cols.flag);
    try std.testing.expectEqual(5, cols.id.len);
}

test "counting mode sizes a buffer with the same code that carves it" {
    const Cols = struct { x: []f32, link: [2][]u32 };
    const Owner = struct {
        a: Cols,
        names: []u8,

        fn build(c: *Carver, n: usize) @This() {
            return .{ .a = c.columns(Cols, n), .names = c.slice(u8, 3 * n) };
        }

        // Callable at comptime, as `Context.requiredBytes` is.
        fn requiredBytes(n: usize) usize {
            var counter: Carver = .{ .buf = null };
            _ = build(&counter, n);
            return counter.off;
        }
    };

    const need = comptime Owner.requiredBytes(30);
    try std.testing.expectEqual(4 * 128, need); // 120 B per column and 90 B of names, each to 128

    var counter: Carver = .{ .buf = null };
    const counted = Owner.build(&counter, 30);
    try std.testing.expectEqual(0, counted.a.x.len);
    try std.testing.expectEqual(need, counter.off);

    var buf: [need]u8 align(column_align) = undefined;
    var c: Carver = .{ .buf = &buf };
    const o = Owner.build(&c, 30);
    try std.testing.expectEqual(need, c.off);
    try std.testing.expectEqual(30, o.a.link[1].len);
    try std.testing.expectEqual(90, o.names.len);
}
