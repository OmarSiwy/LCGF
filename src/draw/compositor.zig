//! Optional CPU compositing and filters, tier 0. The caller chooses surfaces, ordering,
//! snapshots, and scratch. Rendering an isolated subtree is: draw into a transparent surface,
//! apply its masks/filters, then `composite` once with group opacity. There is no hidden layer
//! allocation or traversal. Every pixel pass operates on SIMD batches in caller-owned storage.

const std = @import("std");
const simd = @import("../core/simd.zig");
const color = @import("color_math.zig");
const surface = @import("surface.zig");
const brushes = @import("brushes.zig");
const F = simd.F;
const Batch = surface.Batch;

pub const Error = surface.Error || error{ InvalidOpacity, InvalidFilter, InvalidColor };
pub const Operator = enum { clear, source, destination, source_over, destination_over, source_in, destination_in, source_out, destination_out, source_atop, destination_atop, xor, plus };
pub const Blend = enum { normal, multiply, screen, overlay, darken, lighten, color_dodge, color_burn, hard_light, soft_light, difference, exclusion, hue, saturation, color, luminosity };
pub const Options = struct { offset: [2]i32 = .{ 0, 0 }, opacity: f32 = 1, operator: Operator = .source_over, blend: Blend = .normal };
pub const MaskMode = enum { alpha, luminance, linear_luminance };
pub const MaskOperator = enum { add, subtract, intersect, exclude };
pub const FilterSpace = enum { srgb, linear_srgb };
pub const Morphology = enum { dilate, erode };

inline fn minimum(c: Batch) F {
    return @min(@min(c[0], c[1]), c[2]);
}
inline fn maximum(c: Batch) F {
    return @max(@max(c[0], c[1]), c[2]);
}
inline fn luminosity(c: Batch) F {
    return simd.f(0.3) * c[0] + simd.f(0.59) * c[1] + simd.f(0.11) * c[2];
}
inline fn saturation(c: Batch) F {
    return maximum(c) - minimum(c);
}
inline fn setSaturation(c: Batch, sat: F) Batch {
    const lo = minimum(c);
    const scale = sat / @max(maximum(c) - lo, simd.f(1e-20));
    return .{ (c[0] - lo) * scale, (c[1] - lo) * scale, (c[2] - lo) * scale, c[3] };
}
inline fn setLuminosity(c: Batch, lum: F) Batch {
    const diff = lum - luminosity(c);
    var out: Batch = .{ c[0] + diff, c[1] + diff, c[2] + diff, c[3] };
    const lo = minimum(out);
    const hi = maximum(out);
    inline for (0..3) |k| {
        const low = lum + (out[k] - lum) * lum / @max(lum - lo, simd.f(1e-20));
        out[k] = @select(f32, lo < simd.f(0), low, out[k]);
        const high = lum + (out[k] - lum) * (simd.f(1) - lum) / @max(hi - lum, simd.f(1e-20));
        out[k] = @select(f32, hi > simd.f(1), high, out[k]);
    }
    return out;
}

/// W3C compositing blend functions on straight encoded-sRGB channels. Alpha is handled by
/// `combine`, not by these color functions; nonseparable modes preserve the backdrop's lightness.
pub fn blendColor(backdrop: Batch, source: Batch, mode: Blend) Batch {
    switch (mode) {
        .normal => return source,
        .hue => return setLuminosity(setSaturation(source, saturation(backdrop)), luminosity(backdrop)),
        .saturation => return setLuminosity(setSaturation(backdrop, saturation(source)), luminosity(backdrop)),
        .color => return setLuminosity(source, luminosity(backdrop)),
        .luminosity => return setLuminosity(backdrop, luminosity(source)),
        else => {},
    }
    var result = source;
    inline for (0..3) |k| {
        const b = backdrop[k];
        const s = source[k];
        const one = simd.f(1);
        result[k] = switch (mode) {
            .multiply => b * s,
            .screen => b + s - b * s,
            .overlay => @select(f32, b <= simd.f(0.5), simd.f(2) * b * s, one - simd.f(2) * (one - b) * (one - s)),
            .darken => @min(b, s),
            .lighten => @max(b, s),
            .color_dodge => @select(f32, b == simd.f(0), simd.f(0), @select(f32, s >= one, one, @min(one, b / @max(one - s, simd.f(1e-20))))),
            .color_burn => @select(f32, b >= one, one, @select(f32, s <= simd.f(0), simd.f(0), one - @min(one, (one - b) / @max(s, simd.f(1e-20))))),
            .hard_light => @select(f32, s <= simd.f(0.5), simd.f(2) * b * s, one - simd.f(2) * (one - b) * (one - s)),
            .soft_light => blk: {
                const d = @select(f32, b <= simd.f(0.25), ((simd.f(16) * b - simd.f(12)) * b + simd.f(4)) * b, @sqrt(@max(b, simd.f(0))));
                break :blk @select(f32, s <= simd.f(0.5), b - (one - simd.f(2) * s) * b * (one - b), b + (simd.f(2) * s - one) * (d - b));
            },
            .difference => @abs(b - s),
            .exclusion => b + s - simd.f(2) * b * s,
            else => unreachable,
        };
    }
    return result;
}

/// Combines batches of premultiplied colors. Opacity is applied to the flattened source once.
/// This is also the low-level primitive used by decoration layers; no surface is required.
pub fn combine(backdrop: Batch, source: Batch, alpha: F, operator: Operator, blend: Blend) Batch {
    var s = source;
    inline for (0..4) |k| s[k] *= alpha;
    if (blend != .normal) {
        const mixed = blendColor(surface.unpremultiply(backdrop), surface.unpremultiply(s), blend);
        inline for (0..3) |k| s[k] = (simd.f(1) - backdrop[3]) * s[k] + backdrop[3] * s[3] * mixed[k];
    }
    const one = simd.f(1);
    const zero = simd.f(0);
    const factors: [2]F = switch (operator) {
        .clear => .{ zero, zero },
        .source => .{ one, zero },
        .destination => .{ zero, one },
        .source_over => .{ one, one - s[3] },
        .destination_over => .{ one - backdrop[3], one },
        .source_in => .{ backdrop[3], zero },
        .destination_in => .{ zero, s[3] },
        .source_out => .{ one - backdrop[3], zero },
        .destination_out => .{ zero, one - s[3] },
        .source_atop => .{ backdrop[3], one - s[3] },
        .destination_atop => .{ one - backdrop[3], s[3] },
        .xor => .{ one - backdrop[3], one - s[3] },
        .plus => .{ one, one },
    };
    var out: Batch = undefined;
    inline for (0..4) |k| out[k] = @min(@max(s[k] * factors[0] + backdrop[k] * factors[1], zero), one);
    return out;
}

fn validOpacity(value: f32) Error!void {
    if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidOpacity;
}

pub fn composite(dst: surface.Surface, src: surface.Image, options: Options) Error!void {
    try dst.validate();
    try src.validate();
    try validOpacity(options.opacity);
    if (surface.overlaps(dst.pixels, src.pixels)) return error.AliasedStorage;
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx: F = @floatFromInt(simd.iota + simd.u(@intCast(x)));
            const yy: f32 = @floatFromInt(y);
            const sample = brushes.sampleImage(src, xx + simd.f(0.5 - @as(f32, @floatFromInt(options.offset[0]))), simd.f(yy + 0.5 - @as(f32, @floatFromInt(options.offset[1]))), .nearest, .{ .transparent, .transparent });
            surface.store(dst, x, y, combine(surface.load(dst, x, y), sample, simd.f(options.opacity), options.operator, options.blend));
        }
    }
}

/// Takes a bounded backdrop snapshot at an explicit origin. Call it before painting the
/// foreground that must not participate in its own backdrop filter; then filter and composite.
pub fn capture(dst: surface.Surface, src: surface.Image, origin: [2]i32, edge: [2]brushes.Address) Error!void {
    try dst.validate();
    try src.validate();
    if (surface.overlaps(dst.pixels, src.pixels)) return error.AliasedStorage;
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx: F = @floatFromInt(simd.iota + simd.u(@intCast(x)));
            surface.store(dst, x, y, brushes.sampleImage(src, xx + simd.f(0.5 + @as(f32, @floatFromInt(origin[0]))), simd.f(@as(f32, @floatFromInt(y)) + 0.5 + @as(f32, @floatFromInt(origin[1]))), .nearest, edge));
        }
    }
}

inline fn decode(v: F) F {
    const a = @max(v, simd.f(0));
    return @select(f32, a <= simd.f(0.04045), a / simd.f(12.92), @exp(@log((a + simd.f(0.055)) / simd.f(1.055)) * simd.f(2.4)));
}
inline fn encode(v: F) F {
    const a = @max(v, simd.f(0));
    return @select(f32, a <= simd.f(0.0031308), a * simd.f(12.92), simd.f(1.055) * @exp(@log(@max(a, simd.f(1e-30))) * simd.f(1.0 / 2.4)) - simd.f(0.055));
}

pub fn maskCoverage(pixels: Batch, mode: MaskMode) F {
    if (mode == .alpha) return pixels[3];
    var c = surface.unpremultiply(pixels);
    if (mode == .linear_luminance) inline for (0..3) |k| {
        c[k] = decode(c[k]);
    };
    return (c[0] * simd.f(0.2126) + c[1] * simd.f(0.7152) + c[2] * simd.f(0.0722)) * c[3];
}

pub const MaskOptions = struct { origin: [2]f32 = .{ 0, 0 }, mode: MaskMode = .alpha, invert: bool = false, opacity: f32 = 1, sampling: brushes.Sampling = .linear };

pub fn applyMask(dst: surface.Surface, mask: surface.Image, options: MaskOptions) Error!void {
    try dst.validate();
    try mask.validate();
    try validOpacity(options.opacity);
    if (!std.math.isFinite(options.origin[0]) or !std.math.isFinite(options.origin[1])) return error.InvalidFilter;
    if (surface.overlaps(dst.pixels, mask.pixels)) return error.AliasedStorage;
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx: F = @floatFromInt(simd.iota + simd.u(@intCast(x)));
            const m = brushes.sampleImage(mask, xx + simd.f(0.5 - options.origin[0]), simd.f(@as(f32, @floatFromInt(y)) + 0.5 - options.origin[1]), options.sampling, .{ .transparent, .transparent });
            const coverage = maskCoverage(m, options.mode);
            const factor = (if (options.invert) simd.f(1) - coverage else coverage) * simd.f(options.opacity);
            var pixel = surface.load(dst, x, y);
            inline for (0..4) |k| pixel[k] *= factor;
            surface.store(dst, x, y, pixel);
        }
    }
}

/// Combines multiple mask layers into an alpha surface. The resulting RGB is white
/// premultiplied by alpha; that surface can be fed to `applyMask` or reused as a path clip.
pub fn combineMask(dst: surface.Surface, src: surface.Image, mode: MaskMode, operator: MaskOperator) Error!void {
    try dst.validate();
    try src.validate();
    if (dst.width != src.width or dst.height != src.height) return error.SizeMismatch;
    if (surface.overlaps(dst.pixels, src.pixels)) return error.AliasedStorage;
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx: F = @floatFromInt(simd.iota + simd.u(@intCast(x)));
            const b = surface.load(dst, x, y)[3];
            const a = maskCoverage(brushes.sampleImage(src, xx + simd.f(0.5), simd.f(@as(f32, @floatFromInt(y)) + 0.5), .nearest, .{ .transparent, .transparent }), mode);
            const alpha = switch (operator) {
                .add => a + b - a * b,
                .subtract => a * (simd.f(1) - b),
                .intersect => a * b,
                .exclude => a * (simd.f(1) - b) + b * (simd.f(1) - a),
            };
            surface.store(dst, x, y, .{ alpha, alpha, alpha, alpha });
        }
    }
}

/// A 4x5 matrix on straight color, in the selected space. Matrices can be concatenated before
/// a single pixel pass when their space is the same and no intermediate clamping is required.
pub const ColorMatrix = struct {
    values: [20]f32 = .{ 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0 },
    space: FilterSpace = .srgb,
};

pub fn brightness(amount: f32) ColorMatrix {
    var m: ColorMatrix = .{};
    inline for (0..3) |k| m.values[k * 5 + k] = amount;
    return m;
}
pub fn contrast(amount: f32) ColorMatrix {
    var m = brightness(amount);
    inline for (0..3) |k| m.values[k * 5 + 4] = 0.5 * (1 - amount);
    return m;
}
pub fn saturate(amount: f32) ColorMatrix {
    var m: ColorMatrix = .{};
    const weights = [3]f32{ 0.213, 0.715, 0.072 };
    inline for (0..3) |r| inline for (0..3) |c| {
        m.values[r * 5 + c] = weights[c] * (1 - amount) + if (r == c) amount else 0;
    };
    return m;
}
pub fn grayscale(amount: f32) ColorMatrix {
    return saturate(1 - amount);
}
pub fn invert(amount: f32) ColorMatrix {
    var m = brightness(1 - 2 * amount);
    inline for (0..3) |k| m.values[k * 5 + 4] = amount;
    return m;
}
pub fn sepia(amount: f32) ColorMatrix {
    const matrix = [9]f32{ 0.393, 0.769, 0.189, 0.349, 0.686, 0.168, 0.272, 0.534, 0.131 };
    var m: ColorMatrix = .{};
    inline for (0..3) |r| inline for (0..3) |c| {
        m.values[r * 5 + c] = amount * matrix[r * 3 + c] + if (r == c) 1 - amount else 0;
    };
    return m;
}
pub fn hueRotate(radians: f32) ColorMatrix {
    const c = @cos(radians);
    const s = @sin(radians);
    return .{ .values = .{
        0.213 + 0.787 * c - 0.213 * s, 0.715 - 0.715 * c - 0.715 * s, 0.072 - 0.072 * c + 0.928 * s, 0, 0,
        0.213 - 0.213 * c + 0.143 * s, 0.715 + 0.285 * c + 0.140 * s, 0.072 - 0.072 * c - 0.283 * s, 0, 0,
        0.213 - 0.213 * c - 0.787 * s, 0.715 - 0.715 * c + 0.715 * s, 0.072 + 0.928 * c + 0.072 * s, 0, 0,
        0,                             0,                             0,                             1, 0,
    } };
}
pub fn opacity(amount: f32) ColorMatrix {
    var m: ColorMatrix = .{};
    m.values[18] = amount;
    return m;
}

/// `first`, then `second`. Clipping between two separate filter calls is intentionally not
/// reproduced by fusing; applications choose that boundary explicitly.
pub fn concatenate(first: ColorMatrix, second: ColorMatrix) Error!ColorMatrix {
    if (first.space != second.space) return error.InvalidFilter;
    var out: ColorMatrix = .{ .space = first.space, .values = @splat(0) };
    inline for (0..4) |r| inline for (0..5) |c| {
        inline for (0..4) |k| out.values[r * 5 + c] += second.values[r * 5 + k] * first.values[k * 5 + c];
        if (c == 4) out.values[r * 5 + c] += second.values[r * 5 + 4];
    };
    return out;
}

pub fn colorMatrix(dst: surface.Surface, matrix: ColorMatrix) Error!void {
    try dst.validate();
    for (matrix.values) |v| if (!std.math.isFinite(v)) return error.InvalidFilter;
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            var source = surface.unpremultiply(surface.load(dst, x, y));
            if (matrix.space == .linear_srgb) inline for (0..3) |k| {
                source[k] = decode(source[k]);
            };
            var out: Batch = undefined;
            inline for (0..4) |r| {
                out[r] = simd.f(matrix.values[r * 5 + 4]);
                inline for (0..4) |k| out[r] += source[k] * simd.f(matrix.values[r * 5 + k]);
                out[r] = @min(@max(out[r], simd.f(0)), simd.f(1));
            }
            if (matrix.space == .linear_srgb) inline for (0..3) |k| {
                out[k] = encode(out[k]);
            };
            surface.store(dst, x, y, surface.premultiply(out));
        }
    }
}

pub fn gaussianKernelLength(sigma: f32) Error!usize {
    if (!std.math.isFinite(sigma) or sigma < 0 or sigma > 1_000_000) return error.InvalidFilter;
    return 2 * @as(usize, @intFromFloat(@ceil(3 * sigma))) + 1;
}

/// Symmetric, normalized Gaussian, truncated at three sigma. Explicit kernel storage lets a
/// caller retain coefficients across frames; sigma zero is the exact identity kernel.
pub fn gaussianKernel(sigma: f32, storage: []f32) Error![]const f32 {
    const length = try gaussianKernelLength(sigma);
    if (storage.len < length) return error.InsufficientStorage;
    if (sigma == 0) {
        storage[0] = 1;
        return storage[0..1];
    }
    const radius: f32 = @floatFromInt(length / 2);
    var sum: f32 = 0;
    for (storage[0..length], 0..) |*v, i| {
        const distance = @as(f32, @floatFromInt(i)) - radius;
        v.* = @exp(-distance * distance / (2 * sigma * sigma));
        sum += v.*;
    }
    for (storage[0..length]) |*v| v.* /= sum;
    return storage[0..length];
}

fn filterSurfaces(src: surface.Surface, dst: surface.Surface, scratch: surface.Surface) Error!void {
    try src.validate();
    try dst.validate();
    try scratch.validate();
    if (src.width != dst.width or src.height != dst.height or scratch.width != dst.width or scratch.height != dst.height) return error.SizeMismatch;
    if (surface.overlaps(src.pixels, scratch.pixels) or surface.overlaps(dst.pixels, scratch.pixels)) return error.AliasedStorage;
    if (surface.overlaps(src.pixels, dst.pixels) and (src.pixels.ptr != dst.pixels.ptr or src.stride != dst.stride)) return error.AliasedStorage;
}

fn convolutionAxis(src: surface.Image, dst: surface.Surface, kernel: []const f32, axis: usize, edge: [2]brushes.Address) void {
    const radius: f32 = @floatFromInt(kernel.len / 2);
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx: F = @as(F, @floatFromInt(simd.iota + simd.u(@intCast(x)))) + simd.f(0.5);
            const yy = simd.f(@as(f32, @floatFromInt(y)) + 0.5);
            var sum: Batch = @splat(simd.f(0));
            for (kernel, 0..) |weight, i| {
                const offset = @as(f32, @floatFromInt(i)) - radius;
                const pixel = brushes.sampleImage(src, xx + simd.f(if (axis == 0) offset else 0), yy + simd.f(if (axis == 1) offset else 0), .nearest, edge);
                inline for (0..4) |c| sum[c] += pixel[c] * simd.f(weight);
            }
            surface.store(dst, x, y, sum);
        }
    }
}

/// Separable convolution of premultiplied RGBA. `src` and `dst` may be exactly the same
/// surface. Scratch must be disjoint. Edge mode is part of the result, never a backend default.
pub fn blur(src: surface.Surface, dst: surface.Surface, scratch: surface.Surface, kernel: []const f32, edge: [2]brushes.Address) Error!void {
    try filterSurfaces(src, dst, scratch);
    if (kernel.len == 0 or kernel.len % 2 != 1) return error.InvalidFilter;
    var sum: f32 = 0;
    for (kernel) |v| {
        if (!std.math.isFinite(v) or v < 0) return error.InvalidFilter;
        sum += v;
    }
    if (@abs(sum - 1) > 0.0001) return error.InvalidFilter;
    convolutionAxis(src.view(), scratch, kernel, 0, edge);
    convolutionAxis(scratch.view(), dst, kernel, 1, edge);
}

fn morphologyAxis(src: surface.Image, dst: surface.Surface, radius: u32, axis: usize, mode: Morphology, edge: [2]brushes.Address) void {
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx: F = @as(F, @floatFromInt(simd.iota + simd.u(@intCast(x)))) + simd.f(0.5);
            const yy = simd.f(@as(f32, @floatFromInt(y)) + 0.5);
            var out: Batch = @splat(simd.f(if (mode == .dilate) 0 else 1));
            for (0..2 * @as(usize, radius) + 1) |k| {
                const offset = @as(f32, @floatFromInt(k)) - @as(f32, @floatFromInt(radius));
                const p = brushes.sampleImage(src, xx + simd.f(if (axis == 0) offset else 0), yy + simd.f(if (axis == 1) offset else 0), .nearest, edge);
                inline for (0..4) |c| out[c] = if (mode == .dilate) @max(out[c], p[c]) else @min(out[c], p[c]);
            }
            surface.store(dst, x, y, out);
        }
    }
}

pub fn morphology(src: surface.Surface, dst: surface.Surface, scratch: surface.Surface, radius: [2]u32, mode: Morphology, edge: [2]brushes.Address) Error!void {
    try filterSurfaces(src, dst, scratch);
    if (radius[0] > 1_000_000 or radius[1] > 1_000_000) return error.InvalidFilter;
    morphologyAxis(src.view(), scratch, radius[0], 0, mode, edge);
    morphologyAxis(scratch.view(), dst, radius[1], 1, mode, edge);
}

/// A true alpha-shaped drop shadow, as distinct from the inexpensive analytic box-shadow
/// primitive. Allocate the source surface with the desired transparent halo before calling.
pub fn dropShadow(src: surface.Surface, dst: surface.Surface, scratch: surface.Surface, kernel: []const f32, offset: [2]i32, tint: color.Rgba) Error!void {
    try filterSurfaces(src, dst, scratch);
    if (surface.overlaps(src.pixels, dst.pixels)) return error.AliasedStorage;
    if (!color.finite(tint) or tint[3] < 0 or tint[3] > 1) return error.InvalidColor;
    try blur(src, dst, scratch, kernel, .{ .transparent, .transparent });
    try surface.importImage(scratch, dst.view());
    const pre = color.premultiply(tint);
    for (0..scratch.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(scratch.width)) : (x += simd.lanes) {
            const a = surface.load(scratch, x, y)[3];
            surface.store(scratch, x, y, .{ a * simd.f(pre[0]), a * simd.f(pre[1]), a * simd.f(pre[2]), a * simd.f(pre[3]) });
        }
    }
    try surface.clear(dst, @splat(0));
    try composite(dst, scratch.view(), .{ .offset = offset });
    try composite(dst, src.view(), .{});
}

pub const Displacement = struct { scale: [2]f32, channels: [2]u2 = .{ 0, 1 }, sampling: brushes.Sampling = .linear, edge: [2]brushes.Address = .{ .transparent, .transparent } };

pub fn displace(dst: surface.Surface, src: surface.Image, map: surface.Image, options: Displacement) Error!void {
    try dst.validate();
    try src.validate();
    try map.validate();
    if (!std.math.isFinite(options.scale[0]) or !std.math.isFinite(options.scale[1])) return error.InvalidFilter;
    if (surface.overlaps(dst.pixels, src.pixels) or surface.overlaps(dst.pixels, map.pixels)) return error.AliasedStorage;
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx: F = @as(F, @floatFromInt(simd.iota + simd.u(@intCast(x)))) + simd.f(0.5);
            const yy = simd.f(@as(f32, @floatFromInt(y)) + 0.5);
            const d = surface.unpremultiply(brushes.sampleImage(map, xx, yy, .linear, .{ .clamp, .clamp }));
            surface.store(dst, x, y, brushes.sampleImage(src, xx + (d[options.channels[0]] - simd.f(0.5)) * simd.f(options.scale[0]), yy + (d[options.channels[1]] - simd.f(0.5)) * simd.f(options.scale[1]), options.sampling, options.edge));
        }
    }
}

const testing = std.testing;

test "isolated group opacity is applied once after opaque overlap" {
    var a: [simd.rows(2)]u32 = undefined;
    var b: [simd.rows(2)]u32 = undefined;
    const dst = try surface.init(&a, 2, 1);
    const group = try surface.init(&b, 2, 1);
    try surface.clear(group, .{ 1, 0, 0, 1 });
    const blue = [_]u32{0xffff0000};
    try composite(group, .{ .pixels = &blue, .width = 1, .height = 1, .stride = 1 }, .{ .offset = .{ 1, 0 } });
    try composite(dst, group.view(), .{ .opacity = 0.5 });
    try testing.expectEqual(@as(u32, 128), dst.pixels[0] >> 24);
    try testing.expectEqual(@as(u32, 128), dst.pixels[1] >> 24);
    try testing.expectEqual(@as(u32, 0x80800000), dst.pixels[1]);
}

test "Porter Duff and blend modes produce premultiplied values" {
    const b = surface.splat(.{ 0.4, 0.2, 0.1, 0.5 });
    const s = surface.splat(.{ 0.1, 0.2, 0.3, 0.5 });
    const inside = combine(b, s, simd.f(1), .source_in, .normal);
    try testing.expectEqual(@as(f32, 0.25), inside[3][0]);
    try testing.expectEqual(@as(f32, 0.05), inside[0][0]);
    inline for (@typeInfo(Blend).@"enum".field_names) |name| {
        const result = combine(b, s, simd.f(1), .source_over, @field(Blend, name));
        inline for (0..3) |k| try testing.expect(result[k][0] >= 0 and result[k][0] <= result[3][0]);
    }
}

test "mask luminance, inversion and alpha are distinct" {
    var a: [simd.rows(1)]u32 = undefined;
    const dst = try surface.init(&a, 1, 1);
    const mask = [_]u32{0xff000000};
    const im: surface.Image = .{ .pixels = &mask, .width = 1, .height = 1, .stride = 1 };
    try surface.clear(dst, .{ 1, 1, 1, 1 });
    try applyMask(dst, im, .{ .mode = .alpha });
    try testing.expectEqual(@as(u32, 0xffffffff), dst.pixels[0]);
    try applyMask(dst, im, .{ .mode = .luminance });
    try testing.expectEqual(@as(u32, 0), dst.pixels[0]);
    try surface.clear(dst, .{ 1, 1, 1, 1 });
    try applyMask(dst, im, .{ .mode = .luminance, .invert = true });
    try testing.expectEqual(@as(u32, 0xffffffff), dst.pixels[0]);
}

test "bounded backdrop snapshot blur and matrix passes are caller scheduled" {
    var a: [simd.rows(5) * 3]u32 = undefined;
    var b: [simd.rows(5) * 3]u32 = undefined;
    var c: [simd.rows(5) * 3]u32 = undefined;
    const backdrop = try surface.init(&a, 5, 3);
    const effect = try surface.init(&b, 5, 3);
    const scratch = try surface.init(&c, 5, 3);
    backdrop.pixels[backdrop.stride + 2] = 0xffffffff;
    try capture(effect, backdrop.view(), .{ 0, 0 }, .{ .transparent, .transparent });
    var weights: [7]f32 = undefined;
    const kernel = try gaussianKernel(1, &weights);
    try blur(effect, effect, scratch, kernel, .{ .transparent, .transparent });
    try testing.expect(effect.pixels[effect.stride + 2] >> 24 < 255);
    try testing.expect(effect.pixels[effect.stride + 1] >> 24 > 0);
    try testing.expectEqual(@as(u32, 0xffffffff), backdrop.pixels[backdrop.stride + 2]);
    try colorMatrix(effect, try concatenate(invert(1), opacity(0.5)));
    try testing.expectEqual(@as(u32, 0), effect.pixels[effect.stride + 2] & 0x00ffffff);
    try morphology(backdrop, effect, scratch, .{ 1, 1 }, .dilate, .{ .transparent, .transparent });
    try testing.expectEqual(@as(u32, 0xffffffff), effect.pixels[1]);
}

test "displacement and alpha drop shadow are rendered with explicit storage" {
    var a: [simd.rows(5)]u32 = undefined;
    var b: [simd.rows(5)]u32 = undefined;
    var c: [simd.rows(5)]u32 = undefined;
    const src = try surface.init(&a, 5, 1);
    const dst = try surface.init(&b, 5, 1);
    const scratch = try surface.init(&c, 5, 1);
    src.pixels[1] = 0xffffffff;
    var weights: [1]f32 = undefined;
    try dropShadow(src, dst, scratch, try gaussianKernel(0, &weights), .{ 2, 0 }, .{ 1, 0, 0, 0.5 });
    try testing.expectEqual(@as(u32, 0xffffffff), dst.pixels[1]);
    try testing.expectEqual(@as(u32, 0x80000080), dst.pixels[3]);
    const map = [_]u32{0xff0080ff};
    try displace(dst, src.view(), .{ .pixels = &map, .width = 1, .height = 1, .stride = 1 }, .{ .scale = .{ 2, 0 }, .sampling = .nearest });
    try testing.expectEqual(@as(u32, 0xffffffff), dst.pixels[0]);
}
