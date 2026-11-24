//! Caller-owned CPU effect surfaces. Pixels are premultiplied, encoded-sRGB RGBA8 words
//! (0xAABBGGRR). Padding belongs to the surface and is kept transparent. Import/export names
//! the alpha representation explicitly; the stock quad texture path needs `.straight`.
//! No allocator, resource registry, retained cache, or rendering loop is involved.

const std = @import("std");
const simd = @import("../core/simd.zig");
const color = @import("color_math.zig");

pub const Alpha = enum { straight, premultiplied };
pub const Error = error{ InvalidSize, InvalidStride, InsufficientStorage, AliasedStorage, SizeMismatch };
/// Structure-of-vectors channels; a batch is `simd.lanes` independent pixels.
pub const Batch = [4]simd.F;

/// Borrowed image. Unlike writable surfaces it needs no SIMD padding; sampling gathers only
/// valid pixels. The memory stays owned by the application for the duration of the operation.
pub const Image = struct {
    pixels: []const u32,
    width: u32,
    height: u32,
    stride: usize,
    alpha: Alpha = .straight,

    pub fn validate(im: Image) Error!void {
        if (im.stride < im.width) return error.InvalidStride;
        if (im.width == 0 or im.height == 0) return error.InvalidSize;
        const last = std.math.mul(usize, im.stride, im.height - 1) catch return error.InvalidSize;
        const size = std.math.add(usize, last, im.width) catch return error.InvalidSize;
        if (im.pixels.len < size) return error.InsufficientStorage;
    }
};

pub const Surface = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    stride: usize,

    pub fn view(s: Surface) Image {
        return .{ .pixels = s.pixels, .width = s.width, .height = s.height, .stride = s.stride, .alpha = .premultiplied };
    }

    pub fn validate(s: Surface) Error!void {
        const minimum = try rowPixels(s.width);
        if (s.stride < minimum or s.stride % simd.lanes != 0) return error.InvalidStride;
        const size = std.math.mul(usize, s.stride, s.height) catch return error.InvalidSize;
        if (s.pixels.len < size) return error.InsufficientStorage;
    }
};

pub fn rowPixels(width: u32) Error!usize {
    const n = std.math.add(usize, width, 2 * simd.lanes - 1) catch return error.InvalidSize;
    return n & ~@as(usize, simd.lanes - 1);
}

pub fn requiredPixels(width: u32, height: u32) Error!usize {
    return std.math.mul(usize, try rowPixels(width), height) catch return error.InvalidSize;
}

/// Initializes the used storage to transparent. Capacity errors leave the supplied bytes alone.
pub fn init(pixels: []u32, width: u32, height: u32) Error!Surface {
    const count = try requiredPixels(width, height);
    if (pixels.len < count) return error.InsufficientStorage;
    @memset(pixels[0..count], 0);
    return .{ .pixels = pixels[0..count], .width = width, .height = height, .stride = try rowPixels(width) };
}

pub inline fn overlaps(a: []const u32, b: []const u32) bool {
    if (a.len == 0 or b.len == 0) return false;
    const aa = @intFromPtr(a.ptr);
    const bb = @intFromPtr(b.ptr);
    return aa < bb + b.len * @sizeOf(u32) and bb < aa + a.len * @sizeOf(u32);
}

pub inline fn unpack(v: simd.U) Batch {
    return .{
        @as(simd.F, @floatFromInt(v & simd.u(255))) / simd.f(255),
        @as(simd.F, @floatFromInt((v >> simd.u(8)) & simd.u(255))) / simd.f(255),
        @as(simd.F, @floatFromInt((v >> simd.u(16)) & simd.u(255))) / simd.f(255),
        @as(simd.F, @floatFromInt(v >> simd.u(24))) / simd.f(255),
    };
}

pub inline fn pack(channels: Batch) simd.U {
    var bytes: [4]simd.U = undefined;
    inline for (0..4) |c| {
        const valid = (channels[c] <= simd.f(std.math.floatMax(f32))) & (channels[c] >= simd.f(-std.math.floatMax(f32)));
        const v = @select(f32, valid, channels[c], simd.f(0));
        bytes[c] = @intFromFloat(@round(@min(@max(v, simd.f(0)), simd.f(1)) * simd.f(255)));
    }
    return bytes[0] | (bytes[1] << simd.u(8)) | (bytes[2] << simd.u(16)) | (bytes[3] << simd.u(24));
}

pub inline fn premultiply(v: Batch) Batch {
    return .{ v[0] * v[3], v[1] * v[3], v[2] * v[3], v[3] };
}

pub inline fn unpremultiply(v: Batch) Batch {
    const reciprocal = simd.f(1) / @max(v[3], simd.f(1e-20));
    return .{ v[0] * reciprocal, v[1] * reciprocal, v[2] * reciprocal, v[3] };
}

pub inline fn splat(v: color.Rgba) Batch {
    return .{ simd.f(v[0]), simd.f(v[1]), simd.f(v[2]), simd.f(v[3]) };
}

pub inline fn load(s: Surface, x: usize, y: usize) Batch {
    return unpack(simd.loadU(s.pixels, y * s.stride + x));
}

/// Writes a complete SIMD batch; lanes past the active width are explicitly transparent.
pub inline fn store(s: Surface, x: usize, y: usize, v: Batch) void {
    const active = simd.iota + simd.u(@intCast(x)) < simd.u(s.width);
    simd.storeU(s.pixels, y * s.stride + x, @select(u32, active, pack(v), simd.u(0)));
}

pub fn clear(s: Surface, straight: color.Rgba) Error!void {
    try s.validate();
    const pixel = color.pack(color.premultiply(straight));
    for (0..s.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(s.width)) : (x += simd.lanes) {
            const active = simd.iota + simd.u(@intCast(x)) < simd.u(s.width);
            simd.storeU(s.pixels, y * s.stride + x, @select(u32, active, simd.u(pixel), simd.u(0)));
        }
        @memset(s.pixels[y * s.stride + simd.padded(s.width) .. (y + 1) * s.stride], 0);
    }
}

/// Imports a same-sized image. Exact in-place conversion is allowed; other overlap is rejected
/// before writes. Only this boundary handles unpadded images; effect passes use padded rows.
pub fn importImage(dst: Surface, src: Image) Error!void {
    try dst.validate();
    try src.validate();
    if (dst.width != src.width or dst.height != src.height) return error.SizeMismatch;
    const same = dst.pixels.ptr == src.pixels.ptr and dst.stride == src.stride;
    if (overlaps(dst.pixels, src.pixels) and !same) return error.AliasedStorage;
    for (0..dst.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const count = @min(simd.lanes, dst.width - x);
            var row: [simd.lanes]u32 = @splat(0);
            @memcpy(row[0..count], src.pixels[y * src.stride + x ..][0..count]);
            const channels = unpack(row);
            store(dst, x, y, if (src.alpha == .straight) premultiply(channels) else channels);
        }
    }
}

/// Writes tightly packed or caller-strided RGBA words. Select `.straight` for the existing
/// quad/material texture shader, which performs its own premultiplication exactly once.
pub fn exportRGBA(src: Surface, dst: []u32, stride: usize, alpha: Alpha) Error!void {
    try src.validate();
    if (stride < src.width) return error.InvalidStride;
    const size = std.math.mul(usize, stride, src.height) catch return error.InvalidSize;
    if (dst.len < size) return error.InsufficientStorage;
    const same = src.pixels.ptr == dst.ptr and src.stride == stride;
    if (overlaps(src.pixels, dst) and !same) return error.AliasedStorage;
    for (0..src.height) |y| {
        var x: usize = 0;
        while (x < simd.padded(src.width)) : (x += simd.lanes) {
            const channels = load(src, x, y);
            const pixels: [simd.lanes]u32 = pack(if (alpha == .straight) unpremultiply(channels) else channels);
            const count = @min(simd.lanes, src.width - x);
            @memcpy(dst[y * stride + x ..][0..count], pixels[0..count]);
        }
    }
}

const testing = std.testing;

test "surface capacity and transparent padding are explicit" {
    var bytes: [simd.rows(3) * 2]u32 = @splat(0xdeadbeef);
    try testing.expectError(error.InsufficientStorage, init(bytes[0..2], 3, 2));
    try testing.expectEqual(@as(u32, 0xdeadbeef), bytes[0]);
    const s = try init(&bytes, 3, 2);
    try clear(s, .{ 1, 0.5, 0, 0.5 });
    try testing.expectEqual(@as(u32, 0x80004080), bytes[0]);
    for (0..2) |y| for (3..s.stride) |x| try testing.expectEqual(@as(u32, 0), bytes[y * s.stride + x]);
}

test "texture export changes alpha representation once and preserves zero alpha" {
    var storage: [simd.rows(3)]u32 = undefined;
    const s = try init(&storage, 3, 1);
    const pixels = [_]u32{ 0x800000ff, 0xff00ff00, 0x00ffffff };
    try importImage(s, .{ .pixels = &pixels, .width = 3, .height = 1, .stride = 3 });
    var out: [3]u32 = undefined;
    try exportRGBA(s, &out, 3, .straight);
    try testing.expectEqual(@as(u32, 0x800000ff), out[0]);
    try testing.expectEqual(@as(u32, 0xff00ff00), out[1]);
    try testing.expectEqual(@as(u32, 0), out[2]);
    try testing.expectError(error.InsufficientStorage, exportRGBA(s, out[0..1], 3, .straight));
}
