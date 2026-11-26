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
pub const Kind = enum(u32) { solid = 0, linear = 1, radial = 2, shadow = 3, nine_slice = 4, dashed = 5, dotted = 6, ramp = 7 };

/// Features a renderer must support for one statically described UI.
pub const Usage = struct {
    text: bool = false,
    radius: bool = false,
    border: bool = false,
    image: bool = false,
    kinds: std.enums.EnumSet(Kind) = .initOne(.solid),

    pub const all: Usage = .{ .text = true, .radius = true, .border = true, .image = true, .kinds = .full };

    pub fn kindList(comptime self: Usage) []const Kind {
        comptime var list: []const Kind = &.{};
        inline for (std.enums.values(Kind)) |kind| if (comptime self.kinds.contains(kind)) {
            list = list ++ [_]Kind{kind};
        };
        return list;
    }
};

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

/// One colour of a ramp: `color` at `at`, from 0 (the gradient's start) to 1 (its end).
pub const Stop = struct { color: Color, at: f32 };

/// `Style.params` for a gradient of any number of colours, read from a ramp: one row of the
/// node's texture (`rampPixels` fills it; `Style.uv` is its rect, the row at the rect's middle).
/// The gradient runs along `angle` as `linear`'s does; the colour at each point is the ramp at
/// that fraction, interpolated between its two nearest texels, times the node's `fill` (white
/// for the ramp's own colours).
pub fn linearRamp(angle: f32) [4]f32 {
    return words(.{ @backingInt(Kind.ramp), 0, @bitCast(angle), 0 });
}

/// `Style.params` for a radial gradient read from a ramp (`linearRamp`): from `centre` (a
/// fraction of the node's size) to `radius` pixels from it, as `radial`'s.
pub fn radialRamp(centre: [2]f32, radius: f32) [4]f32 {
    return words(.{ @backingInt(Kind.ramp), 1, half2(centre), @bitCast(radius) });
}

/// Fills the ramp row `out` (straight RGBA8, `Color.bitsOf`) with the colours of `stops`,
/// whose `at` must rise from 0 to 1: texel k holds the gradient at (k + 0.5) / out.len,
/// interpolated between the stops around it in premultiplied colour, as CSS gradients are,
/// and the first and last stops' colours before and after them. Upload `out` as a
/// `out.len` x 1 texture and draw with `linearRamp` or `radialRamp`.
pub fn rampPixels(stops: []const Stop, out: []u32) void {
    std.debug.assert(stops.len > 0);
    const n: f32 = @floatFromInt(out.len);
    var s: usize = 0;
    for (out, 0..) |*o, k| {
        const t = (@as(f32, @floatFromInt(k)) + 0.5) / n;
        while (s + 1 < stops.len and stops[s + 1].at <= t) s += 1;
        const a = stops[s];
        const b = stops[@min(s + 1, stops.len - 1)];
        const span = b.at - a.at;
        // Past the last stop `b` is `a`: its colour, as before the first one is the first's.
        const f: f32 = if (span <= 0) @floatFromInt(@intFromBool(t >= b.at)) else std.math.clamp((t - a.at) / span, 0, 1);
        o.* = mixPremultiplied(a.color, b.color, f).bitsOf();
    }
}

/// `a` to `b` by `f`, interpolated in premultiplied colour and returned straight.
fn mixPremultiplied(a: Color, b: Color, f: f32) Color {
    const aa: f32 = @floatFromInt(a.a);
    const ba: f32 = @floatFromInt(b.a);
    const alpha = aa + (ba - aa) * f;
    var out: Color = .{ .a = @intFromFloat(@round(alpha)) };
    inline for (.{ "r", "g", "b" }) |c| {
        const pa = @as(f32, @floatFromInt(@field(a, c))) * aa;
        const pb = @as(f32, @floatFromInt(@field(b, c))) * ba;
        const p = pa + (pb - pa) * f;
        @field(out, c) = if (alpha > 0) @intFromFloat(@round(std.math.clamp(p / alpha, 0, 255))) else 0;
    }
    return out;
}

/// `Style.params` for an analytic box shadow: the node's rounded rect (its `radius`) blurred by a
/// Gaussian of `sigma` pixels, in the node's `fill`. The quad grows by 3 sigma on every side as
/// it is drawn, so the node itself has the size of the box that casts the shadow; offset and
/// spread are the node's position and size. Put the shadow node before the box it belongs to,
/// so it paints underneath. Its border is not drawn.
pub fn shadow(sigma: f32) [4]f32 {
    return words(.{ @backingInt(Kind.shadow), @bitCast(sigma), 0, 0 });
}

/// `Style.params` for a nine-slice image: the node's texture rect (`Style.uv`) is cut into a 3x3
/// grid. `dst` is the size of the border cells on screen, left, top, right, bottom, in whole
/// pixels from 0 to 255; `src` is where the image is cut, as fractions of the image (0 to 1).
/// Corners keep their size as the node grows, edges stretch along one axis, the middle along
/// both.
pub fn nineSlice(dst: [4]f32, src: [4]f32) [4]f32 {
    var px: u32 = 0;
    for (dst, 0..) |v, k| px |= @as(u32, @intFromFloat(std.math.clamp(@round(v), 0, 255))) << @intCast(8 * k);
    return words(.{ @backingInt(Kind.nine_slice), px, unorm2(src[0], src[1]), unorm2(src[2], src[3]) });
}

/// `Style.params` for a dashed border: dashes of `dash` pixels with `gap` pixels between, in the
/// node's `border_color` and `border` width. The gaps show the node's fill, which reaches under
/// the border as CSS backgrounds do. Dashes are laid along each side from its top or left end.
pub fn dashed(dash: f32, gap: f32) [4]f32 {
    return words(.{ @backingInt(Kind.dashed), @bitCast(dash), @bitCast(gap), 0 });
}

/// `Style.params` for a dotted border: round dots as wide as `border`, `gap` pixels apart.
pub fn dotted(gap: f32) [4]f32 {
    return words(.{ @backingInt(Kind.dotted), 0, @bitCast(gap), 0 });
}

/// Two unorm16 in one word, low half first: WGSL `unpack2x16unorm`.
fn unorm2(lo: f32, hi: f32) u32 {
    const a: u32 = @intFromFloat(@round(std.math.clamp(lo, 0, 1) * 65535));
    const b: u32 = @intFromFloat(@round(std.math.clamp(hi, 0, 1) * 65535));
    return (b << 16) | a;
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
    const ns: [4]u32 = @bitCast(nineSlice(.{ 12, 8, 300, -1 }, .{ 0.25, 0.5, 1, 0 }));
    try testing.expectEqual([4]u32{ @backingInt(Kind.nine_slice), 0x00ff_080c, 0x8000_4000, 0x0000_ffff }, ns);
    const da: [4]u32 = @bitCast(dashed(8, 4));
    try testing.expectEqual([4]u32{ @backingInt(Kind.dashed), @bitCast(@as(f32, 8)), @bitCast(@as(f32, 4)), 0 }, da);
    const dt: [4]u32 = @bitCast(dotted(3));
    try testing.expectEqual([4]u32{ @backingInt(Kind.dotted), 0, @bitCast(@as(f32, 3)), 0 }, dt);
    const lr: [4]u32 = @bitCast(linearRamp(0.5));
    try testing.expectEqual([4]u32{ @backingInt(Kind.ramp), 0, @bitCast(@as(f32, 0.5)), 0 }, lr);
    const rr: [4]u32 = @bitCast(radialRamp(.{ 0.25, 1 }, 40));
    try testing.expectEqual([4]u32{ @backingInt(Kind.ramp), 1, 0x3c00_3400, @bitCast(@as(f32, 40)) }, rr);
    const sh: [4]u32 = @bitCast(shadow(6));
    try testing.expectEqual([4]u32{ @backingInt(Kind.shadow), @bitCast(@as(f32, 6)), 0, 0 }, sh);
}

test "rampPixels: stops at their places, premultiplied mixing, the ends held" {
    var px: [4]u32 = undefined;
    // Red, then green at the middle, then blue: texel centres at 1/8, 3/8, 5/8, 7/8.
    rampPixels(&.{ .{ .color = .rgb(255, 0, 0), .at = 0 }, .{ .color = .rgb(0, 255, 0), .at = 0.5 }, .{ .color = .rgb(0, 0, 255), .at = 1 } }, &px);
    try testing.expectEqual(Color.rgb(191, 64, 0).bitsOf(), px[0]);
    try testing.expectEqual(Color.rgb(64, 191, 0).bitsOf(), px[1]);
    try testing.expectEqual(Color.rgb(0, 191, 64).bitsOf(), px[2]);
    try testing.expectEqual(Color.rgb(0, 64, 191).bitsOf(), px[3]);
    // Before the first stop and after the last, their colours; a hard stop switches at once.
    rampPixels(&.{ .{ .color = .rgb(10, 10, 10), .at = 0.3 }, .{ .color = .rgb(200, 0, 0), .at = 0.5 }, .{ .color = .rgb(0, 0, 200), .at = 0.5 } }, &px);
    try testing.expectEqual(Color.rgb(10, 10, 10).bitsOf(), px[0]);
    try testing.expectEqual(Color.rgb(0, 0, 200).bitsOf(), px[2]);
    try testing.expectEqual(Color.rgb(0, 0, 200).bitsOf(), px[3]);
    // To transparent: the colour holds while it fades (premultiplied), not toward black.
    rampPixels(&.{ .{ .color = .rgb(255, 0, 0), .at = 0 }, .{ .color = .rgba(0, 0, 0, 0), .at = 1 } }, &px);
    try testing.expectEqual(Color.rgba(255, 0, 0, 96).bitsOf(), px[2]);
}
