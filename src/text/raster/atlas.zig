//! Glyph atlas: one 8-bit coverage texture that glyph images are packed into. Tier 0: the
//! caller owns the pixels and the packer's columns.
//!
//! Packing is a skyline (Jylänki, "A Thousand Ways to Pack the Bin", 2010; the scheme Qt Quick's
//! scene graph uses for its glyph and texture atlases): the packed area is described by its top
//! edge, a list of horizontal segments left to right. A rectangle goes where its top would be
//! lowest (bottom-left rule), resting on the highest segment under it; the segments it covers
//! are replaced by one at its top. The skyline cannot reclaim space under a segment, which is
//! what keeps it to a handful of segments per row of glyphs; glyphs are similar in height, so
//! little is wasted.
//!
//! Packing runs once per glyph the atlas has not seen, not per frame or per pixel, so it is
//! plain scalar code over a short list.
//!
//! `Cache` puts a glyph table on top: which glyph image is where, and when it was last drawn.
//! When the atlas is full it evicts the glyphs not drawn recently and repacks the rest from
//! scratch, tallest first, which also recovers the space the skyline had lost.
//!
//! Uploads: the atlas tracks the bounds of what changed since the last upload (`takeDirty`),
//! so the host writes only that region of its texture each frame (in the prototype the host
//! owns the GPU texture and hands its view to `Renderer.addTexture`; prototype/ui_wgpu.zig).
//!
//! The atlas contract of `fonts.Mono.quads` (prototype/ui.zig): a glyph's quad samples the
//! rectangle `uv` of the texture, in 0..1 (`uv`).

const std = @import("std");
const simd = @import("../../core/simd.zig");
const none = @import("../../core/types.zig").none;

pub const Atlas = struct {
    w: u32,
    h: u32,
    /// `w * h` coverage bytes, row by row: the texture.
    pixels: []u8,
    sky: Skyline,
    /// Segments in use.
    sky_len: u32 = 1,
    /// Bounds of the pixels changed since the last `takeDirty`: x0, y0, x1, y1 (empty when
    /// x0 >= x1). One rectangle, not a list: the skyline puts one frame's new glyphs next to
    /// each other, so their bounds are tight.
    dirty: [4]u32 = .{ 0, 0, 0, 0 },

    /// The skyline, left to right: segment i spans x[i] .. x[i] + w[i] at height y[i] (rows
    /// from the top that are taken). Capacity is the slices' length; `w` (the atlas width) is
    /// always enough, since every segment is at least a pixel wide.
    pub const Skyline = struct { x: []u32, y: []u32, w: []u32 };

    /// A packed rectangle.
    pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

    /// An empty atlas over the caller's `pixels` (`w * h`, cleared here) and skyline columns.
    pub fn init(w: u32, h: u32, pixels: []u8, sky: Skyline) Atlas {
        std.debug.assert(pixels.len >= @as(usize, w) * h and w > 0 and h > 0);
        std.debug.assert(sky.y.len == sky.x.len and sky.w.len == sky.x.len and sky.x.len >= 1);
        var a: Atlas = .{ .w = w, .h = h, .pixels = pixels[0 .. @as(usize, w) * h], .sky = sky };
        a.clear();
        return a;
    }

    /// Forgets every packed rectangle and clears the texture.
    pub fn clear(a: *Atlas) void {
        a.sky.x[0] = 0;
        a.sky.y[0] = 0;
        a.sky.w[0] = a.w;
        a.sky_len = 1;
        @memset(a.pixels, 0);
        a.dirty = .{ 0, 0, a.w, a.h };
    }

    /// Room for a `w` x `h` rectangle, or null when the atlas has none. Reserves it: the
    /// skyline rises over it. Glyphs sampled with bilinear filtering need a gap of a pixel
    /// between them; pack `w + 1` x `h + 1` and use the top-left `w` x `h`.
    pub fn pack(a: *Atlas, w: u32, h: u32) ?Rect {
        std.debug.assert(w > 0 and h > 0);
        var best: u32 = std.math.maxInt(u32);
        var best_top: u32 = std.math.maxInt(u32);
        var best_y: u32 = 0;
        for (0..a.sky_len) |i| {
            const y = a.restingHeight(@intCast(i), w) orelse continue;
            if (y + h > a.h) continue;
            // Lowest top wins; among equal tops, the leftmost (the first found).
            if (y + h < best_top) {
                best = @intCast(i);
                best_top = y + h;
                best_y = y;
            }
        }
        if (best == std.math.maxInt(u32)) return null;
        // The new segment, plus at most one split of a segment it covers part of.
        if (a.sky_len + 1 > a.sky.x.len) return null;
        const r: Rect = .{ .x = a.sky.x[best], .y = best_y, .w = w, .h = h };
        a.rise(best, r);
        return r;
    }

    /// The height a rectangle `w` wide would rest at with its left side on segment `i`: the
    /// highest segment under it. Null when it would stick out on the right.
    fn restingHeight(a: *const Atlas, i: u32, w: u32) ?u32 {
        if (a.sky.x[i] + w > a.w) return null;
        var y: u32 = 0;
        var left = w;
        var j = i;
        while (left > 0) : (j += 1) {
            y = @max(y, a.sky.y[j]);
            left -= @min(left, a.sky.w[j]);
        }
        return y;
    }

    /// Raises the skyline over `r`, whose left side is segment `i`'s: one segment at its top
    /// replaces the ones it covers, then neighbours of equal height merge.
    fn rise(a: *Atlas, i: u32, r: Rect) void {
        const s = a.sky;
        const right = r.x + r.w;
        a.insertSegment(i, r.x, r.y + r.h, r.w);
        // Drop the segments now under the new one, and trim the one it ends inside.
        const j = i + 1;
        while (j < a.sky_len and s.x[j] < right) {
            const end = s.x[j] + s.w[j];
            if (end <= right) {
                a.removeSegment(j);
                continue;
            }
            s.w[j] = end - right;
            s.x[j] = right;
            break;
        }
        var k: u32 = 0;
        while (k + 1 < a.sky_len) {
            if (s.y[k] == s.y[k + 1]) {
                s.w[k] += s.w[k + 1];
                a.removeSegment(k + 1);
            } else k += 1;
        }
    }

    fn insertSegment(a: *Atlas, i: u32, x: u32, y: u32, w: u32) void {
        const n = a.sky_len;
        inline for (.{ a.sky.x, a.sky.y, a.sky.w }) |col| std.mem.copyBackwards(u32, col[i + 1 .. n + 1], col[i..n]);
        a.sky.x[i] = x;
        a.sky.y[i] = y;
        a.sky.w[i] = w;
        a.sky_len = n + 1;
    }

    fn removeSegment(a: *Atlas, i: u32) void {
        const n = a.sky_len;
        inline for (.{ a.sky.x, a.sky.y, a.sky.w }) |col| std.mem.copyForwards(u32, col[i .. n - 1], col[i + 1 .. n]);
        a.sky_len = n - 1;
    }

    /// Copies a `r.w` x `r.h` image (row by row, `src.len >= r.w * r.h`) into the texture at `r`.
    pub fn put(a: *Atlas, r: Rect, src: []const u8) void {
        std.debug.assert(r.x + r.w <= a.w and r.y + r.h <= a.h and src.len >= @as(usize, r.w) * r.h);
        for (0..r.h) |row| {
            const to = (@as(usize, r.y) + row) * a.w + r.x;
            @memcpy(a.pixels[to..][0..r.w], src[row * r.w ..][0..r.w]);
        }
        const d = a.dirty;
        const empty = d[0] >= d[2];
        a.dirty = if (empty)
            .{ r.x, r.y, r.x + r.w, r.y + r.h }
        else
            .{ @min(d[0], r.x), @min(d[1], r.y), @max(d[2], r.x + r.w), @max(d[3], r.y + r.h) };
    }

    /// The part of the texture to upload this frame: a region of `pixels` the GPU copy has
    /// not seen, as the arguments of a texture write (wgpu `queue.writeTexture`: data
    /// `pixels[offset..]`, `bytes_per_row`, origin `x`, `y`, extent `w`, `h`). Null when
    /// nothing changed. Resets the dirty bounds: the caller uploads what this returns.
    pub fn takeDirty(a: *Atlas) ?Upload {
        const d = a.dirty;
        if (d[0] >= d[2]) return null;
        a.dirty = .{ 0, 0, 0, 0 };
        return .{
            .x = d[0],
            .y = d[1],
            .w = d[2] - d[0],
            .h = d[3] - d[1],
            .offset = @as(usize, d[1]) * a.w + d[0],
            .bytes_per_row = a.w,
        };
    }

    pub const Upload = struct {
        x: u32,
        y: u32,
        w: u32,
        h: u32,
        /// Byte offset of the region's first pixel in `pixels`.
        offset: usize,
        /// Row pitch of the source: the atlas width.
        bytes_per_row: u32,
    };

    /// Texture coordinates of `r`: left, top, right, bottom in 0..1 (a quad's `uv`).
    pub fn uv(a: *const Atlas, r: Rect) [4]f32 {
        const w: f32 = @floatFromInt(a.w);
        const h: f32 = @floatFromInt(a.h);
        return .{
            @as(f32, @floatFromInt(r.x)) / w,
            @as(f32, @floatFromInt(r.y)) / h,
            @as(f32, @floatFromInt(r.x + r.w)) / w,
            @as(f32, @floatFromInt(r.y + r.h)) / h,
        };
    }
};

/// Key of one glyph image: face (< 64), glyph id, pixel size (< 256) and subpixel bin (< 4),
/// packed into 32 bits, so two different images never share a key.
pub fn key(face: u32, glyph: u16, px: u32, bin: u32) u32 {
    std.debug.assert(face < 64 and px < 256 and bin < 4);
    return (face << 26) | (bin << 24) | (px << 16) | glyph;
}

/// The atlas plus its glyph table: one row per image in the atlas. Rows are in no particular
/// order and move on `evict`; a row index is valid until the next `evict` or `repack`.
pub const Cache = struct {
    atlas: Atlas,
    rows: Rows,
    len: u32 = 0,

    /// Capacity is `rows(cap)` rows per column (the simd padding contract, for `find`).
    pub const Rows = struct {
        key: []u32,
        /// Where the image is; `w`, `h` without the gap.
        rect: []Atlas.Rect,
        /// Frame the image was last drawn in.
        used: []u32,
    };

    pub fn init(atlas: Atlas, rows: Rows) Cache {
        std.debug.assert(rows.rect.len == rows.key.len and rows.used.len == rows.key.len);
        std.debug.assert(rows.key.len >= simd.rows(1));
        return .{ .atlas = atlas, .rows = rows };
    }

    fn cap(c: *const Cache) u32 {
        return @intCast(c.rows.key.len - simd.lanes);
    }

    /// Row of the image with key `k`, or `none`. SIMD.
    pub fn find(c: *const Cache, k: u32) u32 {
        return simd.find(c.rows.key, c.len, k);
    }

    /// Room for a `w` x `h` image with key `k` drawn in `frame`: a new row with its rectangle,
    /// or `none` when the atlas or the table is full. The caller rasterises into it with
    /// `atlas.put(rows.rect[row], image)`.
    pub fn insert(c: *Cache, k: u32, w: u32, h: u32, frame: u32) u32 {
        if (c.len == c.cap() or w == 0 or h == 0) return none;
        const slot = c.atlas.pack(w + 1, h + 1) orelse return none;
        const i = c.len;
        c.rows.key[i] = k;
        c.rows.rect[i] = .{ .x = slot.x, .y = slot.y, .w = w, .h = h };
        c.rows.used[i] = frame;
        c.len = i + 1;
        return i;
    }

    /// Drops every image last drawn before frame `keep_from`. Their space comes back on the
    /// next `repack`. Write-always compaction: no branch per row.
    pub fn evict(c: *Cache, keep_from: u32) void {
        var w: u32 = 0;
        for (0..c.len) |i| {
            c.rows.key[w] = c.rows.key[i];
            c.rows.rect[w] = c.rows.rect[i];
            c.rows.used[w] = c.rows.used[i];
            w += @intFromBool(c.rows.used[i] >= keep_from);
        }
        // Rows past len stay inert for `find`, which masks them by `len` anyway.
        c.len = w;
    }

    /// Packs the remaining images again from an empty skyline, tallest first, moving their
    /// pixels: `scratch` (at least `atlas.w * atlas.h` bytes) holds the old texture meanwhile.
    /// Returns the number of images that no longer fit and were dropped (0 unless the table
    /// was nearly full to begin with). Rows move; the whole texture changes.
    pub fn repack(c: *Cache, scratch: []u8) u32 {
        const a = &c.atlas;
        @memcpy(scratch[0..a.pixels.len], a.pixels);
        a.clear();
        std.mem.sortUnstableContext(0, c.len, ByHeight{ .rows = c.rows });
        var kept: u32 = 0;
        for (0..c.len) |i| {
            const old = c.rows.rect[i];
            const slot = a.pack(old.w + 1, old.h + 1) orelse continue;
            const new: Atlas.Rect = .{ .x = slot.x, .y = slot.y, .w = old.w, .h = old.h };
            for (0..old.h) |row| {
                @memcpy(
                    a.pixels[(new.y + row) * a.w + new.x ..][0..old.w],
                    scratch[(old.y + row) * a.w + old.x ..][0..old.w],
                );
            }
            c.rows.key[kept] = c.rows.key[i];
            c.rows.rect[kept] = new;
            c.rows.used[kept] = c.rows.used[i];
            kept += 1;
        }
        const dropped = c.len - kept;
        c.len = kept;
        return dropped;
    }

    /// The common case in one call: the row of image `k` for `frame`, marked drawn, inserted
    /// if new (`fresh` says the caller must rasterise into it). When the atlas is full, images
    /// not drawn in `frame` are evicted and the rest repacked, once. `none` when even that
    /// leaves no room: this frame draws more than the atlas holds.
    pub fn reserve(c: *Cache, k: u32, w: u32, h: u32, frame: u32, scratch: []u8) struct { row: u32, fresh: bool } {
        const found = c.find(k);
        if (found != none) {
            c.rows.used[found] = frame;
            return .{ .row = found, .fresh = false };
        }
        var row = c.insert(k, w, h, frame);
        if (row == none and w != 0 and h != 0) {
            c.evict(frame);
            _ = c.repack(scratch);
            row = c.insert(k, w, h, frame);
        }
        return .{ .row = row, .fresh = row != none };
    }

    const ByHeight = struct {
        rows: Rows,
        pub fn lessThan(ctx: ByHeight, i: usize, j: usize) bool {
            return ctx.rows.rect[i].h > ctx.rows.rect[j].h;
        }
        pub fn swap(ctx: ByHeight, i: usize, j: usize) void {
            std.mem.swap(u32, &ctx.rows.key[i], &ctx.rows.key[j]);
            std.mem.swap(Atlas.Rect, &ctx.rows.rect[i], &ctx.rows.rect[j]);
            std.mem.swap(u32, &ctx.rows.used[i], &ctx.rows.used[j]);
        }
    };
};

// ---------------------------------------------------------------------------------------------

const raster = @import("raster.zig");
const opentype = @import("../font/opentype.zig");

/// Columns for a skyline of up to `n` segments.
fn TestSky(comptime n: usize) type {
    return struct {
        x: [n]u32 = undefined,
        y: [n]u32 = undefined,
        w: [n]u32 = undefined,

        fn sky(t: *@This()) Atlas.Skyline {
            return .{ .x = &t.x, .y = &t.y, .w = &t.w };
        }
    };
}

fn overlap(p: Atlas.Rect, q: Atlas.Rect) bool {
    return p.x < q.x + q.w and q.x < p.x + p.w and p.y < q.y + q.h and q.y < p.y + p.h;
}

test "glyph images packed into the atlas match the references" {
    // Every image of testdata/ref.bin (160: 8 glyphs, 5 sizes, 4 subpixel shifts), rasterised,
    // packed with a pixel of gap and copied in; then each is read back out of the texture.
    const face = try opentype.Face.parse(raster.test_font, 0);
    var cols: raster.TestOutline = .{};
    var o = cols.outline();
    var acc: [64 * 64]f32 = undefined;
    var cov: [64 * 64]u8 = undefined;
    var pixels: [256 * 256]u8 = undefined;
    var sky: TestSky(256) = .{};
    var a: Atlas = .init(256, 256, &pixels, sky.sky());
    var rects: [160]Atlas.Rect = undefined;
    var boxes: [160]raster.Box = undefined;
    var refs: [160]raster.Ref = undefined;
    var n: usize = 0;
    var it: raster.RefIter = .{};
    while (it.next()) |r| {
        if (r.b.w == 0) continue;
        const b, const img = raster.render(face, r, &o, &acc, &cov);
        const slot = a.pack(b.w + 1, b.h + 1) orelse return error.AtlasFull;
        const rect: Atlas.Rect = .{ .x = slot.x, .y = slot.y, .w = b.w, .h = b.h };
        a.put(rect, img);
        rects[n] = rect;
        boxes[n] = b;
        refs[n] = r;
        n += 1;
    }
    try std.testing.expectEqual(160, n);
    var used: usize = 0;
    var total: raster.Diff = .{};
    for (rects[0..n], boxes[0..n], refs[0..n], 0..) |rect, b, r, i| {
        used += (@as(usize, rect.w) + 1) * (rect.h + 1);
        for (rects[0..i]) |other| try std.testing.expect(!overlap(.{ .x = rect.x, .y = rect.y, .w = rect.w + 1, .h = rect.h + 1 }, other));
        // Read back from the texture and compare with FreeType's image, as raster.zig does.
        var back: [64 * 64]u8 = undefined;
        for (0..rect.h) |row| @memcpy(back[row * rect.w ..][0..rect.w], a.pixels[(rect.y + row) * a.w + rect.x ..][0..rect.w]);
        const d = raster.compare(b, back[0 .. @as(usize, b.w) * b.h], r);
        total.max = @max(total.max, d.max);
        total.sum += d.sum;
        total.pixels += d.pixels;
    }
    // The bounds of raster.zig's reference test: packing moved the images, nothing else.
    try std.testing.expect(total.max <= 16);
    try std.testing.expect(total.sum < total.pixels);
    // The skyline wastes little on glyphs of similar height: the 160 images (gaps included)
    // fill 79% of the area under its highest segment (measured: 36,718 of 256 x 182 px).
    var top: u32 = 0;
    for (a.sky.y[0..a.sky_len]) |y| top = @max(top, y);
    try std.testing.expect(used * 100 >= 75 * @as(usize, a.w) * top);
}

test "a full atlas refuses, and the skyline stays in order" {
    var pixels: [16 * 16]u8 = undefined;
    var sky: TestSky(16) = .{};
    var a: Atlas = .init(16, 16, &pixels, sky.sky());
    try std.testing.expectEqual(Atlas.Rect{ .x = 0, .y = 0, .w = 10, .h = 4 }, a.pack(10, 4).?);
    try std.testing.expectEqual(Atlas.Rect{ .x = 10, .y = 0, .w = 6, .h = 2 }, a.pack(6, 2).?);
    // Lowest top: beside the 6 x 2 (top 2 + 3 = 5) beats the 10 x 4 (4 + 3).
    try std.testing.expectEqual(Atlas.Rect{ .x = 10, .y = 2, .w = 5, .h = 3 }, a.pack(5, 3).?);
    try std.testing.expectEqual(null, a.pack(17, 1));
    try std.testing.expectEqual(null, a.pack(1, 17));
    // Segments now at heights 4, 5, 2: a full-width rectangle rests on the highest.
    try std.testing.expectEqual(3, a.sky_len);
    try std.testing.expectEqual(null, a.pack(16, 12));
    try std.testing.expectEqual(Atlas.Rect{ .x = 0, .y = 5, .w = 16, .h = 11 }, a.pack(16, 11).?);
    try std.testing.expectEqual(null, a.pack(1, 1));
    try std.testing.expectEqual(1, a.sky_len);
    try std.testing.expectEqual([4]f32{ 0, 0.3125, 1, 1 }, a.uv(.{ .x = 0, .y = 5, .w = 16, .h = 11 }));
}

test "glyph images survive eviction and repacking" {
    // Ten frames, each drawing every image of one size (8 glyphs, 4 shifts) from
    // testdata/ref.bin, cycling 9, 13, 16, 24, 40 px twice, through an atlas too small for
    // all of them. After every frame each image of the frame is read back and compared with
    // FreeType's, and so is every older image that survived.
    const face = try opentype.Face.parse(raster.test_font, 0);
    var cols: raster.TestOutline = .{};
    var o = cols.outline();
    var acc: [64 * 64]f32 = undefined;
    var cov: [64 * 64]u8 = undefined;
    var pixels: [256 * 128]u8 = undefined;
    var scratch: [256 * 128]u8 = undefined;
    var sky: TestSky(256) = .{};
    const n = 64;
    var keys: [simd.rows(n)]u32 = @splat(0);
    var rects: [simd.rows(n)]Atlas.Rect = undefined;
    var used: [simd.rows(n)]u32 = undefined;
    var c: Cache = .init(.init(256, 128, &pixels, sky.sky()), .{ .key = &keys, .rect = &rects, .used = &used });
    // The reference of every key, to check survivors.
    var all: [160]raster.Ref = undefined;
    var all_len: usize = 0;
    var it: raster.RefIter = .{};
    while (it.next()) |r| : (all_len += 1) all[all_len] = r;
    const sizes = [_]u16{ 9, 13, 16, 24, 40 };
    var repacks: u32 = 0;
    var frame: u32 = 1;
    while (frame <= 10) : (frame += 1) {
        const px = sizes[(frame - 1) % sizes.len];
        for (all) |r| {
            if (r.px != px) continue;
            const b, const img = raster.render(face, r, &o, &acc, &cov);
            const before = c.len;
            const got = c.reserve(refKey(face, r), b.w, b.h, frame, &scratch);
            try std.testing.expect(got.row != none);
            repacks += @intFromBool(got.fresh and c.len <= before);
            if (got.fresh) c.atlas.put(c.rows.rect[got.row], img);
        }
        // Everything still in the table reads back as its reference image.
        for (c.rows.key[0..c.len], c.rows.rect[0..c.len]) |k, rect| {
            const r = for (all) |r| {
                if (refKey(face, r) == k) break r;
            } else unreachable;
            const b, _ = raster.render(face, r, &o, &acc, &cov);
            try std.testing.expectEqual(rect.w, b.w);
            var back: [64 * 64]u8 = undefined;
            for (0..rect.h) |row| @memcpy(back[row * rect.w ..][0..rect.w], c.atlas.pixels[(rect.y + row) * c.atlas.w + rect.x ..][0..rect.w]);
            const d = raster.compare(b, back[0 .. @as(usize, b.w) * b.h], r);
            try std.testing.expect(d.max <= 16);
        }
    }
    // The atlas filled up and was repacked more than once (measured: 5 times).
    try std.testing.expect(repacks >= 2);
}

fn refKey(face: opentype.Face, r: raster.Ref) u32 {
    return key(0, face.cmap.glyph(r.cp), r.px, r.offset / 16);
}

test "evict keeps recent rows in order; repack moves pixels" {
    var pixels: [16 * 16]u8 = undefined;
    var scratch: [16 * 16]u8 = undefined;
    var sky: TestSky(16) = .{};
    var keys: [simd.rows(4)]u32 = @splat(0);
    var rects: [simd.rows(4)]Atlas.Rect = undefined;
    var used: [simd.rows(4)]u32 = undefined;
    var c: Cache = .init(.init(16, 16, &pixels, sky.sky()), .{ .key = &keys, .rect = &rects, .used = &used });
    const a = c.insert(10, 3, 3, 1);
    const b = c.insert(11, 4, 2, 2);
    const d = c.insert(12, 2, 5, 3);
    const sevens: [10]u8 = @splat(7);
    c.atlas.put(c.rows.rect[d], &sevens);
    try std.testing.expectEqual(.{ 0, 1, 2 }, .{ a, b, d });
    try std.testing.expectEqual(1, c.find(11));
    c.evict(2);
    try std.testing.expectEqual(none, c.find(10));
    try std.testing.expectEqual(0, c.find(11));
    try std.testing.expectEqual(1, c.find(12));
    try std.testing.expectEqual(0, c.repack(&scratch));
    // Tallest first: key 12 now sits at the origin, with its pixels.
    const r = c.rows.rect[c.find(12)];
    try std.testing.expectEqual(Atlas.Rect{ .x = 0, .y = 0, .w = 2, .h = 5 }, r);
    try std.testing.expectEqual(7, c.atlas.pixels[4 * 16 + 1]);
    try std.testing.expectEqual(0, c.atlas.pixels[5 * 16 + 1]);
    try std.testing.expectEqual(key(1, 2, 3, 1), (1 << 26) | (1 << 24) | (3 << 16) | 2);
}

/// What a host does with an `Upload`: copies the region into its texture, here a CPU array.
fn upload(texture: []u8, a: *const Atlas, u: Atlas.Upload) usize {
    for (0..u.h) |row| {
        const at = u.offset + row * u.bytes_per_row;
        @memcpy(texture[at..][0..u.w], a.pixels[at..][0..u.w]);
    }
    return @as(usize, u.w) * u.h;
}

test "uploading dirty regions only keeps the texture equal to the atlas" {
    // The frames of "glyph images survive eviction and repacking", with a texture the host
    // updates from takeDirty alone. After every frame the texture equals the atlas, and every
    // glyph read from the texture matches FreeType's image.
    const face = try opentype.Face.parse(raster.test_font, 0);
    var cols: raster.TestOutline = .{};
    var o = cols.outline();
    var acc: [64 * 64]f32 = undefined;
    var cov: [64 * 64]u8 = undefined;
    var pixels: [256 * 128]u8 = undefined;
    var scratch: [256 * 128]u8 = undefined;
    var texture: [256 * 128]u8 = @splat(0xaa); // whatever the GPU memory held
    var sky: TestSky(256) = .{};
    const n = 64;
    var keys: [simd.rows(n)]u32 = @splat(0);
    var rects: [simd.rows(n)]Atlas.Rect = undefined;
    var used: [simd.rows(n)]u32 = undefined;
    var c: Cache = .init(.init(256, 128, &pixels, sky.sky()), .{ .key = &keys, .rect = &rects, .used = &used });
    var uploaded: usize = 0;
    var frames: usize = 0;
    const it0: raster.RefIter = .{};
    const sizes = [_]u16{ 9, 13, 16, 24, 40, 9, 13, 16, 24, 40, 40, 40 };
    for (sizes, 1..) |px, frame| {
        var it = it0;
        var repacked = frame == 1; // a new atlas is uploaded whole once
        while (it.next()) |r| {
            if (r.px != px) continue;
            const b, const img = raster.render(face, r, &o, &acc, &cov);
            const before = c.len;
            const got = c.reserve(refKey(face, r), b.w, b.h, @intCast(frame), &scratch);
            try std.testing.expect(got.row != none);
            repacked = repacked or (got.fresh and c.len <= before);
            if (got.fresh) c.atlas.put(c.rows.rect[got.row], img);
        }
        const up = if (c.atlas.takeDirty()) |u| upload(&texture, &c.atlas, u) else 0;
        // A repack moves everything, so the whole texture goes up; otherwise only the region
        // the frame's new glyphs went to (measured: 6,630 to 13,770 of 32,768 bytes).
        if (repacked) try std.testing.expectEqual(pixels.len, up) else try std.testing.expect(up * 2 < pixels.len);
        uploaded += up;
        frames += 1;
        try std.testing.expectEqualSlices(u8, &pixels, &texture);
        for (c.rows.key[0..c.len], c.rows.rect[0..c.len]) |k, rect| {
            var all = it0;
            const r = while (all.next()) |r| {
                if (refKey(face, r) == k) break r;
            } else unreachable;
            const b, _ = raster.render(face, r, &o, &acc, &cov);
            var back: [64 * 64]u8 = undefined;
            for (0..rect.h) |row| @memcpy(back[row * rect.w ..][0..rect.w], texture[(rect.y + row) * c.atlas.w + rect.x ..][0..rect.w]);
            try std.testing.expect(raster.compare(b, back[0 .. @as(usize, b.w) * b.h], r).max <= 16);
        }
    }
    // The last two frames draw nothing new and upload nothing: 230,268 bytes over 12 frames,
    // against 393,216 for whole-texture uploads, in a run that repacks every other frame.
    try std.testing.expectEqual(null, c.atlas.takeDirty());
    try std.testing.expectEqual(230_268, uploaded);
    try std.testing.expectEqual(12, frames);
}

test "dirty bounds grow with each put and reset on take" {
    var pixels: [16 * 16]u8 = undefined;
    var sky: TestSky(16) = .{};
    var a: Atlas = .init(16, 16, &pixels, sky.sky());
    // A new atlas is dirty all over: the GPU texture starts undefined.
    try std.testing.expectEqual(Atlas.Upload{ .x = 0, .y = 0, .w = 16, .h = 16, .offset = 0, .bytes_per_row = 16 }, a.takeDirty().?);
    try std.testing.expectEqual(null, a.takeDirty());
    const img: [6]u8 = @splat(1);
    a.put(.{ .x = 3, .y = 2, .w = 3, .h = 2 }, &img);
    a.put(.{ .x = 8, .y = 5, .w = 2, .h = 3 }, &img);
    try std.testing.expectEqual(Atlas.Upload{ .x = 3, .y = 2, .w = 7, .h = 6, .offset = 2 * 16 + 3, .bytes_per_row = 16 }, a.takeDirty().?);
}
