//! Optional vector styling on the existing Path/Polyline representation. Arcs, dashes,
//! markers, width profiles and transforms lower to that same coverage rasterizer. The caller
//! owns every output/scratch span and can keep or replace any preparation step independently.

const std = @import("std");
const simd = @import("../core/simd.zig");
const paths = @import("paths.zig");
const brushes = @import("brushes.zig");
const surface = @import("surface.zig");
const compositor = @import("compositor.zig");
const decoration = @import("decoration.zig");
const F = simd.F;
const Path = paths.Path;
const Polyline = paths.Polyline;

pub const Error = decoration.Error || error{ InvalidPath, InvalidDash, InvalidStroke, IncompatiblePath };
pub const Capacity = struct { points: usize, contours: usize };
pub const Arc = struct { radius: [2]f32, rotation_degrees: f32 = 0, large: bool = false, sweep: bool = true };
pub const StrokeUnits = enum { geometry, logical, device };
pub const DashStyle = struct { array: []const f32, offset: f32 = 0, cap: paths.Cap = .butt };
pub const MarkerKind = enum { start, mid, end };
pub const Marker = struct { position: [2]f32, tangent: [2]f32, kind: MarkerKind };
pub const Orient = union(enum) { auto, auto_start_reverse, angle: f32 };
pub const MarkerUnits = enum { user, stroke_width, device };
pub const MarkerOptions = struct { orient: Orient = .auto, units: MarkerUnits = .user, size: [2]f32 = .{ 1, 1 }, reference: [2]f32 = .{ 0, 0 }, stroke_width: f32 = 1, device_scale: f32 = 1 };

fn finite2(v: [2]f32) bool {
    return std.math.isFinite(v[0]) and std.math.isFinite(v[1]);
}
fn distance(a: [2]f32, b: [2]f32) f32 {
    return std.math.hypot(b[0] - a[0], b[1] - a[1]);
}
fn unit(v: [2]f32) [2]f32 {
    const length = std.math.hypot(v[0], v[1]);
    return if (length > 1e-20) .{ v[0] / length, v[1] / length } else .{ 1, 0 };
}
fn room(path: *const Path, verbs: usize, points: usize) Error!void {
    if (verbs > path.verb.len - path.verbs or points > path.x.len - path.points or points > path.y.len - path.points) return error.InsufficientStorage;
}

/// SVG endpoint-parameterized elliptical arc. Radii are made positive and scaled uniformly
/// when too small to reach the endpoints. It appends <=4 cubic pieces, with no intermediate
/// heap geometry. Formula: SVG 2 Implementation Notes, elliptical arc parameter conversion.
pub fn arcTo(path: *Path, from: [2]f32, to: [2]f32, options: Arc) Error!void {
    if (!finite2(from) or !finite2(to) or !finite2(options.radius) or !std.math.isFinite(options.rotation_degrees)) return error.InvalidGeometry;
    if (path.verbs == 0) return error.InvalidPath;
    if (from[0] == to[0] and from[1] == to[1]) return;
    if (options.radius[0] == 0 or options.radius[1] == 0) {
        try room(path, 1, 1);
        path.lineTo(to[0], to[1]);
        return;
    }
    const phi: f64 = @as(f64, options.rotation_degrees) * std.math.pi / 180;
    const cp = @cos(phi);
    const sp = @sin(phi);
    const dx = (@as(f64, from[0]) - to[0]) * 0.5;
    const dy = (@as(f64, from[1]) - to[1]) * 0.5;
    const x = cp * dx + sp * dy;
    const y = -sp * dx + cp * dy;
    var rx: f64 = @abs(options.radius[0]);
    var ry: f64 = @abs(options.radius[1]);
    const correction = @sqrt(@max(x * x / (rx * rx) + y * y / (ry * ry), 1));
    rx *= correction;
    ry *= correction;
    const denominator = rx * rx * y * y + ry * ry * x * x;
    const numerator = @max(rx * rx * ry * ry - denominator, 0);
    const sign: f64 = if (options.large == options.sweep) -1 else 1;
    const coefficient = sign * @sqrt(numerator / @max(denominator, 1e-200));
    const cx = coefficient * rx * y / ry;
    const cy = -coefficient * ry * x / rx;
    const center_x = cp * cx - sp * cy + (@as(f64, from[0]) + to[0]) * 0.5;
    const center_y = sp * cx + cp * cy + (@as(f64, from[1]) + to[1]) * 0.5;
    const ux = (x - cx) / rx;
    const uy = (y - cy) / ry;
    const vx = (-x - cx) / rx;
    const vy = (-y - cy) / ry;
    const start = std.math.atan2(uy, ux);
    var sweep = std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
    if (options.sweep and sweep < 0) sweep += 2 * std.math.pi;
    if (!options.sweep and sweep > 0) sweep -= 2 * std.math.pi;
    const pieces: usize = @intFromFloat(@min(@max(@ceil(@abs(sweep) / (std.math.pi / 2.0)), 1), 4));
    try room(path, pieces, 3 * pieces);
    const step = sweep / @as(f64, @floatFromInt(pieces));
    const handle = 4.0 / 3.0 * @tan(step / 4);
    var cubics: [4][6]f32 = undefined;
    for (0..pieces) |i| {
        const a = start + step * @as(f64, @floatFromInt(i));
        const b = a + step;
        const local = [3][2]f64{
            .{ rx * (@cos(a) - handle * @sin(a)), ry * (@sin(a) + handle * @cos(a)) },
            .{ rx * (@cos(b) + handle * @sin(b)), ry * (@sin(b) - handle * @cos(b)) },
            .{ rx * @cos(b), ry * @sin(b) },
        };
        for (local, 0..) |p, k| {
            const px = center_x + cp * p[0] - sp * p[1];
            const py = center_y + sp * p[0] + cp * p[1];
            if (@abs(px) > std.math.floatMax(f32) or @abs(py) > std.math.floatMax(f32)) return error.InvalidGeometry;
            cubics[i][2 * k] = @floatCast(px);
            cubics[i][2 * k + 1] = @floatCast(py);
        }
    }
    cubics[pieces - 1][4] = to[0];
    cubics[pieces - 1][5] = to[1];
    for (cubics[0..pieces]) |c| path.cubicTo(c[0], c[1], c[2], c[3], c[4], c[5]);
}

fn validatePolyline(poly: *const Polyline) Error!void {
    if (poly.points > poly.x.len or poly.points > poly.y.len or poly.contours > poly.end.len or poly.contours > poly.closed.len) return error.InvalidPath;
    var first: u32 = 0;
    for (poly.end[0..poly.contours]) |end| {
        if (end < first or end > poly.points) return error.InvalidPath;
        first = end;
    }
    if (first != poly.points) return error.InvalidPath;
    for (poly.x[0..poly.points], poly.y[0..poly.points]) |x, y| if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.InvalidGeometry;
}
fn polylineRoom(out: *const Polyline, required: Capacity) Error!void {
    if (out.x.len < required.points or out.y.len < required.points or out.end.len < required.contours or out.closed.len < required.contours) return error.InsufficientStorage;
}
fn validateMatrix(matrix: [6]f32) Error!void {
    for (matrix) |v| if (!std.math.isFinite(v)) return error.InvalidTransform;
}

/// Transforms padded columns, allowing exact in-place use. Points need simd.rows(points)
/// capacity in both source and destination, in keeping with the core column convention.
pub fn transform(src: *const Polyline, matrix: [6]f32, out: *Polyline) Error!void {
    try validatePolyline(src);
    try validateMatrix(matrix);
    try polylineRoom(out, .{ .points = simd.rows(src.points), .contours = src.contours });
    if (src.x.len < simd.rows(src.points) or src.y.len < simd.rows(src.points)) return error.InsufficientStorage;
    const n = simd.padded(src.points);
    var i: usize = 0;
    while (i < n) : (i += simd.lanes) {
        const x = simd.loadF(src.x, i);
        const y = simd.loadF(src.y, i);
        const active = simd.iota + simd.u(@intCast(i)) < simd.u(src.points);
        simd.storeF(out.x, i, @select(f32, active, x * simd.f(matrix[0]) + y * simd.f(matrix[2]) + simd.f(matrix[4]), simd.f(0)));
        simd.storeF(out.y, i, @select(f32, active, x * simd.f(matrix[1]) + y * simd.f(matrix[3]) + simd.f(matrix[5]), simd.f(0)));
    }
    if (out.end.ptr != src.end.ptr) @memcpy(out.end[0..src.contours], src.end[0..src.contours]);
    if (out.closed.ptr != src.closed.ptr) @memcpy(out.closed[0..src.contours], src.closed[0..src.contours]);
    out.points = src.points;
    out.contours = src.contours;
}

/// Stroke before transform for geometry-scaled widths; transform the centerline first for
/// logical/device widths. This also handles nonuniform scale and skew correctly, unlike
/// dividing by a guessed average scale. Scratch holds the transformed centerline.
pub fn strokeTransformed(src: *const Polyline, style: paths.Stroke, matrix: [6]f32, units: StrokeUnits, device_scale: f32, tolerance: f32, scratch: *Polyline, out: *Polyline) Error!void {
    try validatePolyline(src);
    try validateMatrix(matrix);
    if (!std.math.isFinite(style.width) or style.width < 0 or !std.math.isFinite(tolerance) or tolerance <= 0 or !std.math.isFinite(device_scale) or device_scale <= 0) return error.InvalidStroke;
    var st = style;
    if (units == .device) st.width /= device_scale;
    const lengths = paths.strokeLen(src, st, tolerance);
    try polylineRoom(out, .{ .points = simd.rows(lengths.points), .contours = lengths.contours });
    if (units == .geometry) {
        paths.stroke(src, st, tolerance, out);
        try transform(out, matrix, out);
    } else {
        try transform(src, matrix, scratch);
        paths.stroke(scratch, st, tolerance, out);
    }
}

pub fn variableStrokeCapacity(src: *const Polyline, widths: []const f32, tolerance: f32) Error!Capacity {
    try validatePolyline(src);
    if (!std.math.isFinite(tolerance) or tolerance <= 0 or widths.len < src.points) return error.InvalidStroke;
    var points: usize = 4 * @as(usize, src.points);
    for (widths[0..src.points]) |width| {
        if (!std.math.isFinite(width) or width < 0) return error.InvalidStroke;
        points = std.math.add(usize, points, paths.discSteps(width * 0.5, tolerance)) catch return error.InvalidStroke;
    }
    return .{ .points = simd.rows(points), .contours = 2 * @as(usize, src.points) };
}

/// Round-capped/round-joined varying-width outline: the union of vertex discs and tangent
/// quadrilaterals between them. It is the convex hull of the two endpoint discs on each segment,
/// so a larger radius that encloses the smaller disc needs no degenerate tangent polygon.
pub fn variableStroke(src: *const Polyline, widths: []const f32, tolerance: f32, out: *Polyline) Error!void {
    try polylineRoom(out, try variableStrokeCapacity(src, widths, tolerance));
    out.points = 0;
    out.contours = 0;
    for (0..src.points) |i| {
        const radius = widths[i] * 0.5;
        if (radius == 0) continue;
        const pieces = paths.discSteps(radius, tolerance);
        for (0..pieces) |k| {
            const radians = -2 * std.math.pi * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(pieces));
            out.x[out.points] = src.x[i] + radius * @cos(radians);
            out.y[out.points] = src.y[i] + radius * @sin(radians);
            out.points += 1;
        }
        out.end[out.contours] = out.points;
        out.closed[out.contours] = true;
        out.contours += 1;
    }
    var first: usize = 0;
    for (src.end[0..src.contours], src.closed[0..src.contours]) |end, closed| {
        const count = end - first;
        defer first = end;
        if (count < 2) continue;
        for (0..count - 1 + @intFromBool(closed)) |k| {
            const i = first + k;
            const j = first + (k + 1) % count;
            const ax = src.x[i];
            const ay = src.y[i];
            const bx = src.x[j];
            const by = src.y[j];
            const length = std.math.hypot(bx - ax, by - ay);
            const a = widths[i] * 0.5;
            const b = widths[j] * 0.5;
            if (length <= @abs(a - b) or length <= 1e-20) continue;
            const dx = (bx - ax) / length;
            const dy = (by - ay) / length;
            const slope = (a - b) / length;
            const normal = @sqrt(@max(1 - slope * slope, 0));
            const upper = [2]f32{ dx * slope - dy * normal, dy * slope + dx * normal };
            const lower = [2]f32{ dx * slope + dy * normal, dy * slope - dx * normal };
            const xs = [4]f32{ ax + upper[0] * a, bx + upper[0] * b, bx + lower[0] * b, ax + lower[0] * a };
            const ys = [4]f32{ ay + upper[1] * a, by + upper[1] * b, by + lower[1] * b, ay + lower[1] * a };
            @memcpy(out.x[out.points..][0..4], &xs);
            @memcpy(out.y[out.points..][0..4], &ys);
            out.points += 4;
            out.end[out.contours] = out.points;
            out.closed[out.contours] = true;
            out.contours += 1;
        }
    }
}

fn dashPeriod(pattern: []const f32) Error!f32 {
    if (pattern.len == 0) return error.InvalidDash;
    var total: f32 = 0;
    for (pattern) |v| {
        if (!std.math.isFinite(v) or v < 0) return error.InvalidDash;
        total += v;
    }
    if (!std.math.isFinite(total) or total <= 0) return error.InvalidDash;
    return total * @as(f32, if (pattern.len % 2 == 1) 2 else 1);
}

pub fn dashCapacity(src: *const Polyline, pattern: []const f32) Error!Capacity {
    try validatePolyline(src);
    _ = try dashPeriod(pattern);
    var shortest: f32 = std.math.floatMax(f32);
    var zero_ink: usize = 0;
    for (pattern, 0..) |v, k| {
        if (v > 0) shortest = @min(shortest, v);
        if (v == 0 and (k % 2 == 0 or pattern.len % 2 == 1)) zero_ink += 1;
    }
    var total: f64 = 0;
    var first: usize = 0;
    for (src.end[0..src.contours], src.closed[0..src.contours]) |end, closed| {
        const count = end - first;
        if (count > 1) for (0..count - 1 + @intFromBool(closed)) |k| {
            const i = first + k;
            const j = first + (k + 1) % count;
            total += distance(.{ src.x[i], src.y[i] }, .{ src.x[j], src.y[j] });
        };
        first = end;
    }
    const splits = @ceil(total / shortest) + @as(f64, @floatFromInt(src.points + 4 * src.contours));
    if (!std.math.isFinite(splits) or splits > 1_000_000_000) return error.InvalidDash;
    const bound = std.math.mul(usize, @as(usize, @intFromFloat(splits)), zero_ink + 1) catch return error.InvalidDash;
    return .{ .points = simd.rows(2 * bound), .contours = bound };
}

const DashWriter = struct {
    out: *Polyline,
    open: bool = false,
    first: u32 = 0,
    fn push(w: *DashWriter, x: f32, y: f32) void {
        if (!w.open) {
            w.open = true;
            w.first = w.out.points;
        } else if (w.out.x[w.out.points - 1] == x and w.out.y[w.out.points - 1] == y) return;
        w.out.x[w.out.points] = x;
        w.out.y[w.out.points] = y;
        w.out.points += 1;
    }
    fn finish(w: *DashWriter) void {
        if (!w.open) return;
        w.out.end[w.out.contours] = w.out.points;
        w.out.closed[w.out.contours] = false;
        w.out.contours += 1;
        w.open = false;
    }
};

fn reverse(values: []f32) void {
    var i: usize = 0;
    while (i < values.len / 2) : (i += 1) std.mem.swap(f32, &values[i], &values[values.len - 1 - i]);
}

/// Splits centerlines into on-contours. Feed the result to the existing `paths.stroke` to
/// choose butt/round/square dash caps and ordinary joins. Odd patterns repeat twice; zeros
/// advance the pattern without hanging. A closed seam that falls inside ink is joined once.
pub fn dash(src: *const Polyline, pattern: []const f32, phase: f32, out: *Polyline) Error!void {
    const required = try dashCapacity(src, pattern);
    try polylineRoom(out, required);
    if (!std.math.isFinite(phase)) return error.InvalidDash;
    const period = try dashPeriod(pattern);
    const pattern_count = pattern.len * (if (pattern.len % 2 == 1) @as(usize, 2) else 1);
    out.points = 0;
    out.contours = 0;
    var writer: DashWriter = .{ .out = out };
    var first: usize = 0;
    for (src.end[0..src.contours], src.closed[0..src.contours]) |end, closed| {
        const contour_first = out.contours;
        const point_first = out.points;
        const count = end - first;
        defer first = end;
        if (count == 0) continue;
        var index: usize = 0;
        var offset = @mod(phase, period);
        while (offset >= pattern[index % pattern.len]) {
            if (offset == 0 and pattern[index % pattern.len] == 0 and index % 2 == 0) {
                writer.push(src.x[first], src.y[first]);
                writer.finish();
            }
            offset -= pattern[index % pattern.len];
            index = (index + 1) % pattern_count;
        }
        var remaining = pattern[index % pattern.len] - offset;
        const starts_on = index % 2 == 0;
        if (count == 1) {
            if (starts_on) writer.push(src.x[first], src.y[first]);
            writer.finish();
            continue;
        }
        var end_on = starts_on;
        for (0..count - 1 + @intFromBool(closed)) |segment| {
            const i = first + segment;
            const j = first + (segment + 1) % count;
            const ax = src.x[i];
            const ay = src.y[i];
            const dx = src.x[j] - ax;
            const dy = src.y[j] - ay;
            const length = std.math.hypot(dx, dy);
            if (length <= 1e-20) continue;
            var at: f32 = 0;
            while (at < length) {
                const take = @min(remaining, length - at);
                const on = index % 2 == 0;
                if (on) {
                    writer.push(ax + dx * (at / length), ay + dy * (at / length));
                    writer.push(ax + dx * ((at + take) / length), ay + dy * ((at + take) / length));
                }
                at += take;
                remaining -= take;
                end_on = on;
                if (remaining <= 1e-7) {
                    index = (index + 1) % pattern_count;
                    while (pattern[index % pattern.len] == 0) {
                        if (index % 2 == 0) {
                            writer.finish();
                            writer.push(ax + dx * (at / length), ay + dy * (at / length));
                            writer.finish();
                        }
                        index = (index + 1) % pattern_count;
                    }
                    if (on and index % 2 == 1) writer.finish();
                    remaining = pattern[index % pattern.len];
                }
            }
        }
        writer.finish();
        const made = out.contours - contour_first;
        if (closed and starts_on and end_on and made > 0) {
            if (made == 1) {
                const last = out.points - 1;
                if (out.x[last] == out.x[point_first] and out.y[last] == out.y[point_first]) {
                    out.points -= 1;
                    out.end[contour_first] = out.points;
                }
                out.closed[contour_first] = true;
            } else {
                const last_start = out.end[out.contours - 2];
                const last_size = out.points - last_start;
                // Rotate the final ink contour to the front, then join it with the first.
                reverse(out.x[point_first..last_start]);
                reverse(out.x[last_start..out.points]);
                reverse(out.x[point_first..out.points]);
                reverse(out.y[point_first..last_start]);
                reverse(out.y[last_start..out.points]);
                reverse(out.y[point_first..out.points]);
                // The closed endpoint and the first contour's start are the same vertex.
                // Keep one copy so a later miter/round join sees two nonzero adjacent segments.
                const duplicate = point_first + last_size;
                std.mem.copyForwards(f32, out.x[duplicate .. out.points - 1], out.x[duplicate + 1 .. out.points]);
                std.mem.copyForwards(f32, out.y[duplicate .. out.points - 1], out.y[duplicate + 1 .. out.points]);
                out.points -= 1;
                for (contour_first..out.contours - 1) |k| out.end[k] += last_size - 1;
                out.contours -= 1;
            }
        }
    }
}

/// Common dash + stroke sequence. It uses the same exposed operations and caller scratch;
/// the dash cap is independent from the authored path's ordinary cap.
pub fn strokeDashed(src: *const Polyline, style: paths.Stroke, dashes: DashStyle, tolerance: f32, scratch: *Polyline, out: *Polyline) Error!void {
    if (!std.math.isFinite(style.width) or style.width < 0 or !std.math.isFinite(tolerance) or tolerance <= 0) return error.InvalidStroke;
    try dash(src, dashes.array, dashes.offset, scratch);
    var stroked = style;
    stroked.cap = dashes.cap;
    const required = paths.strokeLen(scratch, stroked, tolerance);
    try polylineRoom(out, .{ .points = simd.rows(required.points), .contours = required.contours });
    paths.stroke(scratch, stroked, tolerance, out);
}

fn tangent(a: [2]f32, b: [2]f32, fallback: [2]f32) [2]f32 {
    return if (a[0] != b[0] or a[1] != b[1]) unit(.{ b[0] - a[0], b[1] - a[1] }) else fallback;
}
fn joinTangent(a: [2]f32, b: [2]f32) [2]f32 {
    const sum = [2]f32{ a[0] + b[0], a[1] + b[1] };
    return if (@abs(sum[0]) + @abs(sum[1]) > 1e-6) unit(sum) else .{ -a[1], a[0] };
}

/// Markers occur at authored path vertices, not at the flattening tessellation vertices.
/// Curves use endpoint derivatives, falling back to farther control/end points for zero tangents.
pub fn markers(path: *const Path, out: []Marker) Error![]Marker {
    if (out.len < 2 * @as(usize, path.verbs) + 1) return error.InsufficientStorage;
    var count: usize = 0;
    var at: usize = 0;
    var current: [2]f32 = .{ 0, 0 };
    var start: [2]f32 = .{ 0, 0 };
    var open = false;
    for (path.verb[0..path.verbs]) |verb| {
        if (verb == .move) {
            if (open and count > 0) out[count - 1].kind = .end;
            current = .{ path.x[at], path.y[at] };
            start = current;
            at += 1;
            out[count] = .{ .position = current, .tangent = .{ 1, 0 }, .kind = .start };
            count += 1;
            open = true;
            continue;
        }
        if (!open) {
            if (count == 0) return error.InvalidPath;
            out[count] = .{ .position = current, .tangent = .{ 1, 0 }, .kind = .start };
            count += 1;
            open = true;
        }
        const used: usize = switch (verb) {
            .move, .line => 1,
            .quad => 2,
            .cubic => 3,
            .close => 0,
        };
        const endpoint: [2]f32 = if (verb == .close) start else .{ path.x[at + used - 1], path.y[at + used - 1] };
        var outgoing = tangent(current, endpoint, .{ 1, 0 });
        var incoming = outgoing;
        if (verb == .quad or verb == .cubic) {
            const first_control = [2]f32{ path.x[at], path.y[at] };
            const last_control = [2]f32{ path.x[at + used - 2], path.y[at + used - 2] };
            outgoing = tangent(current, first_control, tangent(current, last_control, outgoing));
            incoming = tangent(last_control, endpoint, tangent(first_control, endpoint, incoming));
        }
        if (out[count - 1].kind == .start) out[count - 1].tangent = outgoing else out[count - 1].tangent = joinTangent(out[count - 1].tangent, outgoing);
        out[count] = .{ .position = endpoint, .tangent = incoming, .kind = if (verb == .close) .end else .mid };
        count += 1;
        current = endpoint;
        at += used;
        if (verb == .close) open = false;
    }
    if (open and count > 0) out[count - 1].kind = .end;
    return out[0..count];
}

pub fn markerTransform(marker: Marker, options: MarkerOptions) Error![6]f32 {
    if (!finite2(marker.position) or !finite2(marker.tangent) or !finite2(options.size) or !finite2(options.reference) or !std.math.isFinite(options.stroke_width) or options.stroke_width < 0 or !std.math.isFinite(options.device_scale) or options.device_scale <= 0) return error.InvalidGeometry;
    var radians = std.math.atan2(marker.tangent[1], marker.tangent[0]);
    switch (options.orient) {
        .auto => {},
        .auto_start_reverse => if (marker.kind == .start) {
            radians += std.math.pi;
        },
        .angle => |a| {
            if (!std.math.isFinite(a)) return error.InvalidGeometry;
            radians = a;
        },
    }
    const factor: f32 = switch (options.units) {
        .user => 1,
        .stroke_width => options.stroke_width,
        .device => 1 / options.device_scale,
    };
    const sx = factor * options.size[0];
    const sy = factor * options.size[1];
    const a = @cos(radians) * sx;
    const b = @sin(radians) * sx;
    const c = -@sin(radians) * sy;
    const d = @cos(radians) * sy;
    return .{ a, b, c, d, marker.position[0] - a * options.reference[0] - c * options.reference[1], marker.position[1] - b * options.reference[0] - d * options.reference[1] };
}

/// Existing paths.coverage output, interpreted in its raster coordinate space. `scale` says
/// how many coverage pixels form one logical pixel, keeping brush geometry in logical space.
pub const Coverage = struct { bytes: []const u8, box: paths.Box, scale: f32 = 1 };

fn coverageAt(coverage: Coverage, x: F, y: F) F {
    const px = @floor(x * simd.f(coverage.scale) - simd.f(@floatFromInt(coverage.box.x)));
    const py = @floor(y * simd.f(coverage.scale) - simd.f(@floatFromInt(coverage.box.y)));
    const valid = (px >= simd.f(0)) & (py >= simd.f(0)) & (px < simd.f(@floatFromInt(coverage.box.w))) & (py < simd.f(@floatFromInt(coverage.box.h)));
    const ix: simd.U = @intFromFloat(@min(@max(px, simd.f(0)), simd.f(@floatFromInt(coverage.box.w - 1))));
    const iy: simd.U = @intFromFloat(@min(@max(py, simd.f(0)), simd.f(@floatFromInt(coverage.box.h - 1))));
    var bytes: simd.U = undefined;
    inline for (0..simd.lanes) |lane| bytes[lane] = coverage.bytes[@as(usize, iy[lane]) * coverage.box.w + ix[lane]];
    return @as(F, @floatFromInt(@select(u32, valid, bytes, simd.u(0)))) / simd.f(255);
}

/// Paints path fill/stroke coverage using any rich gradient/image/solid brush. This consumes
/// the existing rasterizer's actual mask; no replacement fill-rule or stroke engine is used.
pub fn paintCoverage(dst: surface.Surface, coverage: Coverage, brush: brushes.Brush, view: decoration.View, opacity: f32) Error!void {
    return paintCoverageTransformed(dst, coverage, brush, .{ 1, 0, 0, 1, 0, 0 }, view, opacity);
}

/// The inverse maps logical painting coordinates into the brush coordinate system. Keeping
/// it separate preserves the gradient normals under skew and nonuniform scale.
pub fn paintCoverageTransformed(dst: surface.Surface, coverage: Coverage, brush: brushes.Brush, inverse: [6]f32, view: decoration.View, opacity: f32) Error!void {
    try dst.validate();
    try validateMatrix(inverse);
    try brushes.validateSource(brush, dst.pixels);
    try decoration.validateClipSources(dst.pixels, view.clips);
    if (coverage.box.w == 0 or coverage.box.h == 0) return;
    if (!std.math.isFinite(coverage.scale) or coverage.scale <= 0 or !std.math.isFinite(view.scale) or view.scale <= 0 or !std.math.isFinite(opacity) or opacity < 0 or opacity > 1) return error.InvalidGeometry;
    const count = std.math.mul(usize, coverage.box.w, coverage.box.h) catch return error.InvalidSize;
    if (coverage.bytes.len < count) return error.InsufficientStorage;
    if (surface.overlapsBytes(std.mem.sliceAsBytes(dst.pixels), coverage.bytes)) return error.AliasedStorage;
    const grid: usize = switch (view.quality) {
        .one => 1,
        .four => 2,
        .sixteen => 4,
    };
    for (0..dst.height) |y| {
        const yy = simd.f(view.origin[1] + (@as(f32, @floatFromInt(y)) + 0.5) / view.scale);
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx = simd.f(view.origin[0]) + (@as(F, @floatFromInt(simd.iota + simd.u(@intCast(x)))) + simd.f(0.5)) / simd.f(view.scale);
            var mask = simd.f(0);
            for (0..grid) |sy| for (0..grid) |sx| {
                const px = xx + simd.f(((@as(f32, @floatFromInt(sx)) + 0.5) / @as(f32, @floatFromInt(grid)) - 0.5) / view.scale);
                const py = yy + simd.f(((@as(f32, @floatFromInt(sy)) + 0.5) / @as(f32, @floatFromInt(grid)) - 0.5) / view.scale);
                mask += coverageAt(coverage, px, py) * decoration.clipCoverage(view.clips, px, py);
            };
            mask *= simd.f(opacity / @as(f32, @floatFromInt(grid * grid)));
            const sample_point = decoration.transformed(inverse, xx, yy);
            surface.store(dst, x, y, compositor.combine(surface.load(dst, x, y), brushes.sample(brush, sample_point[0], sample_point[1]), mask, .source_over, .normal));
        }
    }
}

const testing = std.testing;

test "elliptical arc construction reaches endpoints and radius correction stays finite" {
    var buffers: paths.TestBuffers(16, 1024) = .{};
    var path = buffers.path();
    path.moveTo(0, 0);
    try arcTo(&path, .{ 0, 0 }, .{ 20, 0 }, .{ .radius = .{ 2, 1 }, .rotation_degrees = 30, .sweep = true });
    try testing.expect(path.verbs >= 3);
    try testing.expectEqual(@as(f32, 20), path.x[path.points - 1]);
    try testing.expectEqual(@as(f32, 0), path.y[path.points - 1]);
    var poly = buffers.polyline();
    paths.flatten(&path, 0.05, &poly);
    try validatePolyline(&poly);
    try testing.expect(paths.bounds(&poly).w >= 20);
}

test "dash phase crosses vertices and joins ink across the closed seam" {
    var source: paths.TestBuffers(8, 64) = .{};
    var path = source.path();
    path.moveTo(0, 0);
    path.lineTo(10, 0);
    path.lineTo(10, 10);
    path.lineTo(0, 10);
    path.close();
    var poly = source.polyline();
    paths.flatten(&path, 0.1, &poly);
    var output: paths.TestBuffers(64, 512) = .{};
    var dashed = output.polyline();
    try dash(&poly, &.{ 8, 4 }, 2, &dashed);
    try testing.expect(dashed.contours >= 3);
    // Joined seam contains the original first vertex internally, so stroke can make a join.
    var internal_seam = false;
    for (1..dashed.end[0] - 1) |i| internal_seam = internal_seam or (dashed.x[i] == 0 and dashed.y[i] == 0);
    try testing.expect(internal_seam);
    try testing.expectError(error.InvalidDash, dash(&poly, &.{ 0, 0 }, 0, &dashed));
}

test "non scaling device stroke retains pixel width under skew and scale" {
    var source: paths.TestBuffers(4, 64) = .{};
    var path = source.path();
    path.moveTo(0, 0);
    path.lineTo(10, 0);
    var poly = source.polyline();
    paths.flatten(&path, 0.1, &poly);
    var scratch_buffers: paths.TestBuffers(16, 128) = .{};
    var output: paths.TestBuffers(64, 512) = .{};
    var scratch = scratch_buffers.polyline();
    var outline = output.polyline();
    try strokeTransformed(&poly, .{ .width = 4 }, .{ 3, 0, 1, 5, 0, 0 }, .device, 2, 0.1, &scratch, &outline);
    try testing.expectEqual(@as(u32, 2), paths.bounds(&outline).h);
    try testing.expectEqual(@as(u32, 30), paths.bounds(&outline).w);
}

test "width-aware curves feed a rendered tapered outline" {
    var source: paths.TestBuffers(8, 256) = .{};
    var path = source.path();
    path.moveTo(5, 5);
    path.quadTo(10, 5, 15, 5);
    var flat = source.polyline();
    var widths: [256]f32 = undefined;
    paths.flattenWidths(&path, &.{ 2, 8 }, 0.1, &flat, &widths);
    try testing.expectEqual(@as(f32, 2), widths[0]);
    try testing.expectEqual(@as(f32, 8), widths[flat.points - 1]);
    var output: paths.TestBuffers(64, 2048) = .{};
    var outline = output.polyline();
    try variableStroke(&flat, &widths, 0.1, &outline);
    const box = paths.bounds(&outline);
    try testing.expectEqual(@as(i32, 1), box.y);
    try testing.expectEqual(@as(u32, 8), box.h);
    var acc: [2048]f32 = undefined;
    var coverage: [2048]u8 = undefined;
    paths.fill(&outline, box, .nonzero, output.scratch(), &acc);
    paths.coverage(&acc, &coverage, @as(usize, box.w) * box.h);
    try testing.expect(coverage[@as(usize, @intCast(5 - box.y)) * box.w + @as(usize, @intCast(15 - box.x))] > 240);
}

test "path markers use curve derivatives and caller chosen units" {
    var source: paths.TestBuffers(8, 256) = .{};
    var path = source.path();
    path.moveTo(0, 0);
    path.cubicTo(0, 5, 10, 5, 10, 0);
    path.lineTo(20, 0);
    var marker_rows: [9]Marker = undefined;
    const sites = try markers(&path, &marker_rows);
    try testing.expectEqual(@as(usize, 3), sites.len);
    try testing.expectEqual([2]f32{ 0, 1 }, sites[0].tangent);
    const placement = try markerTransform(sites[2], .{ .units = .stroke_width, .stroke_width = 2, .reference = .{ 1, 0 } });
    try testing.expectEqual(@as(f32, 18), placement[4]);
}

test "path coverage consumes the gradient brush" {
    var storage: [simd.rows(4)]u32 = undefined;
    const target = try surface.init(&storage, 4, 1);
    var stop_storage: [2]brushes.Segment = undefined;
    const ramp = try brushes.prepareStops(&.{ .{ .position = 0, .color = .{ 1, 0, 0, 1 } }, .{ .position = 1, .color = .{ 0, 0, 1, 1 } } }, &stop_storage, .{}, .pad);
    try paintCoverage(target, .{ .bytes = &.{ 0, 255, 255, 0 }, .box = .{ .w = 4, .h = 1 } }, .{ .linear = .{ .ramp = ramp, .from = .{ 0, 0 }, .to = .{ 4, 0 } } }, .{}, 1);
    try testing.expectEqual(@as(u32, 0), target.pixels[0]);
    try testing.expect(target.pixels[1] != target.pixels[2]);
    try testing.expectEqual(@as(u32, 255), target.pixels[1] >> 24);
}
