//! Glyph rasteriser: TrueType outlines to 8-bit coverage, by accumulated signed area. Tier 0.
//!
//! Three steps the caller sequences, over memory the caller owns:
//!
//! 1. `box`: the pixel box of the outline at a scale. The caller sizes two buffers from it:
//!    `accLen(b)` floats of accumulation and `imageLen(b)` coverage bytes (`b.w * b.h` pixels,
//!    row by row, padded to whole vectors).
//! 2. `fill`: every edge of the outline adds its signed area to the accumulation buffer, cell by
//!    cell. Curves are flattened into lines first.
//! 3. `coverage`: a running sum over the buffer turns the area deltas into coverage, |sum| clamped
//!    to 1, written as bytes. This is the per-pixel loop, and it is SIMD: a prefix sum inside
//!    each vector plus a carried total.
//!
//! The method is the one of font-rs (Raph Levien, "Inside the fastest font renderer in the
//! world", 2016) and of FreeType's smooth rasteriser: each edge writes, into the cells it crosses
//! in each pixel row, the change in covered area from one cell to the next, so that a prefix sum
//! along the row gives the area covered left of every pixel. The buffer is summed as one long
//! row: an edge that reaches the right border writes its last delta into the first cell of the
//! next row, which cancels the row's carried sum there (each row of a closed outline sums to 0).
//!
//! The result is linear coverage, nonzero winding, with the abs taken so either contour
//! direction works. Images match FreeType's (testdata/make.py) to within a few levels.
//!
//! Subpixel positioning: `box` and `fill` take a horizontal shift `dx`, so one glyph has an image
//! per quarter pixel (`pen`, `shift`). A run places the image of the bin its pen x rounds to at
//! the pen's whole pixel, and keeps its spacing to a quarter pixel instead of a whole one.
//!
//! Output is the atlas contract of `fonts.Mono.quads` in prototype/ui.zig: a glyph is a
//! rectangle of coverage placed at the pen position plus (`left`, -`top`), y down.

const std = @import("std");
const opentype = @import("../font/opentype.zig");
const Outline = opentype.Outline;
const simd = @import("../../core/simd.zig");

const W = simd.lanes;

/// Pixel box of a glyph image. `left` is the column of its first pixel relative to the pen,
/// `top` the number of rows above the baseline (FreeType's bitmap_left and bitmap_top).
pub const Box = struct {
    left: i32 = 0,
    top: i32 = 0,
    w: u32 = 0,
    h: u32 = 0,
};

/// Floats of accumulation buffer `fill` needs for `b`: one cell per pixel, the two cells an
/// edge on the last row's right border writes past the end, padded to whole vectors for
/// `coverage`.
pub fn accLen(b: Box) usize {
    return simd.padded(@as(usize, b.w) * b.h + 2);
}

/// Bytes of coverage image `coverage` writes for `b`: `b.w * b.h` padded to whole vectors.
pub fn imageLen(b: Box) usize {
    return simd.padded(@as(usize, b.w) * b.h);
}

/// Horizontal subpixel positions a glyph is rasterised at: a quarter pixel apart. Four images
/// per glyph is where the eye stops seeing the steps in spacing (FreeType's and Skia's choice).
pub const subpixel_bins = 4;

/// A pen x split for rasterising: the whole pixel the glyph's box is placed from, and the
/// subpixel bin (0 to `subpixel_bins - 1`) whose image is drawn there. The pen rounds to the
/// nearest bin. `shift(bin)` is the `dx` to rasterise that bin's image with.
pub const Pen = struct { pixel: i32, bin: u32 };

pub fn pen(x: f32) Pen {
    const q: i32 = @intFromFloat(@round(x * subpixel_bins));
    return .{ .pixel = @divFloor(q, subpixel_bins), .bin = @intCast(@mod(q, subpixel_bins)) };
}

/// The rasterising shift of subpixel `bin`, in pixels.
pub fn shift(bin: u32) f32 {
    return @as(f32, @floatFromInt(bin)) / subpixel_bins;
}

/// The pixel box covering every point of `o` at `scale` pixels per font unit, shifted right by
/// `dx` pixels. Control points bound a quadratic curve, so the box bounds the outline.
pub fn box(o: *const Outline, scale: f32, dx: f32) Box {
    if (o.points == 0) return .{};
    var lo: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
    var hi: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };
    for (o.x[0..o.points], o.y[0..o.points]) |x, y| {
        lo = .{ @min(lo[0], x), @min(lo[1], y) };
        hi = .{ @max(hi[0], x), @max(hi[1], y) };
    }
    const x0 = @floor(lo[0] * scale + dx);
    const x1 = @ceil(hi[0] * scale + dx);
    const y0 = @floor(lo[1] * scale);
    const y1 = @ceil(hi[1] * scale);
    return .{ .left = @intFromFloat(x0), .top = @intFromFloat(y1), .w = @intFromFloat(x1 - x0), .h = @intFromFloat(y1 - y0) };
}

/// Accumulates the signed area of every contour of `o` (scaled by `scale`, shifted right by `dx`
/// pixels) into `acc`, which it zeroes first. `b` is `box(o, scale, dx)`; `acc` holds
/// `accLen(b)` floats.
pub fn fill(o: *const Outline, scale: f32, dx: f32, b: Box, acc: []f32) void {
    std.debug.assert(acc.len >= accLen(b));
    @memset(acc[0..accLen(b)], 0);
    const g: Grid = .{
        .acc = acc,
        .w = b.w,
        .h = b.h,
        .scale = scale,
        .ox = dx - @as(f32, @floatFromInt(b.left)),
        .oy = @floatFromInt(b.top),
    };
    var start: usize = 0;
    for (o.ends[0..o.contours]) |end| {
        g.contour(o, start, end + 1);
        start = end + 1;
    }
}

/// SIMD. Coverage bytes of the image: the running sum of `acc`, |sum| clamped to 1, times 255,
/// rounded. Writes `padded(n)` bytes for an `n`-pixel image; `acc` and `out` hold at least
/// that many (`accLen` and `imageLen` size them). Each vector is prefix-summed in registers
/// (log2(lanes) shift-and-add steps) and the running total is carried in from the last lane.
pub fn coverage(acc: []const f32, out: []u8, n: usize) void {
    const end = simd.padded(n);
    std.debug.assert(acc.len >= end and out.len >= end);
    var carry: simd.F = @splat(0);
    var i: usize = 0;
    while (i < end) : (i += W) {
        const sum = prefix(simd.loadF(acc, i)) + carry;
        carry = @splat(sum[W - 1]);
        const c = @min(@abs(sum), simd.f(1)) * simd.f(255) + simd.f(0.5);
        out[i..][0..W].* = @as(simd.Bytes, @intFromFloat(c));
    }
}

/// Inclusive prefix sum across the lanes of `v`.
inline fn prefix(v: simd.F) simd.F {
    const zero: simd.F = @splat(0);
    var s = v;
    comptime var k = 1;
    inline while (k < W) : (k *= 2) {
        s += @shuffle(f32, s, zero, shiftMask(k));
    }
    return s;
}

/// Shuffle mask moving lane i - k to lane i, zero (lane 0 of the second operand) below k.
fn shiftMask(k: comptime_int) @Vector(W, i32) {
    var m: [W]i32 = undefined;
    for (&m, 0..) |*e, i| e.* = if (i >= k) @intCast(i - k) else -1;
    return m;
}

/// The accumulation buffer and the transform from font units to its pixels (x right, y down).
const Grid = struct {
    acc: []f32,
    w: u32,
    h: u32,
    scale: f32,
    ox: f32,
    oy: f32,

    const P = [2]f32;

    fn at(g: Grid, o: *const Outline, i: usize) P {
        return .{ o.x[i] * g.scale + g.ox, g.oy - o.y[i] * g.scale };
    }

    /// Points `first..last` of `o` as one closed contour. Two off-curve points in a row imply an
    /// on-curve point midway; a contour may start off-curve (TrueType).
    fn contour(g: Grid, o: *const Outline, first: usize, last: usize) void {
        if (last - first < 2) return;
        // The walk starts at an on-curve point: the first, else the last, else the midpoint of
        // the two (both off-curve).
        const start: P, const skip_first: bool, const skip_last: bool = if (o.on[first])
            .{ g.at(o, first), true, false }
        else if (o.on[last - 1])
            .{ g.at(o, last - 1), false, true }
        else
            .{ mid(g.at(o, first), g.at(o, last - 1)), false, false };
        var cur = start;
        var ctrl: ?P = null;
        const from = first + @intFromBool(skip_first);
        const to = last - @intFromBool(skip_last);
        for (from..to) |i| {
            const p = g.at(o, i);
            if (o.on[i]) {
                if (ctrl) |c| g.quad(cur, c, p) else g.line(cur, p);
                cur = p;
                ctrl = null;
            } else {
                if (ctrl) |c| {
                    const m = mid(c, p);
                    g.quad(cur, c, m);
                    cur = m;
                }
                ctrl = p;
            }
        }
        if (ctrl) |c| g.quad(cur, c, start) else g.line(cur, start);
    }

    fn mid(a: P, b: P) P {
        return .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
    }

    /// A quadratic Bézier flattened into lines. With dev = p0 - 2 p1 + p2, a chord of n equal
    /// steps in t is at most |dev| / (4 n^2) from the curve, so n = sqrt(8 |dev|) keeps every
    /// line within 1/32 px of it. (font-rs's n = (3 |dev|^2)^(1/4) allowed about 1/8 px, which
    /// shifted curved edges by up to 32 levels of 255 against FreeType.)
    fn quad(g: Grid, p0: P, p1: P, p2: P) void {
        const dev = .{ p0[0] - 2 * p1[0] + p2[0], p0[1] - 2 * p1[1] + p2[1] };
        const dd = dev[0] * dev[0] + dev[1] * dev[1];
        const n: u32 = 1 + @as(u32, @intFromFloat(@min(@floor(@sqrt(@sqrt(dd) * 8)), 255)));
        const step = 1 / @as(f32, @floatFromInt(n));
        var prev = p0;
        for (1..n + 1) |k| {
            const t = @as(f32, @floatFromInt(k)) * step;
            const s = 1 - t;
            const p: P = .{
                s * s * p0[0] + 2 * s * t * p1[0] + t * t * p2[0],
                s * s * p0[1] + 2 * s * t * p1[1] + t * t * p2[1],
            };
            g.line(prev, p);
            prev = p;
        }
    }

    /// Adds the signed area of the edge `p0`-`p1` to every row it crosses.
    fn line(g: Grid, p0: P, p1: P) void {
        if (p0[1] == p1[1]) return; // a horizontal edge covers no area
        const down = p0[1] < p1[1];
        const dir: f32 = if (down) 1 else -1;
        const a = if (down) p0 else p1;
        const b = if (down) p1 else p0;
        const dxdy = (b[0] - a[0]) / (b[1] - a[1]);
        const w: f32 = @floatFromInt(g.w);
        const row_end: usize = @intFromFloat(@min(@ceil(b[1]), @as(f32, @floatFromInt(g.h))));
        var row: usize = @intFromFloat(@max(@floor(a[1]), 0));
        while (row < row_end) : (row += 1) {
            const rf: f32 = @floatFromInt(row);
            const y0 = @max(rf, a[1]);
            const y1 = @min(rf + 1, b[1]);
            const xa = a[0] + (y0 - a[1]) * dxdy;
            const xb = a[0] + (y1 - a[1]) * dxdy;
            const lo = std.math.clamp(@min(xa, xb), 0, w);
            const hi = std.math.clamp(@max(xa, xb), 0, w);
            cells(g.acc[row * g.w ..], lo, hi, (y1 - y0) * dir);
        }
    }

    /// One row of an edge that runs from x `lo` to `hi` and covers `d` of the row's height
    /// (signed by direction). Cell c gets the change in the fraction of the edge's area that
    /// lies left of c's right side: cov(c) - cov(c - 1), where cov(c) is the mean over the edge
    /// of clamp(c + 1 - x, 0, 1). For an edge spanning more than a sliver, x is uniform on
    /// [lo, hi] and the mean has the closed form below; for a near-vertical one, the mean is the
    /// value at the midpoint (the closed form would divide by almost zero).
    fn cells(row: []f32, lo: f32, hi: f32, d: f32) void {
        const span = hi - lo;
        const thin = span < 1e-3;
        const inv = 1 / @max(span, 1e-3);
        const m = (lo + hi) * 0.5;
        const c0: usize = @intFromFloat(@floor(lo));
        const c1: usize = @as(usize, @intFromFloat(@floor(hi))) + 1;
        var prev: f32 = 0;
        for (c0..c1 + 1) |c| {
            const cf: f32 = @floatFromInt(c);
            const ramp = (half2(cf + 1 - lo) - half2(cf + 1 - hi) - half2(cf - lo) + half2(cf - hi)) * inv;
            const step = std.math.clamp(cf + 1 - m, 0, 1);
            const cov = if (thin) step else ramp;
            row[c] += d * (cov - prev);
            prev = cov;
        }
    }

    /// max(u, 0)^2 / 2: the integral of the ramp max(t, 0) from 0 to u.
    inline fn half2(u: f32) f32 {
        const p = @max(u, 0);
        return p * p * 0.5;
    }
};

// ---------------------------------------------------------------------------------------------
// Tests: every reference image of testdata/ref.bin (FreeType), rasterised here and compared.
// The helpers are pub for the tests of the other files of src/text/raster/.

pub const test_font = @embedFile("../font/testdata/test.ttf");
const font = test_font;
const refs = @embedFile("testdata/ref.bin");

/// One reference image of testdata/ref.bin.
pub const Ref = struct {
    cp: u32,
    px: u16,
    /// x shift in 1/64 px.
    offset: u16,
    b: Box,
    pixels: []const u8,
};

pub const RefIter = struct {
    at: usize = 4,
    left: u32 = std.mem.readInt(u32, refs[0..4], .little),

    pub fn next(it: *RefIter) ?Ref {
        if (it.left == 0) return null;
        it.left -= 1;
        const h = refs[it.at..][0..16];
        const w = std.mem.readInt(u16, h[12..14], .little);
        const rows = std.mem.readInt(u16, h[14..16], .little);
        const r: Ref = .{
            .cp = std.mem.readInt(u32, h[0..4], .little),
            .px = std.mem.readInt(u16, h[4..6], .little),
            .offset = std.mem.readInt(u16, h[6..8], .little),
            .b = .{
                .left = std.mem.readInt(i16, h[8..10], .little),
                .top = std.mem.readInt(i16, h[10..12], .little),
                .w = w,
                .h = rows,
            },
            .pixels = refs[it.at + 16 ..][0 .. @as(usize, w) * rows],
        };
        it.at += 16 + r.pixels.len;
        return r;
    }
};

/// Largest per-pixel difference, and the sum of differences, between `got` (box `gb`) and the
/// reference, over the union of both boxes (pixels outside a box are 0).
const Diff = struct { max: u32 = 0, sum: u64 = 0, pixels: u64 = 0 };

fn compare(gb: Box, got: []const u8, r: Ref) Diff {
    var d: Diff = .{};
    const x0 = @min(gb.left, r.b.left);
    const x1 = @max(gb.left + @as(i32, @intCast(gb.w)), r.b.left + @as(i32, @intCast(r.b.w)));
    const y0 = @max(gb.top, r.b.top);
    const y1 = @min(gb.top - @as(i32, @intCast(gb.h)), r.b.top - @as(i32, @intCast(r.b.h)));
    var y = y0;
    while (y > y1) : (y -= 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const a = pixel(gb, got, x, y);
            const b = pixel(r.b, r.pixels, x, y);
            const e: u32 = @abs(@as(i32, a) - b);
            d.max = @max(d.max, e);
            d.sum += e;
            d.pixels += 1;
        }
    }
    return d;
}

/// The pixel at column `x` (from the pen) and row `y` (rows above the baseline, the top row of
/// the image being `b.top`), 0 outside the box.
pub fn pixel(b: Box, px: []const u8, x: i32, y: i32) u8 {
    const c = x - b.left;
    const r = b.top - y;
    if (c < 0 or r < 0 or c >= b.w or r >= b.h) return 0;
    return px[@as(usize, @intCast(r)) * b.w + @as(usize, @intCast(c))];
}

/// Rasterises one reference glyph here, into the caller's buffers.
pub fn render(face: opentype.Face, r: Ref, o: *Outline, acc: []f32, out: []u8) struct { Box, []u8 } {
    o.points = 0;
    o.contours = 0;
    face.outline(face.cmap.glyph(r.cp), o) catch unreachable;
    const scale = @as(f32, @floatFromInt(r.px)) / @as(f32, @floatFromInt(face.units_per_em));
    const dx = @as(f32, @floatFromInt(r.offset)) / 64;
    const b = box(o, scale, dx);
    fill(o, scale, dx, b, acc);
    coverage(acc, out, @as(usize, b.w) * b.h);
    return .{ b, out[0 .. @as(usize, b.w) * b.h] };
}

/// Columns for one test glyph's outline.
pub const TestOutline = struct {
    x: [256]f32 = undefined,
    y: [256]f32 = undefined,
    on: [256]bool = undefined,
    ends: [32]u32 = undefined,

    pub fn outline(t: *TestOutline) Outline {
        return .{ .x = &t.x, .y = &t.y, .on = &t.on, .ends = &t.ends };
    }
};

test "glyph images match the FreeType references" {
    const face = try opentype.Face.parse(font, 0);
    var cols: TestOutline = .{};
    var o = cols.outline();
    var acc: [64 * 64]f32 = undefined;
    var out: [64 * 64]u8 = undefined;
    var it: RefIter = .{};
    var total: Diff = .{};
    var images: u32 = 0;
    while (it.next()) |r| {
        const b, const img = render(face, r, &o, &acc, &out);
        // FreeType takes the box from the control box too, but of points rounded to 1/64 px, so
        // an edge within 1/128 px of a pixel border can land on the other side.
        try std.testing.expect(@abs(r.b.left - b.left) <= 1 and @abs(r.b.top - b.top) <= 1);
        try std.testing.expect(@abs(@as(i32, @intCast(r.b.w)) - @as(i32, @intCast(b.w))) <= 1);
        try std.testing.expect(@abs(@as(i32, @intCast(r.b.h)) - @as(i32, @intCast(b.h))) <= 1);
        const d = compare(b, img, r);
        total.max = @max(total.max, d.max);
        total.sum += d.sum;
        total.pixels += d.pixels;
        images += 1;
    }
    // 8 glyphs, 5 sizes, 4 subpixel shifts.
    try std.testing.expectEqual(160, images);
    // FreeType rounds points to 1/64 px and flattens curves more coarsely: straight edges agree
    // to 3 levels of 255, curved ones to 14 (measured at shift 0: 4,613 levels over 8,037
    // pixels, a mean of 0.57; over all four shifts: max 14,
    // 18,596 over 32,489, again 0.57).
    try std.testing.expect(total.max <= 16);
    try std.testing.expect(total.sum < total.pixels);
}

test "an empty outline has an empty box" {
    var cols: TestOutline = .{};
    const o = cols.outline();
    try std.testing.expectEqual(Box{}, box(&o, 1, 0));
}

test "a square half a pixel off the grid" {
    // A 2x2 px square from (0.5, 0.5) to (2.5, 2.5), clockwise in y-up font units at scale 1.
    var cols: TestOutline = .{};
    var o = cols.outline();
    const xs = [_]f32{ 0.5, 0.5, 2.5, 2.5 };
    const ys = [_]f32{ 0.5, 2.5, 2.5, 0.5 };
    @memcpy(o.x[0..4], &xs);
    @memcpy(o.y[0..4], &ys);
    @memset(o.on[0..4], true);
    o.ends[0] = 3;
    o.points = 4;
    o.contours = 1;
    const b = box(&o, 1, 0);
    try std.testing.expectEqual(Box{ .left = 0, .top = 3, .w = 3, .h = 3 }, b);
    var acc: [32]f32 = undefined;
    var out: [32]u8 = undefined;
    fill(&o, 1, 0, b, &acc);
    coverage(&acc, &out, 9);
    // Corners a quarter covered, edges half, the centre fully.
    try std.testing.expectEqualSlices(u8, &.{ 64, 128, 64, 128, 255, 128, 64, 128, 64 }, out[0..9]);
}

/// The scalar running sum `coverage` vectorises: one add per pixel, in order.
fn coverageScalar(acc: []const f32, out: []u8) void {
    var sum: f32 = 0;
    for (acc[0..out.len], out) |a, *px| {
        sum += a;
        px.* = @intFromFloat(@min(@abs(sum), 1) * 255 + 0.5);
    }
}

test "SIMD coverage matches the scalar running sum" {
    const face = try opentype.Face.parse(font, 0);
    var cols: TestOutline = .{};
    var o = cols.outline();
    var acc: [64 * 64]f32 = undefined;
    var out: [64 * 64]u8 = undefined;
    var ref: [64 * 64]u8 = undefined;
    var it: RefIter = .{};
    while (it.next()) |r| {
        if (r.offset != 0) continue;
        _, const img = render(face, r, &o, &acc, &out);
        coverageScalar(&acc, ref[0..img.len]);
        // The sums run in a different order, so a pixel on a rounding boundary may differ by 1.
        for (img, ref[0..img.len]) |v, s| try std.testing.expect(@abs(@as(i32, v) - s) <= 1);
    }
}

test "pen positions split into a pixel and a quarter-pixel bin" {
    try std.testing.expectEqual(Pen{ .pixel = 2, .bin = 1 }, pen(2.3));
    try std.testing.expectEqual(Pen{ .pixel = 3, .bin = 0 }, pen(2.9));
    try std.testing.expectEqual(Pen{ .pixel = -1, .bin = 3 }, pen(-0.25));
    try std.testing.expectEqual(Pen{ .pixel = 0, .bin = 2 }, pen(0.5));
    try std.testing.expectEqual(@as(f32, 0.75), shift(3));
}

test "a subpixel shift moves the image, not just its box" {
    const face = try opentype.Face.parse(font, 0);
    var cols: TestOutline = .{};
    var o = cols.outline();
    o.points = 0;
    o.contours = 0;
    try face.outline(face.cmap.glyph('V'), &o);
    const scale = 16 / @as(f32, @floatFromInt(face.units_per_em));
    var acc: [2][64 * 64]f32 = undefined;
    var img: [2][64 * 64]u8 = undefined;
    var boxes: [2]Box = undefined;
    for (0..2) |k| {
        boxes[k] = box(&o, scale, shift(@intCast(k * 2)));
        fill(&o, scale, shift(@intCast(k * 2)), boxes[k], &acc[k]);
        coverage(&acc[k], &img[k], @as(usize, boxes[k].w) * boxes[k].h);
    }
    // Half a pixel to the right: the ink moves by half a pixel, so its centre of mass does.
    var mass: [2]f64 = .{ 0, 0 };
    var ink: [2]f64 = .{ 0, 0 };
    for (0..2) |k| {
        for (0..@as(usize, boxes[k].w) * boxes[k].h) |i| {
            const x: f64 = @floatFromInt(@as(i32, @intCast(i % boxes[k].w)) + boxes[k].left);
            mass[k] += (x + 0.5) * @as(f64, @floatFromInt(img[k][i]));
            ink[k] += @floatFromInt(img[k][i]);
        }
    }
    try std.testing.expectApproxEqAbs(0.5, mass[1] / ink[1] - mass[0] / ink[0], 0.02);
}
