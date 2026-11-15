//! simd: vector width, column access and branch-free scalar selects. Tier 0.
//!
//! The lane count follows the target (8 with AVX2, 4 with SSE2 or NEON) unless the build forces
//! it with `-Dlanes=N`; std's width query never returns 16, so that is how 16 lanes get tested.

const std = @import("std");
const build_options = @import("build_options");

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
