//! features: the built-in visual features of the stock quad material, as `Style.params` values.
//! Tier 0: pure functions from a description to four 32-bit words. The shader that reads them
//! is src/render/shaders/quad.wgsl; `params.x` picks the feature, the other three words carry
//! its data as bit patterns (colours, packed halves), so a renderer declares the params
//! attribute as uint32x4 and copies the words without converting them.
//!
//! One feature per quad. Features keep `Style.material = .solid`, so quads with different
//! features share one pipeline and batch together.

const std = @import("std");
const types = @import("../core/types.zig");
const Color = types.Color;

/// What `params.x` selects in the stock material. `solid` is all-zero params, the default.
pub const Kind = enum(u32) { solid = 0, linear = 1, radial = 2, shadow = 3 };

/// `Style.params` for a linear gradient from the node's `fill` to `to`. `angle` is in radians:
/// 0 runs left to right, pi/2 top to bottom (y points down). The gradient spans the two corners
/// the direction meets, as CSS `linear-gradient` does.
pub fn linear(to: Color, angle: f32) [4]f32 {
    return words(.{ @backingInt(Kind.linear), to.bitsOf(), @bitCast(angle), 0 });
}

/// `Style.params` for a radial gradient from the node's `fill` at `centre` to `to` at
/// `radius` pixels from it and beyond. `centre` is a fraction of the node's size: (0.5, 0.5)
/// is the middle.
pub fn radial(to: Color, centre: [2]f32, radius: f32) [4]f32 {
    return words(.{ @backingInt(Kind.radial), to.bitsOf(), half2(centre), @bitCast(radius) });
}

/// `Style.params` for an analytic box shadow: the node's rounded rect (its `radius`) blurred by a
/// Gaussian of `sigma` pixels, in the node's `fill`. The quad grows by 3 sigma on every side as
/// it is drawn, so the node itself has the size of the box that casts the shadow; offset and
/// spread are the node's position and size. Put the shadow node before the box it belongs to,
/// so it paints underneath. Its border is not drawn.
pub fn shadow(sigma: f32) [4]f32 {
    return words(.{ @backingInt(Kind.shadow), @bitCast(sigma), 0, 0 });
}

/// Two f16 in one word, low half first: WGSL `unpack2x16float`.
fn half2(v: [2]f32) u32 {
    const lo: u16 = @bitCast(@as(f16, @floatCast(v[0])));
    const hi: u16 = @bitCast(@as(f16, @floatCast(v[1])));
    return (@as(u32, hi) << 16) | lo;
}

fn words(w: [4]u32) [4]f32 {
    return @bitCast(w);
}

const testing = std.testing;

test "features: solid is the zero default, kind and colour travel as exact words" {
    const default: types.Style = .{};
    try testing.expectEqual(default.params, @as([4]f32, @bitCast([4]u32{ @backingInt(Kind.solid), 0, 0, 0 })));
    const p: [4]u32 = @bitCast(linear(.rgba(1, 2, 3, 255), std.math.pi / 2.0));
    try testing.expectEqual(@backingInt(Kind.linear), p[0]);
    // An opaque colour's bits are a NaN as f32; it must arrive unchanged.
    try testing.expectEqual(Color.rgba(1, 2, 3, 255).bitsOf(), p[1]);
    try testing.expectEqual(@as(f32, std.math.pi / 2.0), @as(f32, @bitCast(p[2])));
    const q: [4]u32 = @bitCast(radial(.white, .{ 0.25, 1 }, 40));
    try testing.expectEqual(@backingInt(Kind.radial), q[0]);
    try testing.expectEqual(0x3c00_3400, q[2]); // f16 1.0 high, f16 0.25 low
    try testing.expectEqual(@as(f32, 40), @as(f32, @bitCast(q[3])));
    const sh: [4]u32 = @bitCast(shadow(6));
    try testing.expectEqual([4]u32{ @backingInt(Kind.shadow), @bitCast(@as(f32, 6)), 0, 0 }, sh);
}
