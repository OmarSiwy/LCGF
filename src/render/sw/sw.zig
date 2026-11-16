//! The software back end: draws a `DrawList` into a caller-owned framebuffer on the CPU, with the
//! semantics of the stock quad shader (src/render/shaders/quad.wgsl) so its pixels match the GPU
//! back ends' golden images. No GPU, no allocation, no OS.
//!
//! Framebuffer rows are padded to whole vectors, so every span is whole vectors with a mask for
//! the pixels outside the quad or the scissor; there is no scalar tail.

const std = @import("std");
const simd = @import("../../core/simd.zig");
const types = @import("../../core/types.zig");
const Color = types.Color;

/// Byte order of a pixel in memory.
pub const Format = enum(u8) { rgba8, bgra8 };

/// The render target: `height` rows of `stride` pixels, one u32 each, owned by the caller.
pub const Framebuffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    /// `width` padded to whole vectors (`simd.padded`); pixels past `width` are scratch.
    stride: u32,
    format: Format,

    /// Pixels a `width` x `height` framebuffer needs.
    pub fn len(width: u32, height: u32) usize {
        return simd.padded(width) * height;
    }

    pub fn init(pixels: []u32, width: u32, height: u32, format: Format) Framebuffer {
        std.debug.assert(pixels.len >= len(width, height));
        return .{ .pixels = pixels, .width = width, .height = height, .stride = @intCast(simd.padded(width)), .format = format };
    }

    /// Whole framebuffer as a scissor rect.
    pub fn all(fb: *const Framebuffer) [4]u32 {
        return .{ 0, 0, fb.width, fb.height };
    }

    /// Shift of red in a pixel; blue sits at 16 minus it.
    inline fn red(fb: *const Framebuffer) u5 {
        return @as(u5, @intFromBool(fb.format == .bgra8)) * 16;
    }

    /// `c` in this framebuffer's byte order.
    pub fn pack(fb: *const Framebuffer, c: Color) u32 {
        const r = fb.red();
        return (@as(u32, c.r) << r) | (@as(u32, c.g) << 8) | (@as(u32, c.b) << (16 - r)) | (@as(u32, c.a) << 24);
    }

    /// Pixel (x, y) as a colour.
    pub fn at(fb: *const Framebuffer, x: u32, y: u32) Color {
        const p = fb.pixels[y * fb.stride + x];
        const r = fb.red();
        return .{ .r = @truncate(p >> r), .g = @truncate(p >> 8), .b = @truncate(p >> (16 - r)), .a = @truncate(p >> 24) };
    }

    pub fn clear(fb: *Framebuffer, c: Color) void {
        @memset(fb.pixels[0..len(fb.width, fb.height)], fb.pack(c));
    }
};

const testing = std.testing;

fn Frame(comptime w: u32, comptime h: u32) type {
    return struct {
        px: [Framebuffer.len(w, h)]u32 = undefined,
        fn fb(f: *@This(), format: Format) Framebuffer {
            return .init(&f.px, w, h, format);
        }
    };
}

test "framebuffer: RGBA8 and BGRA8 byte order, rows padded to whole vectors" {
    var f: Frame(5, 3) = .{};
    for ([_]Format{ .rgba8, .bgra8 }) |format| {
        var fb = f.fb(format);
        try testing.expectEqual(simd.padded(5), fb.stride);
        fb.clear(.rgba(10, 20, 30, 40));
        try testing.expectEqual(Color.rgba(10, 20, 30, 40), fb.at(4, 2));
        const bytes: [4]u8 = @bitCast(fb.pixels[fb.stride + 1]);
        const want: [4]u8 = if (format == .rgba8) .{ 10, 20, 30, 40 } else .{ 30, 20, 10, 40 };
        try testing.expectEqual(want, bytes);
    }
}
