//! Color values and conversion, tier 0. These functions do not register colors or retain data.
//! `Rgba` is straight-alpha, extended sRGB unless a function explicitly says otherwise. Only
//! conversion to RGBA8 clips the gamut. CPU effect surfaces use premultiplied sRGB; texture
//! export chooses straight or premultiplied explicitly, because the stock quad shader expects
//! a straight texture and multiplies its alpha at output.

const std = @import("std");
const Color = @import("../core/types.zig").Color;

pub const Rgba = @Vector(4, f32);
pub const Space = enum { srgb, linear_srgb, oklab, oklch };
pub const Hue = enum { shorter, longer, increasing, decreasing };
pub const Interpolation = struct {
    space: Space = .srgb,
    premultiplied: bool = true,
    hue: Hue = .shorter,
};

pub fn rgba(r: f32, g: f32, b: f32, a: f32) Rgba {
    return .{ r, g, b, a };
}

pub inline fn fromColor(c: Color) Rgba {
    return @as(Rgba, @floatFromInt(@as(@Vector(4, u32), .{ c.r, c.g, c.b, c.a }))) / @as(Rgba, @splat(255));
}

/// Packs the supplied channels as-is, clipping and rounding once. They may be straight or
/// premultiplied; the caller's resource contract determines which. Non-finite channels are 0.
pub inline fn pack(c: Rgba) u32 {
    const valid = (c <= @as(Rgba, @splat(std.math.floatMax(f32)))) & (c >= @as(Rgba, @splat(-std.math.floatMax(f32))));
    const v = @min(@max(@select(f32, valid, c, @as(Rgba, @splat(0))), @as(Rgba, @splat(0))), @as(Rgba, @splat(1)));
    const bytes: @Vector(4, u32) = @intFromFloat(@round(v * @as(Rgba, @splat(255))));
    return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
}

pub inline fn unpack(bits: u32) Rgba {
    return fromColor(@bitCast(bits));
}

pub inline fn premultiply(c: Rgba) Rgba {
    return c * @as(Rgba, .{ c[3], c[3], c[3], 1 });
}

pub inline fn unpremultiply(c: Rgba) Rgba {
    const reciprocal = 1 / @max(c[3], 1e-20);
    const rgb = c * @as(Rgba, .{ reciprocal, reciprocal, reciprocal, 1 });
    return @select(f32, @as(@Vector(4, bool), @splat(c[3] > 0)), rgb, @as(Rgba, @splat(0)));
}

pub inline fn finite(c: Rgba) bool {
    return @reduce(.And, (c <= @as(Rgba, @splat(std.math.floatMax(f32)))) & (c >= @as(Rgba, @splat(-std.math.floatMax(f32)))));
}

pub fn srgbToLinear(v: f32) f32 {
    const a = @abs(v);
    const nonlinear = std.math.pow(f32, (a + 0.055) / 1.055, 2.4);
    return std.math.copysign(if (a <= 0.04045) a / 12.92 else nonlinear, v);
}

pub fn linearToSrgb(v: f32) f32 {
    const a = @abs(v);
    const nonlinear = 1.055 * std.math.pow(f32, a, 1.0 / 2.4) - 0.055;
    return std.math.copysign(if (a <= 0.0031308) 12.92 * a else nonlinear, v);
}

pub fn linear(c: Rgba) Rgba {
    return .{ srgbToLinear(c[0]), srgbToLinear(c[1]), srgbToLinear(c[2]), c[3] };
}

pub fn encoded(c: Rgba) Rgba {
    return .{ linearToSrgb(c[0]), linearToSrgb(c[1]), linearToSrgb(c[2]), c[3] };
}

/// HSL hue is in degrees; saturation/lightness/alpha are fractions. Hue wraps, and fractions
/// clamp to [0,1]. This is an authoring conversion, not a per-pixel rendering operation.
pub fn hsl(hue_degrees: f32, saturation: f32, lightness: f32, alpha: f32) Rgba {
    const h = @mod(hue_degrees / 60, 6);
    const s = std.math.clamp(saturation, 0, 1);
    const l = std.math.clamp(lightness, 0, 1);
    const c = (1 - @abs(2 * l - 1)) * s;
    const x = c * (1 - @abs(@mod(h, 2) - 1));
    const sector: usize = @intFromFloat(@floor(h));
    const rgb = [_][3]f32{ .{ c, x, 0 }, .{ x, c, 0 }, .{ 0, c, x }, .{ 0, x, c }, .{ x, 0, c }, .{ c, 0, x } };
    const m = l - c * 0.5;
    return .{ rgb[sector][0] + m, rgb[sector][1] + m, rgb[sector][2] + m, std.math.clamp(alpha, 0, 1) };
}

pub fn hwb(hue_degrees: f32, whiteness: f32, blackness: f32, alpha: f32) Rgba {
    const w = std.math.clamp(whiteness, 0, 1);
    const b = std.math.clamp(blackness, 0, 1);
    const total = @max(w + b, 1);
    const white = w / total;
    const base = hsl(hue_degrees, 1, 0.5, alpha);
    return base * @as(Rgba, .{ 1 - white - b / total, 1 - white - b / total, 1 - white - b / total, 1 }) + @as(Rgba, .{ white, white, white, 0 });
}

pub fn toOklab(c: Rgba) Rgba {
    const v = linear(c);
    const l = std.math.cbrt(0.4122214708 * v[0] + 0.5363325363 * v[1] + 0.0514459929 * v[2]);
    const m = std.math.cbrt(0.2119034982 * v[0] + 0.6806995451 * v[1] + 0.1073969566 * v[2]);
    const s = std.math.cbrt(0.0883024619 * v[0] + 0.2817188376 * v[1] + 0.6299787005 * v[2]);
    return .{
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
        c[3],
    };
}

pub fn oklab(lightness: f32, a: f32, b: f32, alpha: f32) Rgba {
    const l = lightness + 0.3963377774 * a + 0.2158037573 * b;
    const m = lightness - 0.1055613458 * a - 0.0638541728 * b;
    const s = lightness - 0.0894841775 * a - 1.2914855480 * b;
    const l3 = l * l * l;
    const m3 = m * m * m;
    const s3 = s * s * s;
    return encoded(.{
        4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
        -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
        -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3,
        alpha,
    });
}

pub fn oklch(lightness: f32, chroma: f32, hue_degrees: f32, alpha: f32) Rgba {
    const angle = hue_degrees * std.math.pi / 180;
    return oklab(lightness, chroma * @cos(angle), chroma * @sin(angle), alpha);
}

pub fn toOklch(c: Rgba) Rgba {
    const v = toOklab(c);
    return .{ v[0], @sqrt(v[1] * v[1] + v[2] * v[2]), @mod(std.math.atan2(v[2], v[1]) * 180 / std.math.pi, 360), v[3] };
}

/// CIE Lab uses the D50 reference white, with Bradford D50 -> D65 adaptation before sRGB.
pub fn lab(lightness: f32, a: f32, b: f32, alpha: f32) Rgba {
    const fy = (lightness + 16) / 116;
    const x = labInverse(fy + a / 500) * 0.96422;
    const y = labInverse(fy);
    const z = labInverse(fy - b / 200) * 0.82521;
    return xyzD50(.{ x, y, z, alpha });
}

pub fn xyzD65(c: Rgba) Rgba {
    return encoded(.{ 3.24096994 * c[0] - 1.53738318 * c[1] - 0.49861076 * c[2], -0.96924364 * c[0] + 1.87596750 * c[1] + 0.04155506 * c[2], 0.05563008 * c[0] - 0.20397696 * c[1] + 1.05697151 * c[2], c[3] });
}

pub fn xyzD50(c: Rgba) Rgba {
    return xyzD65(.{ 0.9554734 * c[0] - 0.0230985 * c[1] + 0.0632593 * c[2], -0.0283697 * c[0] + 1.0099955 * c[1] + 0.0210414 * c[2], 0.0123140 * c[0] - 0.0205077 * c[1] + 1.3303659 * c[2], c[3] });
}

/// CSS Color 4 predefined RGB spaces, converted to extended straight sRGB. These are
/// authoring conversions; choosing an actual display/output profile remains an explicit step.
pub fn a98Rgb(c: Rgba) Rgba {
    var v = c;
    inline for (0..3) |k| v[k] = std.math.copysign(std.math.pow(f32, @abs(c[k]), 563.0 / 256.0), c[k]);
    return xyzD65(.{ 0.5766690429 * v[0] + 0.1855582379 * v[1] + 0.1882286462 * v[2], 0.2973449753 * v[0] + 0.6273635663 * v[1] + 0.0752914585 * v[2], 0.0270313614 * v[0] + 0.0706888525 * v[1] + 0.9913375368 * v[2], c[3] });
}

pub fn prophotoRgb(c: Rgba) Rgba {
    var v = c;
    inline for (0..3) |k| {
        const magnitude = @abs(c[k]);
        v[k] = std.math.copysign(if (magnitude <= 16.0 / 512.0) magnitude / 16 else std.math.pow(f32, magnitude, 1.8), c[k]);
    }
    return xyzD50(.{ 0.7977666449 * v[0] + 0.1351812974 * v[1] + 0.0313477341 * v[2], 0.2880748288 * v[0] + 0.7118352342 * v[1] + 0.0000899369 * v[2], 0.8251046025 * v[2], c[3] });
}

pub fn rec2020(c: Rgba) Rgba {
    var v = c;
    inline for (0..3) |k| {
        const magnitude = @abs(c[k]);
        v[k] = std.math.copysign(if (magnitude < 0.018053968510807 * 4.5) magnitude / 4.5 else std.math.pow(f32, (magnitude + 0.09929682680944) / 1.09929682680944, 1.0 / 0.45), c[k]);
    }
    return xyzD65(.{ 0.6369580483 * v[0] + 0.1446169036 * v[1] + 0.1688809752 * v[2], 0.2627002120 * v[0] + 0.6779980715 * v[1] + 0.0593017165 * v[2], 0.0280726930 * v[1] + 1.0609850577 * v[2], c[3] });
}

fn labInverse(v: f32) f32 {
    return if (v > 6.0 / 29.0) v * v * v else (v - 4.0 / 29.0) * (108.0 / 841.0);
}

pub fn lch(lightness: f32, chroma: f32, hue_degrees: f32, alpha: f32) Rgba {
    const angle = hue_degrees * std.math.pi / 180;
    return lab(lightness, chroma * @cos(angle), chroma * @sin(angle), alpha);
}

/// Converts an encoded Display-P3 authoring value to extended sRGB. This does not claim an
/// HDR or P3 output surface; an RGBA8 export deliberately clips to the sRGB gamut.
pub fn displayP3(c: Rgba) Rgba {
    const v = linear(c);
    return encoded(.{
        1.22494018 * v[0] - 0.22494018 * v[1],
        -0.04205695 * v[0] + 1.04205695 * v[1],
        -0.01963755 * v[0] - 0.07863605 * v[1] + 1.09827360 * v[2],
        c[3],
    });
}

fn inSpace(c: Rgba, space: Space) Rgba {
    return switch (space) {
        .srgb => c,
        .linear_srgb => linear(c),
        .oklab => toOklab(c),
        .oklch => toOklch(c),
    };
}

fn fromSpace(c: Rgba, space: Space) Rgba {
    return switch (space) {
        .srgb => c,
        .linear_srgb => encoded(c),
        .oklab => oklab(c[0], c[1], c[2], c[3]),
        .oklch => oklch(c[0], c[1], c[2], c[3]),
    };
}

/// Interpolates straight authoring colors and returns straight sRGB. Polar hue is not
/// premultiplied; powerless hue borrows the other stop's hue instead of rotating through red.
pub fn mix(a: Rgba, b: Rgba, fraction: f32, opt: Interpolation) Rgba {
    const t = std.math.clamp(fraction, 0, 1);
    var x = inSpace(a, opt.space);
    var y = inSpace(b, opt.space);
    if (opt.space == .oklch) {
        if (x[1] < 1e-6) x[2] = y[2];
        if (y[1] < 1e-6) y[2] = x[2];
        const increasing = @mod(y[2] - x[2], 360);
        const shorter = if (increasing > 180) increasing - 360 else increasing;
        const delta = switch (opt.hue) {
            .increasing => increasing,
            .decreasing => if (increasing == 0) @as(f32, 0) else increasing - 360,
            .shorter => shorter,
            .longer => if (shorter >= 0) shorter - 360 else shorter + 360,
        };
        y[2] = x[2] + delta;
    }
    if (opt.premultiplied) inline for (0..3) |i| {
        if (i != 2 or opt.space != .oklch) {
            x[i] *= x[3];
            y[i] *= y[3];
        }
    };
    var v = x + (y - x) * @as(Rgba, @splat(t));
    if (opt.premultiplied) inline for (0..3) |i| {
        if (i != 2 or opt.space != .oklch) v[i] /= @max(v[3], 1e-20);
    };
    if (v[3] <= 0) return @splat(0);
    return fromSpace(v, opt.space);
}

const testing = std.testing;

test "authoring values convert without a registry and pack only at the boundary" {
    try testing.expectEqual(Color.rgb(255, 0, 0).bitsOf(), pack(hsl(360, 1, 0.5, 1)));
    try testing.expectEqual(Color.rgb(128, 128, 128).bitsOf(), pack(hwb(90, 1, 1, 1)));
    const white = lab(100, 0, 0, 1);
    inline for (0..3) |i| try testing.expectApproxEqAbs(@as(f32, 1), white[i], 0.001);
    const p3 = displayP3(.{ 1, 1, 1, 0.5 });
    inline for (0..3) |i| try testing.expectApproxEqAbs(@as(f32, 1), p3[i], 0.0001);
    try testing.expectEqual(@as(f32, 0.5), p3[3]);
}

test "premultiplied interpolation avoids transparent endpoint fringes" {
    const c = mix(.{ 1, 0, 0, 0 }, .{ 0, 0, 1, 1 }, 0.5, .{});
    try testing.expectApproxEqAbs(@as(f32, 0), c[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), c[2], 0.0001);
    try testing.expectEqual(@as(f32, 0.5), c[3]);
    const light = mix(.{ 0, 0, 0, 1 }, .{ 1, 1, 1, 1 }, 0.5, .{ .space = .linear_srgb });
    try testing.expectApproxEqAbs(@as(f32, 0.735357), light[0], 0.0001);
}

test "OKLab round trip and explicit alpha representation" {
    const c: Rgba = .{ 0.2, 0.7, 0.4, 0.3 };
    const v = toOklab(c);
    const back = oklab(v[0], v[1], v[2], v[3]);
    inline for (0..4) |i| try testing.expectApproxEqAbs(c[i], back[i], 0.00001);
    const pre = premultiply(c);
    const straight = unpremultiply(pre);
    inline for (0..4) |i| try testing.expectApproxEqAbs(c[i], straight[i], 0.00001);
    try testing.expectEqual(@as(Rgba, @splat(0)), unpremultiply(@splat(0)));
}

test "XYZ and predefined wide gamut authoring spaces preserve white and extended gamut" {
    const white: Rgba = .{ 1, 1, 1, 0.7 };
    for ([_]Rgba{ a98Rgb(white), prophotoRgb(white), rec2020(white), xyzD65(.{ 0.9504559271, 1, 1.0890577508, 0.7 }) }) |converted| {
        inline for (0..3) |k| try testing.expectApproxEqAbs(@as(f32, 1), converted[k], 0.001);
        try testing.expectEqual(@as(f32, 0.7), converted[3]);
    }
    const red = rec2020(.{ 1, 0, 0, 1 });
    try testing.expect(red[0] > 1 and red[1] < 0);
}
