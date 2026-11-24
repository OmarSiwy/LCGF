//! Optional wide-gamut/HDR color processing on caller-owned floating-point planes. Stored RGB
//! is premultiplied, linear-light, in absolute cd/m^2; alpha is a fraction. Values above SDR
//! white and out-of-gamut negative components survive until an explicit output conversion.
//!
//! These routines prepare real RGBA16F/RGBA32F/RGB10A2 data and an SDR RGBA8 fallback. They do
//! not activate an OS HDR mode or change a swapchain: the host must advertise and configure
//! that presentation capability and tag the output's primaries/transfer correctly.
//! Transfer definitions follow https://www.w3.org/TR/css-color-hdr-1/ (Working Draft), including
//! its 203-nit reference-white convention when the caller chooses that value.

const std = @import("std");
const simd = @import("../core/simd.zig");
const color = @import("color_math.zig");
const surface = @import("surface.zig");
const brushes = @import("brushes.zig");
const F = simd.F;
const Batch = surface.Batch;

pub const Error = surface.Error || error{ InvalidEncoding, InvalidColor, InvalidOpacity };
pub const Primaries = enum { srgb, display_p3, rec2020 };
/// Payloads are reference-white luminance in cd/m^2. PQ is absolute, with code 1 = 10,000
/// cd/m^2. HLG uses the CSS color-conversion convention, not a hidden display-specific OOTF.
pub const Transfer = union(enum) { linear: f32, srgb: f32, pq, hlg: f32 };
pub const Encoding = struct { primaries: Primaries = .srgb, transfer: Transfer = .{ .srgb = 203 } };
pub const ToneMap = enum { clip, reinhard };
pub const SdrOptions = struct { white_nits: f32 = 203, exposure: f32 = 1, tone_map: ToneMap = .clip, dither: bool = false };
pub const LinearSurface = struct {
    channels: [4][]f32,
    width: u32,
    height: u32,
    stride: usize,
    primaries: Primaries,

    pub fn validate(s: LinearSurface) Error!void {
        if (s.stride < try surface.rowPixels(s.width) or s.stride % simd.lanes != 0) return error.InvalidStride;
        const count = std.math.mul(usize, s.stride, s.height) catch return error.InvalidSize;
        for (s.channels) |channel| if (channel.len < count) return error.InsufficientStorage;
        inline for (0..4) |c| inline for (0..c) |previous| {
            if (surface.overlapsBytes(std.mem.sliceAsBytes(s.channels[c][0..count]), std.mem.sliceAsBytes(s.channels[previous][0..count]))) return error.AliasedStorage;
        };
    }
};

fn disjointBytes(s: LinearSurface, bytes: []const u8) Error!void {
    const count = s.stride * s.height;
    for (s.channels) |channel| if (surface.overlapsBytes(std.mem.sliceAsBytes(channel[0..count]), bytes)) return error.AliasedStorage;
}

pub fn requiredFloats(width: u32, height: u32) Error!usize {
    return std.math.mul(usize, try surface.requiredPixels(width, height), 4) catch return error.InvalidSize;
}

pub fn init(storage: []f32, width: u32, height: u32, primaries: Primaries) Error!LinearSurface {
    const count = try surface.requiredPixels(width, height);
    const length = try requiredFloats(width, height);
    if (storage.len < length) return error.InsufficientStorage;
    @memset(storage[0..length], 0);
    var channels: [4][]f32 = undefined;
    inline for (0..4) |c| channels[c] = storage[c * count .. (c + 1) * count];
    return .{ .channels = channels, .width = width, .height = height, .stride = try surface.rowPixels(width), .primaries = primaries };
}

pub inline fn load(src: LinearSurface, x: usize, y: usize) Batch {
    var values: Batch = undefined;
    inline for (0..4) |c| values[c] = simd.loadF(src.channels[c], y * src.stride + x);
    return values;
}

pub inline fn store(dst: LinearSurface, x: usize, y: usize, values: Batch) void {
    const active = simd.iota + simd.u(@intCast(x)) < simd.u(dst.width);
    inline for (0..4) |c| simd.storeF(dst.channels[c], y * dst.stride + x, @select(f32, active, values[c], simd.f(0)));
}

pub fn clear(dst: LinearSurface, straight_nits: color.Rgba) Error!void {
    try dst.validate();
    if (!color.finite(straight_nits) or straight_nits[3] < 0 or straight_nits[3] > 1) return error.InvalidColor;
    const values = surface.splat(color.premultiply(straight_nits));
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) store(dst, x, y, values);
    }
}

fn toXyz(primaries: Primaries) [9]f32 {
    return switch (primaries) {
        .srgb => .{ 0.4123907993, 0.3575843394, 0.1804807884, 0.2126390059, 0.7151686788, 0.0721923154, 0.0193308187, 0.1191947798, 0.9505321522 },
        .display_p3 => .{ 0.4865709486, 0.2656676932, 0.1982172852, 0.2289745641, 0.6917385218, 0.0792869141, 0, 0.0451133819, 1.0439443689 },
        .rec2020 => .{ 0.6369580483, 0.1446169036, 0.1688809752, 0.2627002120, 0.6779980715, 0.0593017165, 0, 0.0280726930, 1.0609850577 },
    };
}
fn fromXyz(primaries: Primaries) [9]f32 {
    return switch (primaries) {
        .srgb => .{ 3.2409699419, -1.5373831776, -0.4986107603, -0.9692436363, 1.8759675015, 0.0415550574, 0.0556300797, -0.2039769589, 1.0569715142 },
        .display_p3 => .{ 2.4934969119, -0.9313836179, -0.4027107845, -0.8294889696, 1.7626640603, 0.0236246858, 0.0358458302, -0.0761723893, 0.9568845240 },
        .rec2020 => .{ 1.7166511880, -0.3556707838, -0.2533662814, -0.6666843518, 1.6164812366, 0.0157685458, 0.0176398574, -0.0427706133, 0.9421031212 },
    };
}

/// One conversion matrix per pass, composed through D65 XYZ. It works on premultiplied
/// channels directly because primary conversion is linear and does not touch alpha.
pub fn primaryMatrix(from: Primaries, to: Primaries) [9]f32 {
    if (from == to) return .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    const a = fromXyz(to);
    const b = toXyz(from);
    var out: [9]f32 = @splat(0);
    inline for (0..3) |r| inline for (0..3) |c| inline for (0..3) |k| {
        out[r * 3 + c] += a[r * 3 + k] * b[k * 3 + c];
    };
    return out;
}

pub inline fn convertPrimaries(value: Batch, matrix: [9]f32) Batch {
    var out = value;
    inline for (0..3) |r| out[r] = value[0] * simd.f(matrix[r * 3]) + value[1] * simd.f(matrix[r * 3 + 1]) + value[2] * simd.f(matrix[r * 3 + 2]);
    return out;
}

fn validEncoding(encoding: Encoding) Error!void {
    switch (encoding.transfer) {
        .pq => {},
        .linear, .srgb, .hlg => |white| if (!std.math.isFinite(white) or white <= 0) return error.InvalidEncoding,
    }
}

inline fn pow(value: F, exponent: f32) F {
    return @select(f32, value > simd.f(0), @exp(@log(@max(value, simd.f(1e-30))) * simd.f(exponent)), simd.f(0));
}
inline fn signed(value: F, magnitude: F) F {
    return @select(f32, value < simd.f(0), -magnitude, magnitude);
}

pub fn decode(value: F, transfer: Transfer) F {
    return switch (transfer) {
        .linear => |white| value * simd.f(white),
        .srgb => |white| blk: {
            const v = @abs(value);
            const linear = @select(f32, v <= simd.f(0.04045), v / simd.f(12.92), pow((v + simd.f(0.055)) / simd.f(1.055), 2.4));
            break :blk signed(value, linear) * simd.f(white);
        },
        .pq => blk: {
            const p = pow(@min(@max(value, simd.f(0)), simd.f(1)), 32.0 / 2523.0);
            const ratio = @max(p - simd.f(3424.0 / 4096.0), simd.f(0)) / @max(simd.f(2413.0 / 128.0) - simd.f(2392.0 / 128.0) * p, simd.f(1e-20));
            break :blk pow(ratio, 16384.0 / 2610.0) * simd.f(10000);
        },
        .hlg => |white| blk: {
            const v = @abs(value);
            const linear = @select(f32, v <= simd.f(0.5), v * v / simd.f(3), (@exp((v - simd.f(0.55991073)) / simd.f(0.17883277)) + simd.f(0.28466892)) / simd.f(12));
            break :blk signed(value, linear) * simd.f(3.7743 * white);
        },
    };
}

pub fn encode(value_nits: F, transfer: Transfer) F {
    return switch (transfer) {
        .linear => |white| value_nits / simd.f(white),
        .srgb => |white| blk: {
            const v = @abs(value_nits) / simd.f(white);
            const encoded = @select(f32, v <= simd.f(0.0031308), v * simd.f(12.92), simd.f(1.055) * pow(v, 1.0 / 2.4) - simd.f(0.055));
            break :blk signed(value_nits, encoded);
        },
        .pq => blk: {
            const p = pow(@min(@max(value_nits / simd.f(10000), simd.f(0)), simd.f(1)), 2610.0 / 16384.0);
            break :blk pow((simd.f(3424.0 / 4096.0) + simd.f(2413.0 / 128.0) * p) / (simd.f(1) + simd.f(2392.0 / 128.0) * p), 2523.0 / 32.0);
        },
        .hlg => |white| blk: {
            const v = @abs(value_nits) / simd.f(3.7743 * white);
            const encoded = @select(f32, v <= simd.f(1.0 / 12.0), @sqrt(simd.f(3) * v), simd.f(0.17883277) * @log(@max(simd.f(12) * v - simd.f(0.28466892), simd.f(1e-30))) + simd.f(0.55991073));
            break :blk signed(value_nits, encoded);
        },
    };
}

pub fn fromRGBA8(dst: LinearSurface, src: surface.Image, white_nits: f32) Error!void {
    try dst.validate();
    try src.validate();
    try validEncoding(.{ .transfer = .{ .srgb = white_nits } });
    if (dst.width != src.width or dst.height != src.height) return error.SizeMismatch;
    try disjointBytes(dst, std.mem.sliceAsBytes(src.pixels));
    const matrix = primaryMatrix(.srgb, dst.primaries);
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx = @as(F, @floatFromInt(simd.iota + simd.u(@intCast(x)))) + simd.f(0.5);
            var pixel = surface.unpremultiply(brushes.sampleImage(src, xx, simd.f(@as(f32, @floatFromInt(y)) + 0.5), .nearest, .{ .transparent, .transparent }));
            inline for (0..3) |c| pixel[c] = decode(pixel[c], .{ .srgb = white_nits });
            store(dst, x, y, surface.premultiply(convertPrimaries(pixel, matrix)));
        }
    }
}

/// Real linear-light source-over, preserving highlights above reference white. Source and
/// destination may use different primaries; the primary conversion is computed once.
/// Exact in-place source/destination is supported; shifted or cross-plane aliases are rejected.
pub fn over(dst: LinearSurface, src: LinearSurface, opacity: f32) Error!void {
    try dst.validate();
    try src.validate();
    if (dst.width != src.width or dst.height != src.height) return error.SizeMismatch;
    if (!std.math.isFinite(opacity) or opacity < 0 or opacity > 1) return error.InvalidOpacity;
    var same = dst.stride == src.stride;
    inline for (0..4) |c| same = same and dst.channels[c].ptr == src.channels[c].ptr;
    if (!same) for (src.channels) |channel| try disjointBytes(dst, std.mem.sliceAsBytes(channel[0 .. src.stride * src.height]));
    const matrix = primaryMatrix(src.primaries, dst.primaries);
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            var source = convertPrimaries(load(src, x, y), matrix);
            const backdrop = load(dst, x, y);
            inline for (0..4) |c| source[c] *= simd.f(opacity);
            var result: Batch = undefined;
            inline for (0..4) |c| result[c] = source[c] + backdrop[c] * (simd.f(1) - source[3]);
            store(dst, x, y, result);
        }
    }
}

fn encodedBatch(src: LinearSurface, x: usize, y: usize, matrix: [9]f32, transfer: Transfer, alpha: surface.Alpha) Batch {
    var values = surface.unpremultiply(convertPrimaries(load(src, x, y), matrix));
    inline for (0..3) |c| values[c] = encode(values[c], transfer);
    return if (alpha == .straight) values else surface.premultiply(values);
}

/// Interleaved RGBA half or full float. Stride is in pixels, not components. Half overflow
/// saturates at the representable finite limit; no gamut or SDR clipping is otherwise applied.
pub fn exportRGBA(comptime T: type, src: LinearSurface, dst: []T, stride: usize, encoding: Encoding, alpha: surface.Alpha) Error!void {
    if (T != f16 and T != f32) @compileError("HDR export accepts f16 or f32 components");
    try src.validate();
    try validEncoding(encoding);
    if (stride < src.width) return error.InvalidStride;
    const count = std.math.mul(usize, std.math.mul(usize, stride, src.height) catch return error.InvalidSize, 4) catch return error.InvalidSize;
    if (dst.len < count) return error.InsufficientStorage;
    try disjointBytes(src, std.mem.sliceAsBytes(dst[0..count]));
    const matrix = primaryMatrix(src.primaries, encoding.primaries);
    for (0..src.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(src.width)) : (x += simd.lanes) {
            const values = encodedBatch(src, x, y, matrix, encoding.transfer, alpha);
            var interleaved: [simd.lanes * 4]T = undefined;
            inline for (0..simd.lanes) |lane| inline for (0..4) |c| {
                const value = values[c][lane];
                interleaved[lane * 4 + c] = @floatCast(if (T == f16) std.math.clamp(value, -65504, 65504) else value);
            };
            const active = @min(simd.lanes, src.width - x);
            @memcpy(dst[(y * stride + x) * 4 ..][0 .. active * 4], interleaved[0 .. active * 4]);
        }
    }
}

/// Imports interleaved encoded floating-point color, including HDR values above one for
/// linear/scRGB. The output remains linear, absolute, and premultiplied in dst's primaries.
pub fn importRGBA(comptime T: type, dst: LinearSurface, src: []const T, stride: usize, encoding: Encoding, alpha: surface.Alpha) Error!void {
    if (T != f16 and T != f32) @compileError("HDR import accepts f16 or f32 components");
    try dst.validate();
    try validEncoding(encoding);
    if (stride < dst.width) return error.InvalidStride;
    const count = std.math.mul(usize, std.math.mul(usize, stride, dst.height) catch return error.InvalidSize, 4) catch return error.InvalidSize;
    if (src.len < count) return error.InsufficientStorage;
    try disjointBytes(dst, std.mem.sliceAsBytes(src[0..count]));
    // Validate before writing so a bad decoded file cannot leave a partly converted surface.
    for (0..dst.height) |y| for (0..dst.width) |x| {
        inline for (0..4) |c| if (!std.math.isFinite(src[(y * stride + x) * 4 + c])) return error.InvalidColor;
        const a = src[(y * stride + x) * 4 + 3];
        if (a < 0 or a > 1) return error.InvalidColor;
    };
    const matrix = primaryMatrix(encoding.primaries, dst.primaries);
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            var interleaved: [simd.lanes * 4]T = @splat(0);
            const active = @min(simd.lanes, dst.width - x);
            @memcpy(interleaved[0 .. active * 4], src[(y * stride + x) * 4 ..][0 .. active * 4]);
            var values: Batch = undefined;
            inline for (0..simd.lanes) |lane| inline for (0..4) |c| {
                values[c][lane] = @floatCast(interleaved[lane * 4 + c]);
            };
            if (alpha == .premultiplied) values = surface.unpremultiply(values);
            inline for (0..3) |c| values[c] = decode(values[c], encoding.transfer);
            store(dst, x, y, surface.premultiply(convertPrimaries(values, matrix)));
        }
    }
}

pub fn exportRGB10A2(src: LinearSurface, dst: []u32, stride: usize, encoding: Encoding) Error!void {
    try src.validate();
    try validEncoding(encoding);
    if (stride < src.width) return error.InvalidStride;
    const count = std.math.mul(usize, stride, src.height) catch return error.InvalidSize;
    if (dst.len < count) return error.InsufficientStorage;
    try disjointBytes(src, std.mem.sliceAsBytes(dst[0..count]));
    const matrix = primaryMatrix(src.primaries, encoding.primaries);
    for (0..src.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(src.width)) : (x += simd.lanes) {
            const values = encodedBatch(src, x, y, matrix, encoding.transfer, .straight);
            var components: [4]simd.U = undefined;
            inline for (0..4) |c| components[c] = @intFromFloat(@round(@min(@max(values[c], simd.f(0)), simd.f(1)) * simd.f(if (c == 3) 3 else 1023)));
            const pixels: [simd.lanes]u32 = components[0] | (components[1] << simd.u(10)) | (components[2] << simd.u(20)) | (components[3] << simd.u(30));
            const active = @min(simd.lanes, src.width - x);
            @memcpy(dst[y * stride + x ..][0..active], pixels[0..active]);
        }
    }
}

/// Explicit SDR fallback with hue-preserving luminance Reinhard mapping or clipping. Ordered
/// 4x4 dither is applied at quantization only and never changes alpha or transparent pixels.
pub fn toRGBA8(dst: surface.Surface, src: LinearSurface, options: SdrOptions) Error!void {
    try dst.validate();
    try src.validate();
    if (dst.width != src.width or dst.height != src.height) return error.SizeMismatch;
    try disjointBytes(src, std.mem.sliceAsBytes(dst.pixels));
    if (!std.math.isFinite(options.white_nits) or options.white_nits <= 0 or !std.math.isFinite(options.exposure) or options.exposure < 0) return error.InvalidEncoding;
    const matrix = primaryMatrix(src.primaries, .srgb);
    const bayer = [16]f32{ 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            var values = surface.unpremultiply(convertPrimaries(load(src, x, y), matrix));
            inline for (0..3) |c| values[c] *= simd.f(options.exposure / options.white_nits);
            if (options.tone_map == .reinhard) {
                const luminance = @max(values[0] * simd.f(0.2126) + values[1] * simd.f(0.7152) + values[2] * simd.f(0.0722), simd.f(0));
                inline for (0..3) |c| values[c] /= simd.f(1) + luminance;
            }
            var dither = simd.f(0);
            if (options.dither) inline for (0..simd.lanes) |lane| {
                dither[lane] = (bayer[(y % 4) * 4 + (x + lane) % 4] / 16 - 0.46875) / 255;
            };
            inline for (0..3) |c| values[c] = @min(@max(encode(values[c], .{ .srgb = 1 }) + dither, simd.f(0)), simd.f(1));
            surface.store(dst, x, y, surface.premultiply(values));
        }
    }
}

const testing = std.testing;

test "HDR transfer reference points and round trips use explicit luminance" {
    try testing.expectApproxEqAbs(@as(f32, 1), encode(simd.f(10000), .pq)[0], 0.00001);
    try testing.expectApproxEqAbs(@as(f32, 0.58069), encode(simd.f(203), .pq)[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.75), encode(simd.f(203), .{ .hlg = 203 })[0], 0.0001);
    const transfers = [_]Transfer{ .{ .linear = 80 }, .{ .srgb = 203 }, .pq, .{ .hlg = 203 } };
    for (transfers) |transfer| {
        const value = decode(encode(simd.f(400), transfer), transfer)[0];
        try testing.expectApproxEqAbs(@as(f32, 400), value, 0.05);
    }
}

test "floating surfaces preserve HDR highlights and export actual host texture data" {
    var a: [simd.rows(2) * 4]f32 = undefined;
    var b: [simd.rows(2) * 4]f32 = undefined;
    const src = try init(&a, 2, 1, .rec2020);
    const dst = try init(&b, 2, 1, .display_p3);
    try clear(src, .{ 1000, 1000, 1000, 0.5 });
    try over(dst, src, 1);
    try testing.expectApproxEqAbs(@as(f32, 500), dst.channels[0][0], 0.001);
    var half: [8]f16 = undefined;
    try exportRGBA(f16, dst, &half, 2, .{ .primaries = .display_p3, .transfer = .{ .linear = 80 } }, .straight);
    try testing.expectEqual(@as(f16, 12.5), half[0]);
    var ten_bit: [2]u32 = undefined;
    try exportRGB10A2(src, &ten_bit, 2, .{ .primaries = .rec2020, .transfer = .pq });
    try testing.expect((ten_bit[0] & 1023) > 700);
    try importRGBA(f16, dst, &half, 2, .{ .primaries = .display_p3, .transfer = .{ .linear = 80 } }, .straight);
    try testing.expectApproxEqAbs(@as(f32, 500), dst.channels[0][0], 0.001);
}

test "SDR import conversion and tone-map fallback preserve alpha and transparent black" {
    var linear_storage: [simd.rows(2) * 4]f32 = undefined;
    var rgba_storage: [simd.rows(2)]u32 = undefined;
    const linear = try init(&linear_storage, 2, 1, .display_p3);
    const rgba = try surface.init(&rgba_storage, 2, 1);
    const image = [_]u32{ 0xffffffff, 0x00ffffff };
    try fromRGBA8(linear, .{ .pixels = &image, .width = 2, .height = 1, .stride = 2 }, 203);
    try toRGBA8(rgba, linear, .{});
    try testing.expectEqual(@as(u32, 0xffffffff), rgba.pixels[0]);
    try testing.expectEqual(@as(u32, 0), rgba.pixels[1]);
    try clear(linear, .{ 1000, 1000, 1000, 1 });
    try toRGBA8(rgba, linear, .{ .tone_map = .reinhard, .dither = true });
    try testing.expect((rgba.pixels[0] & 255) > 200 and (rgba.pixels[0] & 255) < 255);
}

test "planar HDR import export and composition reject destructive overlap before writes" {
    var storage: [simd.rows(2) * 4 + simd.lanes]f32 = undefined;
    const linear = try init(storage[0 .. simd.rows(2) * 4], 2, 1, .srgb);
    try clear(linear, .{ 203, 0, 0, 0.5 });
    const before = storage[0];
    try testing.expectError(error.AliasedStorage, exportRGBA(f32, linear, storage[0..8], 2, .{}, .straight));
    try testing.expectError(error.AliasedStorage, importRGBA(f32, linear, storage[0..8], 2, .{}, .straight));
    var shifted = linear;
    shifted.channels[0] = storage[1 .. 1 + linear.stride];
    try testing.expectError(error.AliasedStorage, over(linear, shifted, 0.5));
    try testing.expectEqual(before, storage[0]);
    var overlapping = linear;
    overlapping.channels[1] = overlapping.channels[0];
    try testing.expectError(error.AliasedStorage, overlapping.validate());
    try over(linear, linear, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.75), linear.channels[3][0], 0.0001);
}
