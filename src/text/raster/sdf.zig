//! Signed-distance glyphs: optional, for text drawn at many sizes or transformed from one
//! image. Tier 0.
//!
//! Each pixel holds the distance from its centre to the nearest edge of the outline, signed
//! (inside positive), as a byte: 128 at the edge, 127 / `spread` levels per pixel, clamped at
//! `spread` pixels either way. A shader recovers coverage at any scale as
//! `clamp(distance * scale + 0.5, 0, 1)`, with the distance read through bilinear filtering;
//! `decode` is that rule on the CPU. Plain coverage (raster.zig) stays the default: it is
//! exact at the size it was made for, and a distance field rounds corners and thin stems.
//!
//! The image is the coverage box grown by `spread` on every side (`box`). Distances are to the
//! outline flattened as `raster.fill` flattens it (within 1/32 px of the curve); the sign comes
//! from the pixel's coverage (inside when at least half covered), so it agrees with the coverage
//! image exactly.

const std = @import("std");
const simd = @import("../../core/simd.zig");
const raster = @import("raster.zig");
const Outline = @import("../font/opentype.zig").Outline;

const W = simd.lanes;
const Box = raster.Box;

/// The distance image's box: the coverage box grown by `spread` pixels on each side.
pub fn box(o: *const Outline, scale: f32, dx: f32, spread: u32) Box {
    const b = raster.box(o, scale, dx);
    if (b.w == 0) return b;
    const s: i32 = @intCast(spread);
    return .{ .left = b.left - s, .top = b.top + s, .w = b.w + 2 * spread, .h = b.h + 2 * spread };
}

/// Writes the distance image of `o` for box `b` (`box(o, scale, dx, spread)`) into `out`
/// (`raster.imageLen(b)` bytes), using `acc` (`raster.accLen(b)` floats) for the coverage
/// that signs it and `segs` for the flattened edges. `segs` needs room for the edges padded
/// to whole vectors; `error.NoSpace` when it has not.
pub fn fill(o: *const Outline, scale: f32, dx: f32, spread: u32, b: Box, segs: *raster.Segments, acc: []f32, out: []u8) error{NoSpace}!void {
    std.debug.assert(spread > 0);
    raster.fill(o, scale, dx, b, acc);
    const n = @as(usize, b.w) * b.h;
    raster.coverage(acc, out, n);
    segs.len = 0;
    try raster.segments(o, scale, dx, b, segs);
    const padded = simd.padded(segs.len);
    if (padded > segs.x0.len) return error.NoSpace;
    // Padding rows: a point far away, never the nearest.
    for (segs.len..padded) |i| {
        segs.x0[i] = 1e9;
        segs.y0[i] = 1e9;
        segs.x1[i] = 1e9;
        segs.y1[i] = 1e9;
    }
    distances(segs, padded, b.w, b.h, out[0..n], 127 / @as(f32, @floatFromInt(spread)));
}

/// SIMD over the segments. For every pixel of the `w` x `h` image `img` (row-major), which
/// holds its coverage on entry: the signed distance from its centre to the nearest of the
/// first `n` segments (a whole number of vectors), as `128 + distance * levels`, clamped.
pub fn distances(segs: *const raster.Segments, n: usize, w: u32, h: u32, img: []u8, levels: f32) void {
    std.debug.assert(n % W == 0 and img.len >= @as(usize, w) * h);
    // Pixel centres are counted in floats: converting the u32 counters would widen them to
    // u64, whose conversion to f32 branches on the sign bit (census).
    var row: u32 = 0;
    var py: f32 = 0.5;
    while (row < h) : ({
        row += 1;
        py += 1;
    }) {
        var col: u32 = 0;
        var px: f32 = 0.5;
        while (col < w) : ({
            col += 1;
            px += 1;
        }) {
            var best = simd.f(std.math.inf(f32));
            var k: usize = 0;
            while (k < n) : (k += W) {
                const ax = simd.loadF(segs.x0, k);
                const ay = simd.loadF(segs.y0, k);
                const ex = simd.loadF(segs.x1, k) - ax;
                const ey = simd.loadF(segs.y1, k) - ay;
                const qx = simd.f(px) - ax;
                const qy = simd.f(py) - ay;
                const len2 = @max(ex * ex + ey * ey, simd.f(1e-12));
                const t = std.math.clamp((qx * ex + qy * ey) / len2, simd.f(0), simd.f(1));
                const rx = qx - ex * t;
                const ry = qy - ey * t;
                best = @min(best, rx * rx + ry * ry);
            }
            const d = @sqrt(@reduce(.Min, best));
            const at = @as(usize, row) * w + col;
            // Inside (coverage >= 128) is +1, outside -1, as arithmetic: the optimizer turned a
            // bit select here back into a jump.
            const sign: f32 = @floatFromInt(@as(i32, img[at] >> 7) * 2 - 1);
            const signed = d * sign;
            img[at] = @intFromFloat(std.math.clamp(128 + signed * levels + 0.5, 0, 255));
        }
    }
}

/// Coverage from a distance byte at the scale it was made for: the rule a shader applies.
pub fn decode(v: u8, spread: u32) u8 {
    const d = (@as(f32, @floatFromInt(v)) - 128) * @as(f32, @floatFromInt(spread)) / 127;
    return @intFromFloat(std.math.clamp(d + 0.5, 0, 1) * 255 + 0.5);
}

// ---------------------------------------------------------------------------------------------

const opentype = @import("../font/opentype.zig");

const TestSegs = struct {
    x0: [1024]f32 = undefined,
    y0: [1024]f32 = undefined,
    x1: [1024]f32 = undefined,
    y1: [1024]f32 = undefined,

    fn segs(t: *TestSegs) raster.Segments {
        return .{ .x0 = &t.x0, .y0 = &t.y0, .x1 = &t.x1, .y1 = &t.y1 };
    }
};

test "glyphs decoded from distance images match the references" {
    // Every image of testdata/ref.bin (160), as a distance image with a spread of 4 px, decoded
    // back to coverage at its own size and compared with FreeType's coverage.
    const spread = 4;
    const face = try opentype.Face.parse(raster.test_font, 0);
    var cols: raster.TestOutline = .{};
    var o = cols.outline();
    var ts: TestSegs = .{};
    var segs = ts.segs();
    var acc: [80 * 80]f32 = undefined;
    var img: [80 * 80]u8 = undefined;
    const sizes = [_]u16{ 9, 13, 16, 24, 40 };
    var sum: [sizes.len]u64 = @splat(0);
    var ink: [sizes.len]u64 = @splat(0);
    var worst: u32 = 0;
    var it: raster.RefIter = .{};
    while (it.next()) |r| {
        o.points = 0;
        o.contours = 0;
        try face.outline(face.cmap.glyph(r.cp), &o);
        const scale = @as(f32, @floatFromInt(r.px)) / @as(f32, @floatFromInt(face.units_per_em));
        const dx = @as(f32, @floatFromInt(r.offset)) / 64;
        const b = box(&o, scale, dx, spread);
        try fill(&o, scale, dx, spread, b, &segs, &acc, &img);
        const n = @as(usize, b.w) * b.h;
        for (img[0..n]) |*v| v.* = decode(v.*, spread);
        const d = raster.compare(b, img[0..n], r);
        const k = std.mem.indexOfScalar(u16, &sizes, r.px).?;
        sum[k] += d.sum;
        ink[k] += @as(u64, r.b.w) * r.b.h;
        worst = @max(worst, d.max);
    }
    // Mean difference per pixel of the reference box, in levels of 255 (measured: 7.96, 4.49,
    // 3.26, 2.24, 1.25 at 9, 13, 16, 24, 40 px): a distance field is a good image from about
    // 16 px up and a rough one below. The largest differences are at sharp corners, which a
    // distance field rounds off (measured: at most 101, at 9 px).
    const bound = [_]u64{ 9, 5, 4, 3, 2 };
    for (sum, ink, bound) |s_, i, m| try std.testing.expect(s_ < m * i);
    try std.testing.expect(worst <= 112);
}

test "distances around a square" {
    // A 4 x 4 px square at (2, 2)..(6, 6) in font units at scale 1, spread 2.
    var cols: raster.TestOutline = .{};
    var o = cols.outline();
    const xs = [_]f32{ 2, 2, 6, 6 };
    const ys = [_]f32{ 2, 6, 6, 2 };
    @memcpy(o.x[0..4], &xs);
    @memcpy(o.y[0..4], &ys);
    @memset(o.on[0..4], true);
    o.ends[0] = 3;
    o.points = 4;
    o.contours = 1;
    const b = box(&o, 1, 0, 2);
    try std.testing.expectEqual(Box{ .left = 0, .top = 8, .w = 8, .h = 8 }, b);
    var ts: TestSegs = .{};
    var segs = ts.segs();
    var acc: [80]f32 = undefined;
    var img: [80]u8 = undefined;
    try fill(&o, 1, 0, 2, b, &segs, &acc, &img);
    // Row 4 (centre y 4.5) from the left: centres 0.5 .. 7.5, the square spans x 2..6.
    // Distances -1.5, -0.5, 0.5, 1.5, 1.5, 0.5, -0.5, -1.5 at 63.5 levels per pixel.
    try std.testing.expectEqualSlices(u8, &.{ 33, 96, 160, 223, 223, 160, 96, 33 }, img[4 * 8 ..][0..8]);
    try std.testing.expectEqual(0, decode(33, 2));
    try std.testing.expectEqual(255, decode(223, 2));
    try std.testing.expectEqual(255, decode(160, 2));
    try std.testing.expectEqual(0, decode(96, 2));
}
