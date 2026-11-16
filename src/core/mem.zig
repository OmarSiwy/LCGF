//! Columns carved from a caller-owned buffer. The library never allocates: the caller hands over
//! one buffer and every column is a slice of it.
//!
//! Tier 0: imports only `std`.
//!
//! ## Budgeting limits
//!
//! A column of `n` rows of `T` costs `alignForward(n * @sizeOf(T), column_align)` bytes, so a
//! front end's buffer is the sum over its columns, and its owner computes it with a counting
//! `Carver` (`buf = null`) over the same build function that carves. Declare the buffer from that
//! number at comptime; do not hand-compute it.
//!
//! Measured with `Context.requiredBytes` of the prototype's runtime front end (`prototype/ui.zig`,
//! Zig 0.17.1), as the difference between two limits divided by the rows added; 4 and 8 lanes give
//! the same per-row costs:
//!
//! | Capacity | Bytes per row |
//! |---|---|
//! | node (two tree generations plus draw list) | 646 (about 0.65 KB) |
//! | text run | 150 |
//! | custom draw | 102 |
//! | anim + signal + memo, together | 52 |
//! | string byte | 2 (one buffer per generation, by construction) |
//!
//! Default `Limits` (4,096 nodes, 1,024 texts, 64 KB strings, ...) need 2,959,232 bytes at 4
//! lanes (8 lanes: 384 more, from padding), about 722 B per node all-in; `.{ .nodes = 1024,
//! .texts = 256 }` needs 859,520. Size limits from the largest frame the app builds: nodes
//! dominate, so budget about 0.65 KB per node of capacity plus twice the per-frame string bytes.
//! The buffer is sized by capacity, not use: a smaller frame does not need less of it. It need
//! not be resident, though: carve a buffer that is zero already (static, fresh `mmap`) with
//! `Carver.zeroed` (`Context.initZeroed`) and only the pages the frames touch are.

const std = @import("std");

/// Each column starts on its own cache line. 64 bytes is also a whole number of vectors for every
/// lane count up to 16 x f32, so a SIMD load of a column never straddles a line at its start.
pub const column_align = 64;

/// Bump pointer over a caller-owned buffer. With `buf == null` it only counts: sizing a buffer
/// and carving it run the same code, so the two cannot disagree.
pub const Carver = struct {
    buf: ?[]align(column_align) u8,
    off: usize = 0,
    /// The buffer is all zero bytes already (a static buffer in bss, fresh `mmap` memory), so
    /// carving does not clear it: pages of capacity the UI never reaches are never touched and
    /// never become resident.
    zeroed: bool = false,

    /// Next `n` rows of `T`, zeroed. The carved size is rounded up to `column_align`, so the
    /// next column starts on a fresh cache line. Asserts the buffer is large enough. When counting
    /// it advances `off` and returns an empty slice.
    pub fn slice(c: *Carver, comptime T: type, n: usize) []T {
        comptime std.debug.assert(@alignOf(T) <= column_align);
        std.debug.assert(c.off % column_align == 0);
        const bytes = std.mem.alignForward(usize, n * @sizeOf(T), column_align);
        const start = c.off;
        c.off += bytes;
        const b = c.buf orelse return &.{};
        std.debug.assert(c.off <= b.len);
        if (!c.zeroed) @memset(b[start..c.off], 0);
        std.debug.assert(@intFromPtr(b.ptr + start) % column_align == 0);
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

/// Copies rows [src_at, src_at + n) of every column in `src` to rows starting at `dst_at` in
/// `dst`. `S` is a column set as taken by `Carver.columns`; the ranges must not overlap.
pub fn copyRows(comptime S: type, dst: *const S, dst_at: usize, src: *const S, src_at: usize, n: usize) void {
    copyRowsExcept(S, dst, dst_at, src, src_at, n, &.{});
}

/// `copyRows` of every column but those named in `skip`.
pub fn copyRowsExcept(comptime S: type, dst: *const S, dst_at: usize, src: *const S, src_at: usize, n: usize, comptime skip: []const []const u8) void {
    const info = @typeInfo(S).@"struct";
    inline for (info.field_names, info.field_types) |name, FT| {
        const skipped = comptime for (skip) |s| {
            if (std.mem.eql(u8, s, name)) break true;
        } else false;
        if (!skipped) switch (@typeInfo(FT)) {
            .pointer => @memcpy(@field(dst, name)[dst_at..][0..n], @field(src, name)[src_at..][0..n]),
            .array => |a| inline for (0..a.len) |k| {
                @memcpy(@field(dst, name)[k][dst_at..][0..n], @field(src, name)[k][src_at..][0..n]);
            },
            else => @compileError("column sets hold only []T and [k][]T fields"),
        };
    }
}

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

test "Carver.zeroed carves without writing the buffer" {
    var buf: [256]u8 align(column_align) = @splat(0xaa);
    var c: Carver = .{ .buf = &buf, .zeroed = true };
    const a = c.slice(u32, 4);
    // Nothing was cleared: the caller promised zero bytes, and these are not.
    try std.testing.expectEqual(@as(u32, 0xaaaa_aaaa), a[0]);
    try std.testing.expectEqual(@as(usize, column_align), c.off);
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

test "copyRows copies a row range of every column" {
    const Cols = struct { id: []u32, pos: [2][]f32 };
    var buf: [64 * 6]u8 align(column_align) = undefined;
    var c: Carver = .{ .buf = &buf };
    const src = c.columns(Cols, 6);
    const dst = c.columns(Cols, 6);
    for (0..6) |i| {
        src.id[i] = @intCast(10 + i);
        src.pos[0][i] = @floatFromInt(i);
        src.pos[1][i] = @floatFromInt(100 + i);
    }

    copyRows(Cols, &dst, 1, &src, 3, 2);

    try std.testing.expectEqualSlices(u32, &.{ 0, 13, 14, 0, 0, 0 }, dst.id);
    try std.testing.expectEqualSlices(f32, &.{ 0, 3, 4, 0, 0, 0 }, dst.pos[0]);
    try std.testing.expectEqualSlices(f32, &.{ 0, 103, 104, 0, 0, 0 }, dst.pos[1]);

    copyRows(Cols, &dst, 0, &src, 0, 0); // empty range is a no-op
    try std.testing.expectEqual(0, dst.id[0]);
}

test "every column starts on a 64-byte boundary" {
    const Cols = struct {
        a: []u8,
        b: []u64,
        c: [3][]u16,
        d: []struct { x: f32, y: f32, z: f32 },
    };
    var buf: [64 * 64]u8 align(column_align) = undefined;
    var c: Carver = .{ .buf = &buf };
    for ([_]usize{ 1, 7, 13, 64, 65 }) |n| {
        c.off = 0;
        const cols = c.columns(Cols, n);
        try std.testing.expectEqual(0, @intFromPtr(cols.a.ptr) % column_align);
        try std.testing.expectEqual(0, @intFromPtr(cols.b.ptr) % column_align);
        for (cols.c) |col| try std.testing.expectEqual(0, @intFromPtr(col.ptr) % column_align);
        try std.testing.expectEqual(0, @intFromPtr(cols.d.ptr) % column_align);
        try std.testing.expectEqual(0, c.off % column_align);
    }
}
