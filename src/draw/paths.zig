//! Vector paths: a builder, a flattener and a coverage rasteriser. Tier 0: every step writes
//! into columns the caller owns, and the caller sequences them:
//!
//! 1. `Path`: verbs (move, line, quadratic, cubic, close) and the points they consume.
//! 2. `flatten`: the path as polylines, curves cut into chords.
//! 3. `bounds`, `fill`, `coverage`: the pixel box of the polylines, then their 8-bit coverage
//!    under a fill rule, into a `w * h` image the caller places (an atlas, a canvas).
//!
//! Coverage is exact along x and sampled along y: each pixel row is cut into `sub_rows` lines,
//! each line's spans are found from its edge crossings under the fill rule, and the exact length
//! of every span inside every pixel is added. Crossings make both rules exact, which the signed
//! area of src/text/raster/raster.zig cannot do for even-odd (TinyVG fills even-odd, strokes are
//! a union of overlapping pieces). The spans go into the same accumulation buffer as the glyph
//! rasteriser's, as deltas whose running sum is the coverage, so `coverage` is its SIMD prefix
//! sum.
//!
//! Coordinates are logical pixels, x right and y down.

const std = @import("std");
const simd = @import("../core/simd.zig");
const raster = @import("../text/raster/raster.zig");

/// What one path step does, and how many points it consumes from `Path.x` / `Path.y`.
pub const Verb = enum(u8) {
    /// Starts a contour at 1 point.
    move,
    /// A line to 1 point.
    line,
    /// A quadratic Bezier: control point, end point.
    quad,
    /// A cubic Bezier: two control points, end point.
    cubic,
    /// A line back to the contour's first point; consumes none.
    close,
};

/// A path as two column sets the caller owns: `verb[0..verbs]` and the points they consume,
/// `x[0..points]`, `y[0..points]`. The slice lengths are the capacity; going past it is a
/// programmer error (asserted). A drawing verb after `close` continues from the closed
/// contour's first point, as in SVG.
pub const Path = struct {
    verb: []Verb,
    x: []f32,
    y: []f32,
    verbs: u32 = 0,
    points: u32 = 0,

    pub fn init(verb: []Verb, x: []f32, y: []f32) Path {
        std.debug.assert(x.len == y.len);
        return .{ .verb = verb, .x = x, .y = y };
    }

    pub fn moveTo(p: *Path, x: f32, y: f32) void {
        p.add(.move, &.{ x, y });
    }

    pub fn lineTo(p: *Path, x: f32, y: f32) void {
        p.add(.line, &.{ x, y });
    }

    pub fn quadTo(p: *Path, cx: f32, cy: f32, x: f32, y: f32) void {
        p.add(.quad, &.{ cx, cy, x, y });
    }

    pub fn cubicTo(p: *Path, c0x: f32, c0y: f32, c1x: f32, c1y: f32, x: f32, y: f32) void {
        p.add(.cubic, &.{ c0x, c0y, c1x, c1y, x, y });
    }

    pub fn close(p: *Path) void {
        p.add(.close, &.{});
    }

    /// Empties the path, keeping its columns.
    pub fn clear(p: *Path) void {
        p.verbs = 0;
        p.points = 0;
    }

    /// `xy` is x, y pairs.
    fn add(p: *Path, v: Verb, xy: []const f32) void {
        std.debug.assert(p.verbs < p.verb.len and p.points + xy.len / 2 <= p.x.len);
        p.verb[p.verbs] = v;
        p.verbs += 1;
        for (0..xy.len / 2) |k| {
            p.x[p.points] = xy[2 * k];
            p.y[p.points] = xy[2 * k + 1];
            p.points += 1;
        }
    }
};

/// Polylines as columns the caller owns: points `x[0..points]`, `y[0..points]`, and per contour
/// the index one past its last point (`end`) and whether it was closed. Contour `c` runs from
/// `end[c - 1]` (0 for the first) to `end[c]`. The point columns need `lanes` rows of slack past
/// the last point, because curves are written a whole vector at a time (`flattenLen`).
pub const Polyline = struct {
    x: []f32,
    y: []f32,
    end: []u32,
    closed: []bool,
    points: u32 = 0,
    contours: u32 = 0,
};

/// Chords per curve. ponytail: a fixed count; flattening to a tolerance replaces it.
const curve_steps = 64;

/// Rows `flatten` needs for `p`: an upper bound on the points (plus the vector slack) and the
/// contours.
pub fn flattenLen(p: *const Path) struct { points: usize, contours: usize } {
    var points: usize = simd.lanes;
    var contours: usize = 0;
    for (p.verb[0..p.verbs]) |v| {
        // A drawing verb after a close opens a contour of its own and repeats its first point.
        points += switch (v) {
            .move => 1,
            .line => 2,
            .quad, .cubic => curve_steps + 1,
            .close => 0,
        };
        contours += @intFromBool(v != .close);
    }
    return .{ .points = points, .contours = contours };
}

/// The polylines of `p`, curves cut into chords, into `out` (emptied first; sized by
/// `flattenLen`). A point equal to the one before it is dropped, so no chord has zero length,
/// and a closed contour does not repeat its first point at the end.
pub fn flatten(p: *const Path, out: *Polyline) void {
    out.points = 0;
    out.contours = 0;
    var f: Flattener = .{ .out = out };
    var at: usize = 0;
    for (p.verb[0..p.verbs]) |v| {
        const px = p.x[at..];
        const py = p.y[at..];
        switch (v) {
            .move => {
                f.finish(false);
                f.start(px[0], py[0]);
            },
            .line => {
                f.reopen();
                f.push(px[0], py[0]);
            },
            .quad => {
                f.reopen();
                f.curve(.{ f.cx, f.cy, px[0], py[0], px[0], py[0], px[1], py[1] }, true);
            },
            .cubic => {
                f.reopen();
                f.curve(.{ f.cx, f.cy, px[0], py[0], px[1], py[1], px[2], py[2] }, false);
            },
            .close => f.finish(true),
        }
        at += switch (v) {
            .move, .line => 1,
            .quad => 2,
            .cubic => 3,
            .close => 0,
        };
    }
    f.finish(false);
}

const Flattener = struct {
    out: *Polyline,
    /// First point of the open contour, in `out`.
    first: u32 = 0,
    open: bool = false,
    /// The pen: the last point written, or the start of the last closed contour.
    cx: f32 = 0,
    cy: f32 = 0,
    sx: f32 = 0,
    sy: f32 = 0,

    fn start(f: *Flattener, x: f32, y: f32) void {
        f.first = f.out.points;
        f.open = true;
        f.sx = x;
        f.sy = y;
        f.cx = x;
        f.cy = y;
        f.out.x[f.out.points] = x;
        f.out.y[f.out.points] = y;
        f.out.points += 1;
    }

    /// A drawing verb with no open contour starts one at the last start point.
    fn reopen(f: *Flattener) void {
        if (!f.open) f.start(f.sx, f.sy);
    }

    /// Writes always; advances unless the point repeats the last one.
    fn push(f: *Flattener, x: f32, y: f32) void {
        const o = f.out;
        o.x[o.points] = x;
        o.y[o.points] = y;
        o.points += @intFromBool(x != f.cx or y != f.cy);
        f.cx = x;
        f.cy = y;
    }

    /// Ends the open contour, if any. A closed contour drops a last point equal to its first.
    fn finish(f: *Flattener, closed: bool) void {
        if (!f.open) return;
        const o = f.out;
        const last = o.points - 1;
        const repeats = closed and last > f.first and o.x[last] == o.x[f.first] and o.y[last] == o.y[f.first];
        o.points -= @intFromBool(repeats);
        o.end[o.contours] = o.points;
        o.closed[o.contours] = closed;
        o.contours += 1;
        f.open = false;
        f.cx = f.sx;
        f.cy = f.sy;
    }

    /// A cubic Bezier (a quadratic one is passed as a cubic whose two controls are its one:
    /// `quadratic` evaluates it as a quadratic), cut into `n` chords of equal steps in t. The
    /// inner points are evaluated a vector of t values at a time and written whole, the count
    /// advancing by the ones that are real; the end point goes through `push`.
    fn curve(f: *Flattener, c: [8]f32, quadratic: bool) void {
        const n: u32 = curve_steps;
        const o = f.out;
        const F = simd.F;
        const inv: F = @splat(1 / @as(f32, @floatFromInt(n)));
        var k: u32 = 1;
        while (k < n) : (k += simd.lanes) {
            const t = @as(F, @floatFromInt(simd.iota + simd.u(k))) * inv;
            const s = simd.f(1) - t;
            // Quadratic: s^2 p0 + 2 s t p1 + t^2 p2. Cubic: s^3 p0 + 3 s^2 t p1 + 3 s t^2 p2 + t^3 p3.
            const b0 = if (quadratic) s * s else s * s * s;
            const b1 = if (quadratic) simd.f(2) * s * t else simd.f(3) * s * s * t;
            const b2 = if (quadratic) simd.f(0) else simd.f(3) * s * t * t;
            const b3 = if (quadratic) t * t else t * t * t;
            const x = b0 * simd.f(c[0]) + b1 * simd.f(c[2]) + b2 * simd.f(c[4]) + b3 * simd.f(c[6]);
            const y = b0 * simd.f(c[1]) + b1 * simd.f(c[3]) + b2 * simd.f(c[5]) + b3 * simd.f(c[7]);
            o.x[o.points..][0..simd.lanes].* = x;
            o.y[o.points..][0..simd.lanes].* = y;
            o.points += @min(simd.lanes, n - k);
        }
        f.cx = o.x[o.points - 1];
        f.cy = o.y[o.points - 1];
        f.push(c[6], c[7]);
    }
};

/// The pixel rectangle an image covers: column `x`, row `y` of its top-left pixel, and its size.
pub const Box = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: u32 = 0,
    h: u32 = 0,
};

/// The pixel box covering every point of `l`; empty for no points.
pub fn bounds(l: *const Polyline) Box {
    if (l.points == 0) return .{};
    var lo: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
    var hi: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };
    for (l.x[0..l.points], l.y[0..l.points]) |x, y| {
        lo = .{ @min(lo[0], x), @min(lo[1], y) };
        hi = .{ @max(hi[0], x), @max(hi[1], y) };
    }
    const x0 = @floor(lo[0]);
    const y0 = @floor(lo[1]);
    return .{
        .x = @intFromFloat(x0),
        .y = @intFromFloat(y0),
        .w = @intFromFloat(@ceil(hi[0]) - x0),
        .h = @intFromFloat(@ceil(hi[1]) - y0),
    };
}

/// Which spans are inside: the winding number of a point, masked; inside when nonzero. The
/// masks make the rule a coefficient instead of a branch.
pub const Rule = enum(u32) {
    nonzero = 0xffff_ffff,
    even_odd = 1,
};

/// Sample lines per pixel row. Coverage is exact along x; along y a pixel edge is placed to
/// 1/32 px. ponytail: fixed; a caller-chosen count if a size needs better or faster.
pub const sub_rows = 16;

/// Floats of accumulation buffer `fill` needs for `b`, as for the glyph rasteriser: a cell per
/// pixel, two past the end for spans that reach the right border of the last row, padded.
pub fn accLen(b: Box) usize {
    return simd.padded(@as(usize, b.w) * b.h + 2);
}

/// Bytes of coverage image `coverage` writes for `b`.
pub fn imageLen(b: Box) usize {
    return simd.padded(@as(usize, b.w) * b.h);
}

/// Per-edge and per-crossing scratch for `fill`: one row per polyline point.
pub const Scratch = struct {
    x0: []f32,
    y0: []f32,
    y1: []f32,
    dxdy: []f32,
    cross_x: []f32,
    cross_d: []i32,
};

/// Spans of every contour of `l` (each one closed, whether or not it was) inside box `b` under
/// `rule`, accumulated into `acc` (zeroed first; `accLen(b)` floats) as coverage deltas for
/// `coverage`. `scratch` columns hold `l.points` rows.
///
/// ponytail: every sample line tests every edge, O(rows * sub_rows * edges); an active-edge list
/// when paths get large.
pub fn fill(l: *const Polyline, b: Box, rule: Rule, scratch: Scratch, acc: []f32) void {
    std.debug.assert(acc.len >= accLen(b));
    @memset(acc[0..accLen(b)], 0);
    const bx: f32 = @floatFromInt(b.x);
    const by: f32 = @floatFromInt(b.y);
    // Edges in box space: point i to the next point of its contour, the last to the first.
    var first: usize = 0;
    for (l.end[0..l.contours]) |end| {
        for (first..end) |i| {
            const j = if (i + 1 == end) first else i + 1;
            const x0 = l.x[i] - bx;
            const y0 = l.y[i] - by;
            const y1 = l.y[j] - by;
            scratch.x0[i] = x0;
            scratch.y0[i] = y0;
            scratch.y1[i] = y1;
            // Infinite for a horizontal edge, which never crosses a sample line.
            scratch.dxdy[i] = (l.x[j] - bx - x0) / (y1 - y0);
        }
        first = end;
    }
    const edges = l.points;
    const mask: i32 = @bitCast(@backingInt(rule));
    const w: f32 = @floatFromInt(b.w);
    const step = 1 / @as(f32, sub_rows);
    for (0..b.h) |row| {
        const cells = acc[row * b.w ..];
        for (0..sub_rows) |s| {
            const ys = @as(f32, @floatFromInt(row)) + (@as(f32, @floatFromInt(s)) + 0.5) * step;
            // Crossings of this line: written always, kept when the edge spans it.
            var n: usize = 0;
            for (0..edges) |e| {
                const y0 = scratch.y0[e];
                const y1 = scratch.y1[e];
                scratch.cross_x[n] = scratch.x0[e] + (ys - y0) * scratch.dxdy[e];
                scratch.cross_d[n] = @as(i32, @intFromBool(y1 > y0)) * 2 - 1;
                n += @intFromBool((y0 <= ys) != (y1 <= ys));
            }
            sortCrossings(scratch.cross_x[0..n], scratch.cross_d[0..n]);
            // Walk left to right; where inside-ness changes, a span opens or closes. Its edge
            // adds +-1/sub_rows split between the cell it falls in and the next, by position.
            var wind: i32 = 0;
            var was: f32 = 0;
            for (scratch.cross_x[0..n], scratch.cross_d[0..n]) |cx, cd| {
                wind += cd;
                const in = simd.b2f((wind & mask) != 0);
                const d = (in - was) * step;
                was = in;
                const x = std.math.clamp(cx, 0, w);
                const c = @floor(x);
                const frac = x - c;
                const ci: usize = @intFromFloat(c);
                cells[ci] += d * (1 - frac);
                cells[ci + 1] += d * frac;
            }
        }
    }
}

/// Insertion sort of crossings by x, the winding direction moving with its x. A sample line
/// crosses few edges, and they come nearly sorted from one line to the next. This is the one
/// data-dependent branch of `fill`: span order is the data.
fn sortCrossings(xs: []f32, ds: []i32) void {
    if (xs.len < 2) return;
    for (1..xs.len) |i| {
        const x = xs[i];
        const d = ds[i];
        var j = i;
        while (j > 0 and xs[j - 1] > x) : (j -= 1) {
            xs[j] = xs[j - 1];
            ds[j] = ds[j - 1];
        }
        xs[j] = x;
        ds[j] = d;
    }
}

/// SIMD. Coverage bytes from `fill`'s buffer for an `n`-pixel image: the glyph rasteriser's
/// prefix sum, |sum| clamped to 1, times 255.
pub const coverage = raster.coverage;

/// Columns for a test path, its polylines and the fill scratch.
pub fn TestBuffers(comptime verbs: usize, comptime points: usize) type {
    return struct {
        verb: [verbs]Verb = undefined,
        px: [points]f32 = undefined,
        py: [points]f32 = undefined,
        lx: [points]f32 = undefined,
        ly: [points]f32 = undefined,
        end: [verbs]u32 = undefined,
        closed: [verbs]bool = undefined,
        s: [5][points]f32 = undefined,
        cd: [points]i32 = undefined,

        pub fn path(t: *@This()) Path {
            return .init(&t.verb, &t.px, &t.py);
        }
        pub fn polyline(t: *@This()) Polyline {
            return .{ .x = &t.lx, .y = &t.ly, .end = &t.end, .closed = &t.closed };
        }
        pub fn scratch(t: *@This()) Scratch {
            return .{ .x0 = &t.s[0], .y0 = &t.s[1], .y1 = &t.s[2], .dxdy = &t.s[3], .cross_x = &t.s[4], .cross_d = &t.cd };
        }
    };
}

const testing = std.testing;

/// Renders `l` under `rule` and returns the image and its box.
fn testRender(l: *const Polyline, rule: Rule, s: Scratch, acc: []f32, img: []u8) struct { Box, []u8 } {
    const b = bounds(l);
    fill(l, b, rule, s, acc);
    coverage(acc, img, @as(usize, b.w) * b.h);
    return .{ b, img[0 .. @as(usize, b.w) * b.h] };
}

test "builder: verbs consume their points; flatten keeps lines and cuts curves" {
    var t: TestBuffers(8, 256) = .{};
    var p = t.path();
    p.moveTo(1, 1);
    p.lineTo(5, 1);
    p.quadTo(5, 5, 1, 5);
    p.close();
    p.cubicTo(0, 0, 0, 0, 1, 1);
    try testing.expectEqual(5, p.verbs);
    try testing.expectEqual(1 + 1 + 2 + 3, p.points);
    try testing.expectEqualSlices(Verb, &.{ .move, .line, .quad, .close, .cubic }, p.verb[0..5]);
    try testing.expect(flattenLen(&p).points <= t.lx.len);

    var l = t.polyline();
    flatten(&p, &l);
    // Contour 0: start, line end, 32 chords of the quad. Contour 1 restarts at (1, 1) after the
    // close: the start, 31 inner points of the cubic and its end, back at the start (an open
    // contour keeps it).
    try testing.expectEqual(2, l.contours);
    try testing.expectEqual(2 + curve_steps, l.end[0]);
    try testing.expect(l.closed[0] and !l.closed[1]);
    try testing.expectEqual(1, l.x[l.end[0] - 1]);
    try testing.expectEqual(5, l.y[l.end[0] - 1]);
    try testing.expectEqual(1, l.x[l.end[0]]);
    try testing.expectEqual(1, l.y[l.end[0]]);
    try testing.expectEqual(l.end[0] + 1 + curve_steps, l.end[1]);
    // The quad's midpoint at t = 1/2: (5 + 2 * 5 + 1) / 4, (1 + 2 * 5 + 5) / 4.
    try testing.expectApproxEqAbs(4, l.x[1 + curve_steps / 2], 1e-5);
    try testing.expectApproxEqAbs(4, l.y[1 + curve_steps / 2], 1e-5);
}

test "flatten: repeated points are dropped, a closing point equal to the first too" {
    var t: TestBuffers(8, 64) = .{};
    var p = t.path();
    p.moveTo(0, 0);
    p.lineTo(0, 0);
    p.lineTo(4, 0);
    p.lineTo(4, 4);
    p.lineTo(0, 0);
    p.close();
    var l = t.polyline();
    flatten(&p, &l);
    try testing.expectEqual(1, l.contours);
    try testing.expectEqual(3, l.end[0]);
    try testing.expectEqualSlices(f32, &.{ 0, 4, 4 }, l.x[0..3]);
}

test "fill: a pixel-aligned square is full inside and empty outside" {
    var t: TestBuffers(8, 64) = .{};
    var p = t.path();
    p.moveTo(1, 1);
    p.lineTo(4, 1);
    p.lineTo(4, 3);
    p.lineTo(1, 3);
    p.close();
    var l = t.polyline();
    flatten(&p, &l);
    var acc: [64]f32 = undefined;
    var img: [64]u8 = undefined;
    const b, const px = testRender(&l, .nonzero, t.scratch(), &acc, &img);
    try testing.expectEqual(Box{ .x = 1, .y = 1, .w = 3, .h = 2 }, b);
    for (px) |c| try testing.expectEqual(255, c);
}

test "fill: a half-pixel edge covers half, either winding direction" {
    for ([2]bool{ false, true }) |reverse| {
        var t: TestBuffers(8, 64) = .{};
        var p = t.path();
        const xs = [4]f32{ 0, 2.5, 2.5, 0 };
        const ys = [4]f32{ 0, 0, 1, 1 };
        for (0..4) |k| {
            const i = if (reverse) 3 - k else k;
            if (k == 0) p.moveTo(xs[i], ys[i]) else p.lineTo(xs[i], ys[i]);
        }
        p.close();
        var l = t.polyline();
        flatten(&p, &l);
        var acc: [64]f32 = undefined;
        var img: [64]u8 = undefined;
        _, const px = testRender(&l, .nonzero, t.scratch(), &acc, &img);
        try testing.expectEqualSlices(u8, &.{ 255, 255, 128 }, px);
    }
}

test "fill: rules differ where contours overlap with the same winding" {
    var t: TestBuffers(16, 64) = .{};
    var p = t.path();
    // Two nested squares drawn the same way round: winding 2 inside the inner one.
    for ([2][2]f32{ .{ 0, 4 }, .{ 1, 3 } }) |r| {
        p.moveTo(r[0], r[0]);
        p.lineTo(r[1], r[0]);
        p.lineTo(r[1], r[1]);
        p.lineTo(r[0], r[1]);
        p.close();
    }
    var l = t.polyline();
    flatten(&p, &l);
    var acc: [64]f32 = undefined;
    var img: [64]u8 = undefined;
    _, const nz = testRender(&l, .nonzero, t.scratch(), &acc, &img);
    try testing.expectEqual(255, nz[1 * 4 + 1]);
    _, const eo = testRender(&l, .even_odd, t.scratch(), &acc, &img);
    try testing.expectEqual(0, eo[1 * 4 + 1]);
    try testing.expectEqual(255, eo[0]);
}
