//! Image atlas: small images packed into one premultiplied RGBA8 texture, so quads showing
//! different icons share a texture and merge into one batch (batches split on texture,
//! prototype/ui.zig `Batch`). The scheme is Qt Quick's scene graph: images up to a size limit
//! go into a shared atlas texture and are addressed by a sub-rectangle; bigger ones, or ones
//! that no longer fit, get a texture of their own. `add` returning null is that signal.
//!
//! Packing reuses the glyph atlas's skyline (src/text/raster/atlas.zig): only its packer is
//! used, over no pixels of its own, because this atlas holds 4 bytes a texel.
//!
//! Each image is packed with a 1-texel border that repeats its edge texels, so bilinear
//! sampling at the edge of its `uv` rectangle reads the image's own colour, not a neighbour's
//! (Qt pads the same way). That covers magnification and mild minification; an image that is
//! drawn much smaller than its size wants its own texture with mipmaps, since
//! averaged levels of an atlas mix neighbours.
//!
//! Uploads work as the glyph atlas's: `takeDirty` gives the region changed since the last
//! upload, as the arguments of a texture write.

const std = @import("std");
const skyline = @import("../text/raster/atlas.zig");

pub const Rect = skyline.Atlas.Rect;
pub const Skyline = skyline.Atlas.Skyline;

pub const Atlas = struct {
    w: u32,
    h: u32,
    /// `w * h * 4` bytes of premultiplied RGBA8, row by row: the texture.
    pixels: []u8,
    /// Images wider or taller than this are not packed.
    max_side: u32,
    packer: skyline.Atlas,
    /// x0, y0, x1, y1 of texels changed since the last `takeDirty`; empty when x0 >= x1.
    dirty: [4]u32 = .{ 0, 0, 0, 0 },

    /// An empty atlas over the caller's `pixels` (`w * h * 4`, cleared here) and skyline
    /// columns (capacity `w` is always enough). Images with a side over `max_side` are refused.
    pub fn init(w: u32, h: u32, pixels: []u8, sky: Skyline, max_side: u32) Atlas {
        std.debug.assert(pixels.len >= @as(usize, w) * h * 4 and w > 2 and h > 2);
        std.debug.assert(sky.y.len == sky.x.len and sky.w.len == sky.x.len and sky.x.len >= 1);
        var a: Atlas = .{
            .w = w,
            .h = h,
            .pixels = pixels[0 .. @as(usize, w) * h * 4],
            .max_side = max_side,
            // No pixels: only the skyline is used.
            .packer = .{ .w = w, .h = h, .pixels = &.{}, .sky = sky },
        };
        a.clear();
        return a;
    }

    /// Forgets every image and clears the texture.
    pub fn clear(a: *Atlas) void {
        a.packer.clear();
        @memset(a.pixels, 0);
        a.dirty = .{ 0, 0, a.w, a.h };
    }

    /// Copies a `w` x `h` premultiplied RGBA8 image (`src`, row by row) into the atlas and
    /// returns where it is, border excluded; `uv` turns that into a quad's `uv`. Null when the
    /// image is over `max_side` or the atlas is full: draw it from a texture of its own.
    pub fn add(a: *Atlas, w: u32, h: u32, src: []const u8) ?Rect {
        std.debug.assert(w > 0 and h > 0 and src.len >= @as(usize, w) * h * 4);
        if (w > a.max_side or h > a.max_side) return null;
        const slot = a.packer.pack(w + 2, h + 2) orelse return null;
        // Rows of the padded slot: the image's rows, with the first and last repeated.
        for (0..h + 2) |row| {
            const from = std.math.clamp(row, 1, h) - 1;
            const line = src[from * w * 4 ..][0 .. w * 4];
            const to = a.pixels[((slot.y + row) * a.w + slot.x) * 4 ..][0 .. (w + 2) * 4];
            @memcpy(to[4..][0 .. w * 4], line);
            to[0..4].* = line[0..4].*;
            to[(w + 1) * 4 ..][0..4].* = line[(w - 1) * 4 ..][0..4].*;
        }
        const d = a.dirty;
        a.dirty = if (d[0] >= d[2])
            .{ slot.x, slot.y, slot.x + slot.w, slot.y + slot.h }
        else
            .{ @min(d[0], slot.x), @min(d[1], slot.y), @max(d[2], slot.x + slot.w), @max(d[3], slot.y + slot.h) };
        return .{ .x = slot.x + 1, .y = slot.y + 1, .w = w, .h = h };
    }

    /// Texture coordinates of `r`: left, top, right, bottom in 0..1 (a quad's `uv`).
    pub fn uv(a: *const Atlas, r: Rect) [4]f32 {
        return a.packer.uv(r);
    }

    /// The region to upload this frame (wgpu `queue.writeTexture`: data `pixels[offset..]`,
    /// `bytes_per_row`, origin `x`, `y`, extent `w`, `h`), or null when nothing changed.
    /// Resets the dirty bounds.
    pub fn takeDirty(a: *Atlas) ?skyline.Atlas.Upload {
        const d = a.dirty;
        if (d[0] >= d[2]) return null;
        a.dirty = .{ 0, 0, 0, 0 };
        return .{
            .x = d[0],
            .y = d[1],
            .w = d[2] - d[0],
            .h = d[3] - d[1],
            .offset = (@as(usize, d[1]) * a.w + d[0]) * 4,
            .bytes_per_row = a.w * 4,
        };
    }
};

const testing = std.testing;

test "small images pack side by side with repeated edges" {
    var pixels: [16 * 8 * 4]u8 = undefined;
    var sx: [16]u32 = undefined;
    var sy: [16]u32 = undefined;
    var sw: [16]u32 = undefined;
    var a: Atlas = .init(16, 8, &pixels, .{ .x = &sx, .y = &sy, .w = &sw }, 6);
    try testing.expect(a.takeDirty() != null);
    try testing.expectEqual(null, a.takeDirty());

    // A 2 x 2 image: texels 1, 2 / 3, 4 (every channel the same).
    var img: [16]u8 = undefined;
    for (0..4) |k| @memset(img[k * 4 ..][0..4], @intCast(k + 1));
    const r = a.add(2, 2, &img).?;
    try testing.expectEqual(Rect{ .x = 1, .y = 1, .w = 2, .h = 2 }, r);
    // The padded 4 x 4 slot: edges repeated, corners from the corner texels.
    const want = [4][4]u8{ .{ 1, 1, 2, 2 }, .{ 1, 1, 2, 2 }, .{ 3, 3, 4, 4 }, .{ 3, 3, 4, 4 } };
    for (0..4) |y| for (0..4) |x| try testing.expectEqual(want[y][x], pixels[(y * 16 + x) * 4 + 2]);
    const up = a.takeDirty().?;
    try testing.expectEqual(0, up.x);
    try testing.expectEqual(4, up.w);
    try testing.expectEqual(4, up.h);
    try testing.expectEqual(64, up.bytes_per_row);
    try testing.expectEqualSlices(f32, &.{ 1.0 / 16.0, 1.0 / 8.0, 3.0 / 16.0, 3.0 / 8.0 }, &a.uv(r));

    // The next one goes beside it; dirty covers only it.
    const r2 = a.add(2, 2, &img).?;
    try testing.expectEqual(5, r2.x);
    try testing.expectEqual(4, a.takeDirty().?.x);
}

test "large images and a full atlas are refused" {
    var pixels: [8 * 8 * 4]u8 = undefined;
    var sx: [8]u32 = undefined;
    var sy: [8]u32 = undefined;
    var sw: [8]u32 = undefined;
    var a: Atlas = .init(8, 8, &pixels, .{ .x = &sx, .y = &sy, .w = &sw }, 4);
    const img: [5 * 5 * 4]u8 = @splat(9);
    try testing.expectEqual(null, a.add(5, 1, &img)); // over max_side
    try testing.expect(a.add(4, 4, &img) != null); // 6 x 6 padded
    try testing.expectEqual(null, a.add(4, 4, &img)); // no room left
    try testing.expectEqual(null, a.add(1, 1, &img)); // 3 x 3 padded: 2 texels left beside it, 2 above
    a.clear();
    try testing.expect(a.add(1, 1, &img) != null);
}
