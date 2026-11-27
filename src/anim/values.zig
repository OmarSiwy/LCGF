//! Values: what `Frame.animate` and `Frame.tween` can move. A value is a number, a `Color`, or
//! an array, vector or struct of values; it moves as its numeric components do, each on its own
//! spring or tween row. Tier 0: functions over types, no state.
//!
//! Components are numbered depth-first in field and index order, so a `Color` is r, g, b, a
//! (the keys `Frame.transition` uses) and a `Rect` x0, y0, x1, y1. Floats are read and written
//! as they are; integers (and a colour's channels) are rounded to the nearest value and clamped
//! to their type's range on the way back.

const std = @import("std");
const types = @import("../core/types.zig");
const Color = types.Color;

/// The type a target of type `T` animates as: an untyped number literal moves as an f32.
pub fn Of(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .comptime_int, .comptime_float => f32,
        else => T,
    };
}

/// How many numbers a value of `T` is made of; a compile error naming the first part of `T`
/// that is not a number (a bool, a pointer, an optional, a union).
pub fn count(comptime T: type) comptime_int {
    return countAt(T, @typeName(T));
}

fn countAt(comptime T: type, comptime path: []const u8) comptime_int {
    if (T == Color) return 4;
    return switch (@typeInfo(T)) {
        .float, .int => 1,
        .array => |a| a.len * countAt(a.child, path ++ "[i]"),
        .vector => |v| v.len * countAt(v.child, path ++ "[i]"),
        .@"struct" => |s| blk: {
            var n = 0;
            for (s.field_names, s.field_types) |name, FT| n += countAt(FT, path ++ "." ++ name);
            break :blk n;
        },
        else => @compileError("cannot animate " ++ path ++ ": a " ++ @typeName(T) ++ " is not a number, a Color, or an array, vector or struct of them"),
    };
}

/// The components of `v`, in order.
pub fn flatten(comptime T: type, v: T) [count(T)]f32 {
    var out: [count(T)]f32 = undefined;
    var at: usize = 0;
    put(T, v, &out, &at);
    return out;
}

/// The value made of `xs`, in `flatten`'s order.
pub fn build(comptime T: type, xs: *const [count(T)]f32) T {
    var at: usize = 0;
    return take(T, xs, &at);
}

fn put(comptime T: type, v: T, out: []f32, at: *usize) void {
    if (T == Color) {
        inline for (.{ v.r, v.g, v.b, v.a }) |c| put(u8, c, out, at);
        return;
    }
    switch (@typeInfo(T)) {
        .float => {
            out[at.*] = @floatCast(v);
            at.* += 1;
        },
        .int => {
            out[at.*] = @floatFromInt(v);
            at.* += 1;
        },
        .array => for (v) |x| put(@TypeOf(x), x, out, at),
        .vector => |info| {
            const arr: [info.len]info.child = v;
            for (arr) |x| put(info.child, x, out, at);
        },
        .@"struct" => |s| inline for (s.field_names, s.field_types) |name, FT| put(FT, @field(v, name), out, at),
        else => unreachable,
    }
}

/// An animated number as an integer of the range [lo, hi]: rounded half away from zero, clamped
/// in f64 (where the ends of every type up to 32 bits are exact: an f32 of maxInt(u32) is 2^32),
/// NaN to 0. What `build` does for an integer.
pub fn intOf(x: f32, lo: i64, hi: i64) i64 {
    if (x != x) return 0;
    return @intFromFloat(@min(@max(@as(f64, @round(x)), @as(f64, @floatFromInt(lo))), @as(f64, @floatFromInt(hi))));
}

fn take(comptime T: type, xs: []const f32, at: *usize) T {
    if (T == Color) {
        var c: [4]u8 = undefined;
        for (&c) |*x| x.* = take(u8, xs, at);
        return .rgba(c[0], c[1], c[2], c[3]);
    }
    switch (@typeInfo(T)) {
        .float => {
            at.* += 1;
            return @floatCast(xs[at.* - 1]);
        },
        .int => |info| {
            if (info.bits > 32) @compileError("cannot animate a " ++ @typeName(T) ++ ": integers of up to 32 bits");
            at.* += 1;
            return @intCast(intOf(xs[at.* - 1], std.math.minInt(T), std.math.maxInt(T)));
        },
        .array => |a| {
            var out: T = undefined;
            for (&out) |*x| x.* = take(a.child, xs, at);
            return out;
        },
        .vector => |info| {
            var arr: [info.len]info.child = undefined;
            for (&arr) |*x| x.* = take(info.child, xs, at);
            return arr;
        },
        .@"struct" => |s| {
            var out: T = undefined;
            inline for (s.field_names, s.field_types) |name, FT| @field(out, name) = take(FT, xs, at);
            return out;
        },
        else => unreachable,
    }
}

const testing = std.testing;

test "values: colours, rects, arrays and vectors round-trip; integers round and clamp" {
    const c: Color = .rgba(10, 20, 30, 255);
    try testing.expectEqual(@as(comptime_int, 4), count(Color));
    try testing.expectEqual([4]f32{ 10, 20, 30, 255 }, flatten(Color, c));
    try testing.expectEqual(c, build(Color, &.{ 10.4, 19.6, 30, 300 }));

    const r: types.Rect = .{ .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 };
    try testing.expectEqual(r, build(types.Rect, &flatten(types.Rect, r)));

    const P = struct { at: [2]f32, v: @Vector(2, f32), n: i8 };
    try testing.expectEqual(@as(comptime_int, 5), count(P));
    const p = build(P, &.{ 1, 2, 3, 4, -200 });
    try testing.expectEqual([2]f32{ 1, 2 }, p.at);
    try testing.expectEqual(@as(f32, 4), p.v[1]);
    try testing.expectEqual(@as(i8, -128), p.n);
    // An f32 past a u32's end clamps to it.
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), build(u32, &.{5e9}));

    try testing.expectEqual(f32, Of(@TypeOf(1)));
    try testing.expectEqual(Color, Of(Color));
}
