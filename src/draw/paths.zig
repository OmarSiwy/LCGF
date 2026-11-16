//! Vector paths: a builder, a flattener and a coverage rasteriser. Tier 0: every step writes
//! into columns the caller owns, and the caller sequences them:
//!
//! 1. `Path`: verbs (move, line, quadratic, cubic, close) and the points they consume.
//! 2. `flatten`: the path as polylines, curves cut into chords. `stroke` turns polylines into
//!    the outline of a stroke, more polylines, filled like any other.
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

/// Chords per curve at most, whatever the tolerance: bounds the work and the rows per curve.
pub const max_curve_steps = 1024;

/// Chords that keep a curve within `tolerance` px of its polyline, cut at equal steps in t:
/// a chord over a step h of t is at most |B''| h^2 / 8 from the curve. A quadratic has
/// B'' = 2 (p0 - 2 p1 + p2); a cubic's |B''| is at most 6 max(|p0 - 2 p1 + p2|, |p1 - 2 p2 + p3|).
/// `c` is p0..p3 as x, y pairs; a quadratic passes its control twice (p1 = p2).
pub fn curveSteps(c: [8]f32, comptime quadratic: bool, tolerance: f32) u32 {
    const d0 = std.math.hypot(c[0] - 2 * c[2] + c[4], c[1] - 2 * c[3] + c[5]);
    const d1 = std.math.hypot(c[2] - 2 * c[4] + c[6], c[3] - 2 * c[5] + c[7]);
    const d2 = if (quadratic) 2 * std.math.hypot(c[0] - 2 * c[2] + c[6], c[1] - 2 * c[3] + c[7]) else 6 * @max(d0, d1);
    const n = @ceil(@sqrt(d2 / (8 * tolerance)));
    return @intFromFloat(std.math.clamp(n, 1, max_curve_steps));
}

/// Rows `flatten` needs for `p` at `tolerance`: an upper bound on the points (plus the vector
/// slack) and the contours.
pub fn flattenLen(p: *const Path, tolerance: f32) struct { points: usize, contours: usize } {
    var points: usize = simd.lanes;
    var contours: usize = 0;
    // The pen, as `flatten` moves it: curves need their start point.
    var cx: f32 = 0;
    var cy: f32 = 0;
    var sx: f32 = 0;
    var sy: f32 = 0;
    var at: usize = 0;
    for (p.verb[0..p.verbs]) |v| {
        const px = p.x[at..];
        const py = p.y[at..];
        // A drawing verb after a close opens a contour of its own and repeats its first point.
        points += switch (v) {
            .move => 1,
            .line => 2,
            .quad => 1 + curveSteps(.{ cx, cy, px[0], py[0], px[0], py[0], px[1], py[1] }, true, tolerance),
            .cubic => 1 + curveSteps(.{ cx, cy, px[0], py[0], px[1], py[1], px[2], py[2] }, false, tolerance),
            .close => 0,
        };
        contours += @intFromBool(v != .close);
        const used: usize = switch (v) {
            .move, .line => 1,
            .quad => 2,
            .cubic => 3,
            .close => 0,
        };
        if (v == .move) {
            sx = px[0];
            sy = py[0];
        }
        cx = if (used == 0) sx else px[used - 1];
        cy = if (used == 0) sy else py[used - 1];
        at += used;
    }
    return .{ .points = points, .contours = contours };
}

/// The polylines of `p`, curves cut into chords that stay within `tolerance` px of them, into
/// `out` (emptied first; sized by `flattenLen` with the same tolerance). A point equal to the one before it is dropped, so no chord has zero length,
/// and a closed contour does not repeat its first point at the end.
pub fn flatten(p: *const Path, tolerance: f32, out: *Polyline) void {
    std.debug.assert(tolerance > 0);
    out.points = 0;
    out.contours = 0;
    var f: Flattener = .{ .out = out, .tolerance = tolerance };
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
    tolerance: f32,
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
    /// `quadratic` evaluates it as a quadratic), cut into `curveSteps` chords of equal steps in t. The
    /// inner points are evaluated a vector of t values at a time and written whole, the count
    /// advancing by the ones that are real; the end point goes through `push`.
    fn curve(f: *Flattener, c: [8]f32, comptime quadratic: bool) void {
        const n = curveSteps(c, quadratic, f.tolerance);
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

/// How two segments of a stroke meet.
pub const Join = enum(u8) {
    /// Outer edges extended until they meet, or `bevel` past `Stroke.miter_limit`.
    miter,
    /// The outer corners joined by an arc around the vertex.
    round,
    /// The outer corners joined by a straight edge.
    bevel,
};

/// How an open contour of a stroke ends.
pub const Cap = enum(u8) {
    /// At the end point.
    butt,
    /// A half disc past the end point (a whole disc is drawn; the other half is inside).
    round,
    /// Half the width past the end point.
    square,
};

/// A stroke style. Lengths in px.
pub const Stroke = struct {
    width: f32,
    join: Join = .miter,
    cap: Cap = .butt,
    /// Longest miter as a multiple of the width (SVG's stroke-miterlimit): a join whose miter
    /// is longer becomes a bevel.
    miter_limit: f32 = 4,
};

/// Points of a polygon that stays within `tolerance` px of a circle of radius `r`: the sagitta
/// of a chord over angle 2 pi / n is r (1 - cos(pi / n)).
pub fn discSteps(r: f32, tolerance: f32) u32 {
    const c = std.math.clamp(1 - tolerance / @max(r, 1e-6), -1, 1);
    const n = @ceil(std.math.pi / @max(std.math.acos(c), 1e-6));
    return @intFromFloat(std.math.clamp(n, 4, max_curve_steps));
}

/// Rows `stroke` needs for `l` in style `st` at `tolerance`.
pub fn strokeLen(l: *const Polyline, st: Stroke, tolerance: f32) struct { points: usize, contours: usize } {
    const disc: usize = discSteps(st.width / 2, tolerance);
    // A round join is a sector of at most half the disc: its centre, and up to disc / 2 + 1
    // points on the arc.
    const join_points: usize = if (st.join == .round) disc / 2 + 2 else 4;
    const cap_points: usize = switch (st.cap) {
        .butt => 0,
        .square => 4,
        .round => disc,
    };
    var points: usize = 0;
    var contours: usize = 0;
    var first: usize = 0;
    for (l.end[0..l.contours], l.closed[0..l.contours]) |end, closed| {
        const k = shape(end - first, closed);
        points += 4 * k.segments + join_points * k.joins + @max(cap_points, disc) * k.caps;
        contours += k.segments + k.joins + k.caps;
        first = end;
    }
    return .{ .points = points, .contours = contours };
}

/// Pieces of a stroked contour of `m` points. A single point is a dot (only a round cap draws
/// it); a closed contour needs at least two points.
fn shape(m: usize, closed: bool) struct { segments: usize, joins: usize, caps: usize } {
    if (m < 2) return .{ .segments = 0, .joins = 0, .caps = m };
    if (closed) return .{ .segments = m, .joins = m, .caps = 0 };
    return .{ .segments = m - 1, .joins = m - 2, .caps = 2 };
}

/// The outline of `l` stroked in style `st`, into `out` (emptied first; sized by `strokeLen`) as
/// closed contours to fill under `Rule.nonzero`: one quadrilateral per segment, one piece per
/// join and per cap, all wound the same way so their union is what fills. Overlap costs
/// nothing under the nonzero rule, so no piece is clipped against another; round joins and caps
/// are polygons within `tolerance` px of their circle.
pub fn stroke(l: *const Polyline, st: Stroke, tolerance: f32, out: *Polyline) void {
    out.points = 0;
    out.contours = 0;
    const hw = st.width / 2;
    const disc = discSteps(hw, tolerance);
    var first: usize = 0;
    for (l.end[0..l.contours], l.closed[0..l.contours]) |end, closed| {
        defer first = end;
        const m = end - first;
        const k = shape(m, closed);
        const px = l.x[first..end];
        const py = l.y[first..end];
        if (m == 1) {
            if (st.cap == .round) circle(out, px[0], py[0], hw, disc);
            continue;
        }
        for (0..k.segments) |i| {
            const j = (i + 1) % m;
            quad(out, px[i], py[i], px[j], py[j], hw);
        }
        // Joins at every vertex of a closed contour, at the inner ones of an open one.
        const j0: usize = @intFromBool(!closed);
        for (j0..j0 + k.joins) |v| {
            const a = (v + m - 1) % m;
            const b = (v + 1) % m;
            const d1 = unit(px[v] - px[a], py[v] - py[a]);
            const d2 = unit(px[b] - px[v], py[b] - py[v]);
            corner(out, px[v], py[v], d1, d2, hw, if (st.join == .miter) st.miter_limit else 0, if (st.join == .round) disc else 0);
        }
        if (k.caps == 0) continue;
        // Outward directions at the two ends.
        const ds = unit(px[0] - px[1], py[0] - py[1]);
        const de = unit(px[m - 1] - px[m - 2], py[m - 1] - py[m - 2]);
        for ([2][4]f32{ .{ px[0], py[0], ds[0], ds[1] }, .{ px[m - 1], py[m - 1], de[0], de[1] } }) |e| {
            switch (st.cap) {
                .butt => {},
                .square => quad(out, e[0], e[1], e[0] + e[2] * hw, e[1] + e[3] * hw, hw),
                .round => circle(out, e[0], e[1], hw, disc),
            }
        }
    }
}

fn unit(dx: f32, dy: f32) [2]f32 {
    const inv = 1 / @max(std.math.hypot(dx, dy), 1e-12);
    return .{ dx * inv, dy * inv };
}

/// Appends one closed contour.
fn piece(out: *Polyline, xs: []const f32, ys: []const f32) void {
    std.debug.assert(out.points + xs.len <= out.x.len and out.contours < out.end.len);
    @memcpy(out.x[out.points..][0..xs.len], xs);
    @memcpy(out.y[out.points..][0..ys.len], ys);
    out.points += @intCast(xs.len);
    out.end[out.contours] = out.points;
    out.closed[out.contours] = true;
    out.contours += 1;
}

/// The rectangle of half-width `hw` around segment a-b. Its winding (negative area in x right,
/// y down) is the one every stroke piece has.
fn quad(out: *Polyline, ax: f32, ay: f32, bx: f32, by: f32, hw: f32) void {
    const d = unit(bx - ax, by - ay);
    const nx = -d[1] * hw;
    const ny = d[0] * hw;
    piece(out, &.{ ax + nx, bx + nx, bx - nx, ax - nx }, &.{ ay + ny, by + ny, by - ny, ay - ny });
}

/// A polygon of `n` points on the circle, angle decreasing so it winds like `quad`.
fn circle(out: *Polyline, cx: f32, cy: f32, r: f32, n: u32) void {
    std.debug.assert(out.points + n <= out.x.len and out.contours < out.end.len);
    const step = -2 * std.math.pi / @as(f32, @floatFromInt(n));
    for (0..n) |i| {
        const a = step * @as(f32, @floatFromInt(i));
        out.x[out.points + i] = cx + r * @cos(a);
        out.y[out.points + i] = cy + r * @sin(a);
    }
    out.points += n;
    out.end[out.contours] = out.points;
    out.closed[out.contours] = true;
    out.contours += 1;
}

/// A join at `p` from direction `d1` to `d2` (unit vectors): p, the outer corner of the first
/// segment, then the tip, then the outer corner of the second. With `disc` > 0 the tip is an arc
/// of the circle the disc polygon approximates, as many of its steps as the turn needs (round);
/// else it is the miter point when its length is within `limit` widths and the corners'
/// midpoint otherwise (a bevel; `limit` 0 always bevels), both computed and one selected. The
/// corner order follows the turn so the piece winds like `quad`.
fn corner(out: *Polyline, px: f32, py: f32, d1: [2]f32, d2: [2]f32, hw: f32, limit: f32, disc: u32) void {
    const cross = d1[0] * d2[1] - d1[1] * d2[0];
    const dot = std.math.clamp(d1[0] * d2[0] + d1[1] * d2[1], -1, 1);
    // The outer side is away from the turn.
    const s = simd.selF(cross > 0, -1, 1);
    const n1 = [2]f32{ -d1[1] * hw * s, d1[0] * hw * s };
    const n2 = [2]f32{ -d2[1] * hw * s, d2[0] * hw * s };
    const a = [2]f32{ px + n1[0], py + n1[1] };
    const b = [2]f32{ px + n2[0], py + n2[1] };
    const left = s > 0;
    const p1 = [2]f32{ simd.selF(left, a[0], b[0]), simd.selF(left, a[1], b[1]) };
    const p3 = [2]f32{ simd.selF(left, b[0], a[0]), simd.selF(left, b[1], a[1]) };
    if (disc > 0) {
        // From p1 to p3 the angle around p decreases by the turn, as in `circle`.
        const turn = std.math.acos(dot);
        const k: u32 = @intFromFloat(@max(@ceil(turn / (2 * std.math.pi) * @as(f32, @floatFromInt(disc))), 1));
        std.debug.assert(out.points + k + 2 <= out.x.len and out.contours < out.end.len);
        const start = std.math.atan2(p1[1] - py, p1[0] - px);
        const o = out.x[out.points..];
        const oy = out.y[out.points..];
        o[0] = px;
        oy[0] = py;
        for (0..k + 1) |i| {
            const ang = start - turn * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(k));
            o[i + 1] = px + hw * @cos(ang);
            oy[i + 1] = py + hw * @sin(ang);
        }
        out.points += k + 2;
        out.end[out.contours] = out.points;
        out.closed[out.contours] = true;
        out.contours += 1;
        return;
    }
    // Miter length / width = 1 / cos(half the turn) = sqrt(2 / (1 + dot)).
    const ok = 2 <= limit * limit * (1 + dot);
    const k = 1 / (1 + dot);
    const tip = [2]f32{
        simd.selF(ok, px + (n1[0] + n2[0]) * k, (a[0] + b[0]) / 2),
        simd.selF(ok, py + (n1[1] + n2[1]) * k, (a[1] + b[1]) / 2),
    };
    piece(out, &.{ px, p1[0], tip[0], p3[0] }, &.{ py, p1[1], tip[1], p3[1] });
}

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
    const tol = 1.0 / 64.0;
    try testing.expect(flattenLen(&p, tol).points <= t.lx.len);
    // |B''| / (8 tol): quad 2 |(-4, -4)| * 8 = 90.5, cubic 6 |(1, 1)| * 8 = 67.9.
    const quad_steps = curveSteps(.{ 5, 1, 5, 5, 5, 5, 1, 5 }, true, tol);
    const cubic_steps = curveSteps(.{ 1, 1, 0, 0, 0, 0, 1, 1 }, false, tol);
    try testing.expectEqual(10, quad_steps);
    try testing.expectEqual(9, cubic_steps);

    var l = t.polyline();
    flatten(&p, tol, &l);
    // Contour 0: start, line end, the chords of the quad. Contour 1 restarts at (1, 1) after the
    // close: the start, the inner points of the cubic and its end, back at the start (an open
    // contour keeps it).
    try testing.expectEqual(2, l.contours);
    try testing.expectEqual(2 + quad_steps, l.end[0]);
    try testing.expect(l.closed[0] and !l.closed[1]);
    try testing.expectEqual(1, l.x[l.end[0] - 1]);
    try testing.expectEqual(5, l.y[l.end[0] - 1]);
    try testing.expectEqual(1, l.x[l.end[0]]);
    try testing.expectEqual(1, l.y[l.end[0]]);
    try testing.expectEqual(l.end[0] + 1 + cubic_steps, l.end[1]);
    // The quad's midpoint at t = 1/2: (5 + 2 * 5 + 1) / 4, (1 + 2 * 5 + 5) / 4.
    try testing.expectApproxEqAbs(4, l.x[1 + quad_steps / 2], 1e-5);
    try testing.expectApproxEqAbs(4, l.y[1 + quad_steps / 2], 1e-5);
}

test "flatten: every chord stays within the tolerance, and fewer chords for a looser one" {
    const curves = [_][8]f32{
        .{ 0, 0, 30, -40, 70, 90, 100, 10 },
        .{ 5, 5, 200, 5, 5, 200, 150, 150 },
        .{ 0, 0, 1, 2, 2, 1, 3, 3 },
        .{ 10, 10, 60, 10, 60, 10, 60, 60 },
    };
    var t: TestBuffers(8, 2048) = .{};
    var last_count: u32 = std.math.maxInt(u32);
    for ([_]f32{ 1.0 / 128.0, 1.0 / 16.0, 0.25, 1 }) |tol| {
        var count: u32 = 0;
        for (curves, 0..) |c, ci| {
            const quadratic = ci == 3; // c[2..4] == c[4..6]: its control twice
            var p = t.path();
            p.moveTo(c[0], c[1]);
            if (quadratic) p.quadTo(c[2], c[3], c[6], c[7]) else p.cubicTo(c[2], c[3], c[4], c[5], c[6], c[7]);
            var l = t.polyline();
            try testing.expect(flattenLen(&p, tol).points <= t.lx.len);
            flatten(&p, tol, &l);
            const n = l.points - 1;
            count += n;
            // Each chord k joins t = k / n and (k + 1) / n; sample the curve between them.
            for (0..n) |k| {
                const ax = l.x[k];
                const ay = l.y[k];
                const dx = l.x[k + 1] - ax;
                const dy = l.y[k + 1] - ay;
                for (1..16) |j| {
                    const u = (@as(f32, @floatFromInt(k)) + @as(f32, @floatFromInt(j)) / 16) / @as(f32, @floatFromInt(n));
                    const s = 1 - u;
                    const b = if (quadratic)
                        [4]f32{ s * s, 2 * s * u, 0, u * u }
                    else
                        [4]f32{ s * s * s, 3 * s * s * u, 3 * s * u * u, u * u * u };
                    const x = b[0] * c[0] + b[1] * c[2] + b[2] * c[4] + b[3] * c[6];
                    const y = b[0] * c[1] + b[1] * c[3] + b[2] * c[5] + b[3] * c[7];
                    const along = std.math.clamp(((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy), 0, 1);
                    const dist = std.math.hypot(x - ax - along * dx, y - ay - along * dy);
                    try testing.expect(dist <= tol * 1.01 + 1e-4);
                }
            }
        }
        try testing.expect(count < last_count);
        last_count = count;
    }
}

test "flatten: a straight or point-like curve is one chord" {
    try testing.expectEqual(1, curveSteps(.{ 0, 0, 1, 1, 2, 2, 3, 3 }, false, 0.01));
    try testing.expectEqual(1, curveSteps(.{ 4, 4, 4, 4, 4, 4, 4, 4 }, false, 0.01));
    try testing.expectEqual(max_curve_steps, curveSteps(.{ 0, 0, 1e6, 0, -1e6, 0, 0, 0 }, false, 0.01));
    var t: TestBuffers(8, 64) = .{};
    var p = t.path();
    p.moveTo(4, 4);
    p.cubicTo(4, 4, 4, 4, 4, 4);
    p.lineTo(8, 4);
    var l = t.polyline();
    flatten(&p, 0.25, &l);
    try testing.expectEqual(2, l.points);
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
    flatten(&p, 0.25, &l);
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
    flatten(&p, 0.25, &l);
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
        flatten(&p, 0.25, &l);
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
    flatten(&p, 0.25, &l);
    var acc: [64]f32 = undefined;
    var img: [64]u8 = undefined;
    _, const nz = testRender(&l, .nonzero, t.scratch(), &acc, &img);
    try testing.expectEqual(255, nz[1 * 4 + 1]);
    _, const eo = testRender(&l, .even_odd, t.scratch(), &acc, &img);
    try testing.expectEqual(0, eo[1 * 4 + 1]);
    try testing.expectEqual(255, eo[0]);
}

/// Twice the signed area of each contour of `l` (shoelace).
fn testAreas(l: *const Polyline, out: []f32) []f32 {
    var first: usize = 0;
    for (l.end[0..l.contours], 0..) |end, c| {
        var a: f32 = 0;
        for (first..end) |i| {
            const j = if (i + 1 == end) first else i + 1;
            a += l.x[i] * l.y[j] - l.x[j] * l.y[i];
        }
        out[c] = a;
        first = end;
    }
    return out[0..l.contours];
}

test "stroke: pieces per segment, join and cap, all wound the same way" {
    var t: TestBuffers(8, 64) = .{};
    var p = t.path();
    p.moveTo(2, 2);
    p.lineTo(20, 2);
    p.lineTo(20, 14);
    p.lineTo(4, 20);
    var l = t.polyline();
    flatten(&p, 0.25, &l);
    var o: TestBuffers(64, 512) = .{};
    for ([_]Join{ .miter, .round, .bevel }) |join| for ([_]Cap{ .butt, .round, .square }) |cap| {
        const st: Stroke = .{ .width = 3, .join = join, .cap = cap };
        var s = o.polyline();
        const need = strokeLen(&l, st, 0.1);
        stroke(&l, st, 0.1, &s);
        try testing.expect(s.points <= need.points and s.contours <= need.contours);
        // 3 segments, 2 joins, 2 caps unless butt.
        try testing.expectEqual(@as(u32, if (cap == .butt) 5 else 7), s.contours);
        var areas: [16]f32 = undefined;
        for (testAreas(&s, &areas)) |a| try testing.expect(a < 0);
        if (join == .round) {
            // The first join turns down at (20, 2): its arc runs from the second segment's outer
            // corner (21.5, 2) to the first one's (20, 0.5), angle decreasing.
            const first = s.end[2];
            const end = s.end[3];
            try testing.expectApproxEqAbs(21.5, s.x[first + 1], 1e-4);
            try testing.expectApproxEqAbs(2, s.y[first + 1], 1e-4);
            try testing.expectApproxEqAbs(20, s.x[end - 1], 1e-4);
            try testing.expectApproxEqAbs(0.5, s.y[end - 1], 1e-4);
        }
    };
}

test "stroke: a straight stroke fills its rectangle; a closed one gets no caps" {
    var t: TestBuffers(8, 64) = .{};
    var p = t.path();
    p.moveTo(1, 3);
    p.lineTo(7, 3);
    var l = t.polyline();
    flatten(&p, 0.25, &l);
    var o: TestBuffers(16, 256) = .{};
    var s = o.polyline();
    stroke(&l, .{ .width = 2, .cap = .square }, 0.1, &s);
    var acc: [128]f32 = undefined;
    var img: [128]u8 = undefined;
    const b, const px = testRender(&s, .nonzero, o.scratch(), &acc, &img);
    try testing.expectEqual(Box{ .x = 0, .y = 2, .w = 8, .h = 2 }, b);
    for (px) |c| try testing.expectEqual(255, c);

    p.clear();
    p.moveTo(0, 0);
    p.lineTo(4, 0);
    p.lineTo(4, 4);
    p.close();
    flatten(&p, 0.25, &l);
    stroke(&l, .{ .width = 1, .cap = .round }, 0.1, &s);
    try testing.expectEqual(6, s.contours);
}

test "stroke: a sharp miter past the limit becomes a bevel" {
    var t: TestBuffers(8, 64) = .{};
    var p = t.path();
    // A 20-degree turn back: miter length 1 / sin(10 deg) = 5.8 widths.
    p.moveTo(0, 0);
    p.lineTo(20, 0);
    p.lineTo(20 - 20 * @cos(std.math.degreesToRadians(20.0)), 20 * @sin(std.math.degreesToRadians(20.0)));
    var l = t.polyline();
    flatten(&p, 0.25, &l);
    var o: TestBuffers(16, 256) = .{};
    var s = o.polyline();
    var right: [2]f32 = undefined;
    for ([_]f32{ 10, 4 }, 0..) |limit, k| {
        stroke(&l, .{ .width = 2, .miter_limit = limit }, 0.1, &s);
        var hi: f32 = 0;
        for (s.x[0..s.points]) |x| hi = @max(hi, x);
        right[k] = hi;
    }
    try testing.expectApproxEqAbs(20 + 1.0 / @sin(std.math.degreesToRadians(10.0)) * @cos(std.math.degreesToRadians(10.0)), right[0], 1e-3);
    try testing.expect(right[1] < 21.01);
}
