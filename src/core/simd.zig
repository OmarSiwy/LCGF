//! simd: vector width, column access and branch-free scalar selects. Tier 0.
//!
//! The lane count follows the target (8 with AVX2, 4 with SSE2 or NEON) unless the build forces
//! it with `-Dlanes=N`; std's width query never returns 16, so that is how 16 lanes get tested.

const std = @import("std");
const build_options = @import("build_options");
const none = @import("types.zig").none;

/// f32/u32 lanes per vector.
pub const lanes: comptime_int = build_options.lanes orelse (std.simd.suggestVectorLength(f32) orelse 4);
comptime {
    // `padded` rounds with alignForward, which needs a power of two.
    if (!std.math.isPowerOfTwo(lanes)) @compileError("-Dlanes must be a power of two");
}

pub const F = @Vector(lanes, f32);
pub const U = @Vector(lanes, u32);
pub const B = @Vector(lanes, bool);
pub const Bytes = @Vector(lanes, u8);
/// One bit per lane.
pub const Mask = @Int(.unsigned, lanes);
pub const iota: U = std.simd.iota(u32, lanes);

/// Rows are rounded up to whole vectors so batch loops need no scalar tail.
pub inline fn padded(n: usize) usize {
    return std.mem.alignForward(usize, n, lanes);
}
pub inline fn loadF(col: []const f32, i: usize) F {
    return col[i..][0..lanes].*;
}
pub inline fn storeF(col: []f32, i: usize, v: F) void {
    col[i..][0..lanes].* = v;
}
pub inline fn loadU(col: []const u32, i: usize) U {
    return col[i..][0..lanes].*;
}
pub inline fn storeU(col: []u32, i: usize, v: U) void {
    col[i..][0..lanes].* = v;
}
pub inline fn f(x: f32) F {
    return @splat(x);
}
pub inline fn u(x: u32) U {
    return @splat(x);
}
pub inline fn bits(m: B) Mask {
    return @bitCast(m);
}

/// `c ? a : b` without a branch.
pub inline fn selU(c: bool, a: u32, b: u32) u32 {
    const m = -%@as(u32, @intFromBool(c));
    return b ^ ((a ^ b) & m);
}
/// `c ? a : b` without a branch. A bit-level select, so inf and NaN pass through.
pub inline fn selF(c: bool, a: f32, b: f32) f32 {
    return @bitCast(selU(c, @bitCast(a), @bitCast(b)));
}
/// 1.0 or 0.0, built from the bit pattern so that it stays a mask
/// operation instead of becoming a compare-and-jump.
pub inline fn b2f(c: bool) f32 {
    return @bitCast(-%@as(u32, @intFromBool(c)) & @as(u32, 0x3f80_0000));
}
/// `a and b` as one bitwise AND, with no short-circuit jump.
pub inline fn andB(a: bool, b: bool) bool {
    return (@intFromBool(a) & @intFromBool(b)) != 0;
}
/// `a or b` as one bitwise OR.
pub inline fn orB(a: bool, b: bool) bool {
    return (@intFromBool(a) | @intFromBool(b)) != 0;
}

/// First index of `needle` in `col[0..len]`, or `none`.
/// Compares `lanes` values per step and never exits early.
/// `col` holds at least `padded(len)` rows; rows past `len` are ignored.
pub fn find(col: []const u32, len: u32, needle: u32) u32 {
    var found: u32 = none;
    const n = padded(len);
    var i: usize = 0;
    while (i < n) : (i += lanes) {
        const base: u32 = @intCast(i);
        const in_range = (iota + u(base)) < u(len);
        const m = bits((loadU(col, i) == u(needle)) & in_range);
        const idx = base + @as(u32, @ctz(m));
        found = selU(andB(m != 0, found == none), idx, found);
    }
    return found;
}

/// Number of values in `col[0..len]` that are below `bound`.
/// On a sorted column this is the insertion index.
/// `col` holds at least `padded(len)` rows; rows past `len` are ignored.
pub fn rank(col: []const u32, len: u32, bound: u32) u32 {
    var acc: U = @splat(0);
    const n = padded(len);
    var i: usize = 0;
    while (i < n) : (i += lanes) {
        const in_range = (iota + u(@intCast(i))) < u(len);
        acc += @intFromBool((loadU(col, i) < u(bound)) & in_range);
    }
    return @reduce(.Add, acc);
}

/// One step of a filtering loop: `out[w] = v` always, then the cursor moves
/// by 0 or 1. `out` needs one spare row past the last kept one, because a
/// dropped row is still written there.
pub inline fn emit(comptime T: type, out: []T, w: u32, v: T, keep: bool) u32 {
    out[w] = v;
    return w + @intFromBool(keep);
}

/// Stream compaction over a set of columns: keeps, in order, the rows `r` of
/// every slice field of `cols` for which `key[r] == want`, and returns the
/// new length. Every row is copied to the write cursor, which advances only
/// for kept rows. Rows from the new length up to `len` are zeroed so batch
/// passes over the padding see inert rows. `key` may be one of the columns.
pub fn compact(cols: anytype, len: u32, key: []const u32, want: u32) u32 {
    const names = @typeInfo(@TypeOf(cols)).@"struct".field_names;
    var w: u32 = 0;
    for (0..len) |r| {
        const keep = key[r] == want;
        inline for (names) |name| @field(cols, name)[w] = @field(cols, name)[r];
        w += @intFromBool(keep);
    }
    inline for (names) |name| {
        const col = @field(cols, name);
        @memset(col[w..len], std.mem.zeroes(@typeInfo(@TypeOf(col)).pointer.child));
    }
    return w;
}

const testing = std.testing;

test "padded rounds up to whole vectors" {
    try testing.expectEqual(@as(usize, 0), padded(0));
    try testing.expectEqual(@as(usize, lanes), padded(1));
    try testing.expectEqual(@as(usize, lanes), padded(lanes));
    try testing.expectEqual(@as(usize, 2 * lanes), padded(lanes + 1));
    for (0..100) |n| {
        const p = padded(n);
        try testing.expect(p >= n and p < n + lanes and p % lanes == 0);
    }
}

test "aliases have one lane per element" {
    try testing.expectEqual(lanes, @typeInfo(F).vector.len);
    try testing.expectEqual(lanes, @typeInfo(U).vector.len);
    try testing.expectEqual(lanes, @typeInfo(Bytes).vector.len);
    try testing.expectEqual(lanes, @bitSizeOf(Mask));
    const idx: [lanes]u32 = iota;
    for (idx, 0..) |v, i| try testing.expectEqual(@as(u32, @intCast(i)), v);
    try testing.expectEqual(@as(f32, 2.5), @reduce(.Max, f(2.5)));
    try testing.expectEqual(@as(u32, 7 * lanes), @reduce(.Add, u(7)));
    // Lane 0 is the lowest bit.
    try testing.expectEqual(@as(Mask, 1), bits(iota == u(0)));
    try testing.expectEqual(~@as(Mask, 0), bits(iota < u(lanes)));
}

test "load and store move one vector at a column offset" {
    var fc: [3 * lanes]f32 = @splat(0);
    var uc: [3 * lanes]u32 = @splat(0);
    for (&fc, &uc, 0..) |*a, *b, i| {
        a.* = @floatFromInt(i);
        b.* = @intCast(i);
    }
    // Any offset works, not only whole vectors.
    for ([_]usize{ 0, 1, lanes, 2 * lanes }) |i| {
        const base: u32 = @intCast(i);
        try testing.expectEqual(iota + u(base), loadU(&uc, i));
        const want: F = @floatFromInt(iota + u(base));
        try testing.expectEqual(want, loadF(&fc, i));
    }
    storeF(&fc, lanes, f(-1));
    storeU(&uc, lanes, u(9));
    for (fc, uc, 0..) |a, b, i| {
        const inside = i >= lanes and i < 2 * lanes;
        try testing.expectEqual(if (inside) @as(f32, -1) else @as(f32, @floatFromInt(i)), a);
        try testing.expectEqual(if (inside) @as(u32, 9) else @as(u32, @intCast(i)), b);
    }
}

test "selects pick like if-else, bit for bit" {
    const inf = std.math.inf(f32);
    const nan = std.math.nan(f32);
    try testing.expectEqual(@as(u32, 7), selU(true, 7, 9));
    try testing.expectEqual(@as(u32, 9), selU(false, 7, 9));
    try testing.expectEqual(@as(u32, 0xffff_ffff), selU(true, 0xffff_ffff, 0));
    try testing.expectEqual(@as(f32, -0.5), selF(true, -0.5, 2));
    try testing.expectEqual(@as(f32, 2), selF(false, -0.5, 2));
    try testing.expectEqual(inf, selF(true, inf, 0));
    try testing.expect(std.math.isNan(selF(false, 0, nan)));
    // -0.0 keeps its sign: the select moves bits, not values.
    try testing.expectEqual(@as(u32, 0x8000_0000), @as(u32, @bitCast(selF(true, -0.0, 0))));
    try testing.expectEqual(@as(f32, 1), b2f(true));
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(b2f(false))));
    for ([_]bool{ false, true }) |a| for ([_]bool{ false, true }) |b| {
        try testing.expectEqual(a and b, andB(a, b));
        try testing.expectEqual(a or b, orB(a, b));
    };
}

test "find returns the first match, ignores rows past len, else none" {
    var col: [3 * lanes]u32 = undefined;
    for (&col, 0..) |*v, i| v.* = @intCast(100 + i);
    const len: u32 = 2 * lanes + 1;
    for (0..len) |i| try testing.expectEqual(@as(u32, @intCast(i)), find(&col, len, @intCast(100 + i)));
    // Present in the padding only: not found.
    try testing.expectEqual(none, find(&col, len, 100 + len));
    try testing.expectEqual(none, find(&col, 0, 100));
    try testing.expectEqual(none, find(&col, len, 7));
    // Duplicates across vectors: the lowest index wins.
    col[lanes + 1] = 100;
    try testing.expectEqual(@as(u32, 0), find(&col, len, 100));
    col[0] = 0;
    try testing.expectEqual(@as(u32, lanes + 1), find(&col, len, 100));
}

test "rank is the insertion index on a sorted column" {
    var col: [3 * lanes]u32 = undefined;
    // 0, 0, 2, 2, 4, 4, ...: duplicates straddle vector edges at every lane count.
    for (&col, 0..) |*v, i| v.* = @intCast(i / 2 * 2);
    // Padding below every bound: must not be counted.
    const len: u32 = 2 * lanes + 1;
    for (len..col.len) |i| col[i] = 0;
    try testing.expectEqual(@as(u32, 0), rank(&col, len, 0));
    for (0..len) |k| {
        const bound: u32 = @intCast(k);
        const want = std.sort.lowerBound(u32, col[0..len], bound, struct {
            fn order(b: u32, x: u32) std.math.Order {
                return std.math.order(b, x);
            }
        }.order);
        try testing.expectEqual(@as(u32, @intCast(want)), rank(&col, len, bound));
    }
    try testing.expectEqual(len, rank(&col, len, 0xffff_ffff));
    try testing.expectEqual(@as(u32, 0), rank(&col, 0, 5));
}

test "emit writes always and advances only for kept rows" {
    var out: [3 * lanes + 1]u32 = @splat(0xdead);
    var w: u32 = 0;
    for (0..3 * lanes) |i| w = emit(u32, &out, w, @intCast(i), i % 3 == 0);
    try testing.expectEqual(@as(u32, lanes), w);
    for (out[0..w], 0..) |v, k| try testing.expectEqual(@as(u32, @intCast(3 * k)), v);
    // The last dropped row landed in the spare slot.
    try testing.expectEqual(@as(u32, 3 * lanes - 1), out[w]);
}

test "compact keeps matching rows in order and zeroes the rest" {
    const n = 2 * lanes + 3;
    var id: [n]u32 = undefined;
    var x: [n]f32 = undefined;
    var seen: [n]u32 = undefined;
    for (0..n) |i| {
        id[i] = @intCast(10 + i);
        x[i] = @floatFromInt(i);
        seen[i] = selU(i % 2 == 1 or i == 0, 7, 3);
    }
    const Cols = struct { id: []u32, x: []f32, seen: []u32 };
    const cols: Cols = .{ .id = &id, .x = &x, .seen = &seen };
    const len = compact(cols, n, cols.seen, 7);
    // Kept: row 0 and every odd row; n is odd.
    try testing.expectEqual(@as(u32, 1 + (n - 1) / 2), len);
    for (0..len) |k| {
        const r = (2 * k) -| 1;
        try testing.expectEqual(@as(u32, @intCast(10 + r)), id[k]);
        try testing.expectEqual(@as(f32, @floatFromInt(r)), x[k]);
        try testing.expectEqual(@as(u32, 7), seen[k]);
    }
    for (len..n) |r| {
        try testing.expectEqual(@as(u32, 0), id[r]);
        try testing.expectEqual(@as(f32, 0), x[r]);
        try testing.expectEqual(@as(u32, 0), seen[r]);
    }
    try testing.expectEqual(@as(u32, 0), compact(cols, len, cols.seen, 8));
}
