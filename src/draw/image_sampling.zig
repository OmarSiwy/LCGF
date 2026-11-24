//! Optional image preparation: orientation, area/linear resampling, and caller-owned mipmaps.
//! These are independent operations over borrowed Images and writable Surfaces. Pixel loops
//! run in SIMD batches. Linear-light filtering operates on premultiplied linear channels,
//! then encodes the result; transparent source colors cannot contaminate opaque edges.

const std = @import("std");
const simd = @import("../core/simd.zig");
const surface = @import("surface.zig");
const brushes = @import("brushes.zig");
const F = simd.F;
const Batch = surface.Batch;
pub const Space = enum { srgb, linear_srgb };
pub const Filter = enum { nearest, linear, area };
pub const Options = struct { filter: Filter = .area, space: Space = .linear_srgb };
pub const Error = brushes.Error;

inline fn decode(v: F) F {
    const a = @max(v, simd.f(0));
    return @select(f32, a <= simd.f(0.04045), a / simd.f(12.92), @exp(@log((a + simd.f(0.055)) / simd.f(1.055)) * simd.f(2.4)));
}
inline fn encode(v: F) F {
    const a = @max(v, simd.f(0));
    return @select(f32, a <= simd.f(0.0031308), a * simd.f(12.92), simd.f(1.055) * @exp(@log(@max(a, simd.f(1e-30))) * simd.f(1.0 / 2.4)) - simd.f(0.055));
}
fn working(value: Batch, space: Space) Batch {
    if (space == .srgb) return value;
    var result = surface.unpremultiply(value);
    inline for (0..3) |channel| result[channel] = decode(result[channel]) * result[3];
    return result;
}
fn encoded(value: Batch, space: Space) Batch {
    if (space == .srgb) return value;
    var result = surface.unpremultiply(value);
    inline for (0..3) |channel| result[channel] = encode(result[channel]) * result[3];
    return result;
}
fn validate(dst: surface.Surface, src: surface.Image) Error!void {
    try dst.validate();
    try src.validate();
    if (surface.overlaps(dst.pixels, src.pixels)) return error.AliasedStorage;
}

/// Materializes EXIF orientation. A 90-degree/transposed result swaps width and height.
/// The same orientation can instead remain in ImageBrush for allocation-free sampling.
pub fn orient(dst: surface.Surface, src: surface.Image, orientation: brushes.Orientation) Error!void {
    try validate(dst, src);
    const swapped = switch (orientation) {
        .normal, .mirror_x, .rotate_180, .mirror_y => false,
        else => true,
    };
    if (dst.width != (if (swapped) src.height else src.width) or dst.height != (if (swapped) src.width else src.height)) return error.SizeMismatch;
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const u = (@as(F, @floatFromInt(simd.iota + simd.u(@intCast(x)))) + simd.f(0.5)) / simd.f(@floatFromInt(dst.width));
            const v = simd.f((@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(dst.height)));
            const point = brushes.orientedUv(u, v, orientation);
            surface.store(dst, x, y, brushes.sampleImage(src, point[0] * simd.f(@floatFromInt(src.width)), point[1] * simd.f(@floatFromInt(src.height)), .nearest, .{ .clamp, .clamp }));
        }
    }
}

fn sampleLinear(src: surface.Image, x: F, y: F, space: Space) Batch {
    const x0 = @floor(x - simd.f(0.5));
    const y0 = @floor(y - simd.f(0.5));
    const fx = x - simd.f(0.5) - x0;
    const fy = y - simd.f(0.5) - y0;
    const a = working(brushes.sampleImage(src, x0 + simd.f(0.5), y0 + simd.f(0.5), .nearest, .{ .clamp, .clamp }), space);
    const b = working(brushes.sampleImage(src, x0 + simd.f(1.5), y0 + simd.f(0.5), .nearest, .{ .clamp, .clamp }), space);
    const c = working(brushes.sampleImage(src, x0 + simd.f(0.5), y0 + simd.f(1.5), .nearest, .{ .clamp, .clamp }), space);
    const d = working(brushes.sampleImage(src, x0 + simd.f(1.5), y0 + simd.f(1.5), .nearest, .{ .clamp, .clamp }), space);
    var result: Batch = undefined;
    inline for (0..4) |channel| result[channel] = (a[channel] * (simd.f(1) - fx) + b[channel] * fx) * (simd.f(1) - fy) + (c[channel] * (simd.f(1) - fx) + d[channel] * fx) * fy;
    return encoded(result, space);
}

/// Resizes the entire source. Area filtering integrates each output footprint, including
/// partial edge texels for odd sizes; bilinear and nearest are useful for enlargement.
pub fn resample(dst: surface.Surface, src: surface.Image, options: Options) Error!void {
    try validate(dst, src);
    if (dst.width == 0 or dst.height == 0) return error.InvalidSize;
    const sx = @as(f32, @floatFromInt(src.width)) / @as(f32, @floatFromInt(dst.width));
    const sy = @as(f32, @floatFromInt(src.height)) / @as(f32, @floatFromInt(dst.height));
    const columns: usize = @intFromFloat(@ceil(sx) + 1);
    const rows: usize = @intFromFloat(@ceil(sy) + 1);
    for (0..dst.height) |y| {
        const top = @as(f32, @floatFromInt(y)) * sy;
        const bottom = top + sy;
        const first_y = @floor(top);
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const left = @as(F, @floatFromInt(simd.iota + simd.u(@intCast(x)))) * simd.f(sx);
            const right = left + simd.f(sx);
            const center_x = left + simd.f(sx * 0.5);
            const center_y = simd.f(top + sy * 0.5);
            const result = switch (options.filter) {
                .nearest => brushes.sampleImage(src, center_x, center_y, .nearest, .{ .clamp, .clamp }),
                .linear => sampleLinear(src, center_x, center_y, options.space),
                .area => blk: {
                    var sum: Batch = @splat(simd.f(0));
                    const first_x = @floor(left);
                    for (0..rows) |j| {
                        const yy = first_y + @as(f32, @floatFromInt(j));
                        const wy = @max(0, @min(bottom, yy + 1) - @max(top, yy));
                        for (0..columns) |i| {
                            const xx = first_x + simd.f(@floatFromInt(i));
                            const wx = @max(simd.f(0), @min(right, xx + simd.f(1)) - @max(left, xx));
                            const value = working(brushes.sampleImage(src, xx + simd.f(0.5), simd.f(yy + 0.5), .nearest, .{ .clamp, .clamp }), options.space);
                            const weight = wx * simd.f(wy / (sx * sy));
                            inline for (0..4) |channel| sum[channel] += value[channel] * weight;
                        }
                    }
                    break :blk encoded(sum, options.space);
                },
            };
            surface.store(dst, x, y, result);
        }
    }
}

/// Number of levels after level zero. Odd dimensions follow GPU floor-halving dimensions.
pub fn mipCount(width: u32, height: u32) u32 {
    var extent = @max(width, height);
    var count: u32 = 0;
    while (extent > 1) : (extent /= 2) count += 1;
    return count;
}
pub fn mipSize(width: u32, height: u32, level: u32) [2]u32 {
    return if (level >= 32) .{ 1, 1 } else .{ @max(width >> @as(u5, @intCast(level)), 1), @max(height >> @as(u5, @intCast(level)), 1) };
}
/// Produces as many successive levels as supplied. Every level is validated for dimensions
/// and aliasing before the first write; the caller may retain the levels or rebuild them.
pub fn mipChain(src: surface.Image, levels: []surface.Surface, space: Space) Error!void {
    try src.validate();
    if (levels.len > mipCount(src.width, src.height)) return error.InvalidSize;
    for (levels, 0..) |level, i| {
        try level.validate();
        const size = mipSize(src.width, src.height, @intCast(i + 1));
        if (level.width != size[0] or level.height != size[1]) return error.SizeMismatch;
        if (surface.overlaps(src.pixels, level.pixels)) return error.AliasedStorage;
        for (levels[0..i]) |earlier| if (surface.overlaps(earlier.pixels, level.pixels)) return error.AliasedStorage;
    }
    var previous = src;
    for (levels) |level| {
        try resample(level, previous, .{ .filter = .area, .space = space });
        previous = level.view();
    }
}

const testing = std.testing;
test "EXIF rotations materialize and sample the same oriented pixels" {
    const input: [6]u32 = .{ 0xff000001, 0xff000002, 0xff000003, 0xff000004, 0xff000005, 0xff000006 };
    const src: surface.Image = .{ .pixels = &input, .width = 3, .height = 2, .stride = 3 };
    var pixels: [simd.rows(2) * 3]u32 = undefined;
    const dst = try surface.init(&pixels, 2, 3);
    try orient(dst, src, .rotate_90);
    try testing.expectEqual(@as(u32, 0xff000004), dst.pixels[0]);
    try testing.expectEqual(@as(u32, 0xff000001), dst.pixels[1]);
    try testing.expectEqual(@as(u32, 0xff000006), dst.pixels[2 * dst.stride]);
    const b: brushes.Brush = .{ .image = .{ .image = src, .source = .{ .x1 = 3, .y1 = 2 }, .destination = .{ .x1 = 2, .y1 = 3 }, .area = .{ .x1 = 2, .y1 = 3 }, .orientation = .rotate_90, .sampling = .nearest } };
    try testing.expectEqual(dst.pixels[0], surface.pack(brushes.sample(b, simd.f(0.5), simd.f(0.5)))[0]);
}
test "area filtering retains odd edges and premultiplies before linear light filtering" {
    const src_pixels: [3]u32 = .{ 0xff000000, 0xffffffff, 0x000000ff };
    const src: surface.Image = .{ .pixels = &src_pixels, .width = 3, .height = 1, .stride = 3 };
    var pixels: [simd.rows(1)]u32 = undefined;
    const dst = try surface.init(&pixels, 1, 1);
    try resample(dst, src, .{});
    const packed_value = dst.pixels[0];
    try testing.expectEqual(@as(u32, 170), packed_value >> 24);
    try testing.expect(@abs(@as(i32, @intCast(packed_value & 255)) - 125) <= 1);
    try testing.expectEqual(packed_value & 255, (packed_value >> 8) & 255);
    try testing.expectEqual(packed_value & 255, (packed_value >> 16) & 255);
}
test "caller mip chain is consumed by fractional LOD sampling" {
    const source_pixels: [8]u32 = .{ 0xff000000, 0xffffffff, 0xff000000, 0xffffffff, 0xff000000, 0xffffffff, 0xff000000, 0xffffffff };
    const src: surface.Image = .{ .pixels = &source_pixels, .width = 4, .height = 2, .stride = 4 };
    var first_pixels: [simd.rows(2)]u32 = undefined;
    var last_pixels: [simd.rows(1)]u32 = undefined;
    var levels = [_]surface.Surface{ try surface.init(&first_pixels, 2, 1), try surface.init(&last_pixels, 1, 1) };
    try mipChain(src, &levels, .srgb);
    const images = [_]surface.Image{ levels[0].view(), levels[1].view() };
    var b: brushes.Brush = .{ .image = .{ .image = src, .source = .{ .x1 = 4, .y1 = 2 }, .destination = .{ .x1 = 4, .y1 = 2 }, .area = .{ .x1 = 4, .y1 = 2 }, .mipmaps = &images, .lod = 0.5, .sampling = .nearest } };
    try brushes.validate(b);
    const value = brushes.sample(b, simd.f(0.5), simd.f(0.5))[0][0];
    try testing.expectApproxEqAbs(@as(f32, 64.0 / 255.0), value, 0.002);
    b.image.lod = 2;
    try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), brushes.sample(b, simd.f(0.5), simd.f(0.5))[0][0], 0.001);
    try testing.expectEqual(@as(f32, 2), try brushes.imageLod(.{ 4, 0 }, .{ 0, 2 }));
}
