//! Images decoded at compile time: `embed(@embedFile("icon.png"))` runs the PNG decoder
//! (png.zig) in the compiler, so the binary holds the premultiplied RGBA8 pixels in read-only
//! data and the program never decodes, allocates or reads a file for them. A broken file is a
//! compile error naming the decoder's error, not a failure at run time.
//!
//! The price is compile time: the decoder runs interpreted, about 0.7 ms per pixel on the
//! machine this was written on (a 64 x 64 RGBA image took 3 s), and the binary holds 4 bytes a
//! pixel instead of the compressed file. That suits icons and small UI art; large images go
//! through `png.decode` at run time, or a background thread (C0759).

const std = @import("std");
const png = @import("png.zig");

/// A decoded image: `w * h` premultiplied RGBA8 pixels, row by row, in read-only data.
pub const Image = struct {
    w: u32,
    h: u32,
    pixels: []const u8,
};

/// Decodes `file` (a PNG, usually `@embedFile(...)`) at compile time.
pub fn embed(comptime file: []const u8) Image {
    comptime {
        const i = png.info(file) catch |e| @compileError("embed: not a decodable PNG: " ++ @errorName(e));
        // The interpreter counts backward branches; decoding takes a few dozen a byte.
        @setEvalBranchQuota(1_000_000 + 200 * (i.pixelBytes() + i.scratchBytes()));
        var pixels: [i.pixelBytes()]u8 = undefined;
        var scratch: [i.scratchBytes()]u8 = undefined;
        _ = png.decode(file, &pixels, &scratch) catch |e| @compileError("embed: not a decodable PNG: " ++ @errorName(e));
        const out = pixels;
        return .{ .w = i.w, .h = i.h, .pixels = &out };
    }
}

/// Pixel (x, y) of testdata/icon16.png before premultiplying: `pixel` in testdata/make.py.
fn icon16Pixel(x: u32, y: u32) [4]u8 {
    return .{
        @intCast(x * 255 / 15),
        @intCast(y * 255 / 15),
        @intCast(((x ^ y) * 16) % 256),
        if ((x / 4 + y / 4) % 2 == 0) 255 else 128,
    };
}

fn premultiplied(c: [4]u8) [4]u8 {
    var out = c;
    for (0..3) |k| out[k] = @intCast((@as(u16, c[k]) * c[3] + 127) / 255);
    return out;
}

test "an embedded image is decoded by the compiler" {
    const icon = comptime embed(@embedFile("testdata/icon16.png"));
    // Known at compile time: no decode runs in the program.
    comptime std.debug.assert(icon.w == 16 and icon.h == 16 and icon.pixels.len == 16 * 16 * 4);
    comptime std.debug.assert(icon.pixels[4 * 17 + 3] == 255);
    for (0..16) |y| for (0..16) |x| {
        const want = premultiplied(icon16Pixel(@intCast(x), @intCast(y)));
        try std.testing.expectEqualSlices(u8, &want, icon.pixels[(y * 16 + x) * 4 ..][0..4]);
    };
}

test "embedding matches decoding at run time" {
    const file = @embedFile("testdata/icon16.png");
    const icon = comptime embed(file);
    var pixels: [16 * 16 * 4]u8 = undefined;
    var scratch: [2048]u8 = undefined;
    _ = try png.decode(file, &pixels, &scratch);
    try std.testing.expectEqualSlices(u8, &pixels, icon.pixels);
}
