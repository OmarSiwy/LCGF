//! Optional perspective flattening on caller-owned surfaces. A 3D-transformed plane becomes
//! a homography, sampled into a prepared texture for the ordinary quad backends. This is a
//! real projective raster path, not a promise that stock quads have a depth buffer or a 3D scene.
//! The caller orders flattened planes and decides whether to cull their reverse faces.

const std = @import("std");
const simd = @import("../core/simd.zig");
const surface = @import("surface.zig");
const brushes = @import("brushes.zig");
const compositor = @import("compositor.zig");
const decoration = @import("decoration.zig");
const Rect = @import("../core/types.zig").Rect;
const F = simd.F;

pub const Error = decoration.Error || error{ SingularProjection, CrossesProjectionPlane, InvalidOpacity };
/// Row-major matrices multiplying a column vector. 3x3 acts on (x,y,1), 4x4 on (x,y,z,1).
pub const Matrix = [9]f32;
pub const Matrix4 = [16]f32;
pub const identity: Matrix = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
pub const identity4: Matrix4 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
pub const Cull = enum { none, back, front };
pub const Options = struct { sampling: brushes.Sampling = .linear, cull: Cull = .none, opacity: f32 = 1, operator: compositor.Operator = .source_over, blend: compositor.Blend = .normal };
pub const Projection = struct { forward: Matrix, inverse: Matrix };

pub fn affine(m: [6]f32) Matrix {
    return .{ m[0], m[2], m[4], m[1], m[3], m[5], 0, 0, 1 };
}

pub fn plane(matrix: Matrix4) Matrix {
    return .{ matrix[0], matrix[1], matrix[3], matrix[4], matrix[5], matrix[7], matrix[12], matrix[13], matrix[15] };
}

pub fn multiply(a: Matrix4, b: Matrix4) Matrix4 {
    var out: Matrix4 = @splat(0);
    inline for (0..4) |r| inline for (0..4) |c| inline for (0..4) |k| {
        out[r * 4 + c] += a[r * 4 + k] * b[k * 4 + c];
    };
    return out;
}

pub fn translate(x: f32, y: f32, z: f32) Matrix4 {
    var out = identity4;
    out[3] = x;
    out[7] = y;
    out[11] = z;
    return out;
}

pub fn scale(x: f32, y: f32, z: f32) Matrix4 {
    var out = identity4;
    out[0] = x;
    out[5] = y;
    out[10] = z;
    return out;
}

pub fn rotateX(radians: f32) Matrix4 {
    const c = @cos(radians);
    const s = @sin(radians);
    return .{ 1, 0, 0, 0, 0, c, -s, 0, 0, s, c, 0, 0, 0, 0, 1 };
}
pub fn rotateY(radians: f32) Matrix4 {
    const c = @cos(radians);
    const s = @sin(radians);
    return .{ c, 0, s, 0, 0, 1, 0, 0, -s, 0, c, 0, 0, 0, 0, 1 };
}
pub fn rotateZ(radians: f32) Matrix4 {
    const c = @cos(radians);
    const s = @sin(radians);
    return .{ c, -s, 0, 0, s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
}

/// Perspective with w=1-z/distance, matching the usual positive-z-toward-viewer convention.
pub fn perspective(distance: f32) Error!Matrix4 {
    if (!std.math.isFinite(distance) or distance <= 0) return error.InvalidTransform;
    var out = identity4;
    out[14] = -1 / distance;
    return out;
}

pub fn around(origin: [3]f32, matrix: Matrix4) Matrix4 {
    return multiply(translate(origin[0], origin[1], origin[2]), multiply(matrix, translate(-origin[0], -origin[1], -origin[2])));
}

pub fn prepare(matrix: Matrix) Error!Projection {
    for (matrix) |v| if (!std.math.isFinite(v)) return error.InvalidTransform;
    const a = matrix;
    const adj: Matrix = .{
        a[4] * a[8] - a[5] * a[7], a[2] * a[7] - a[1] * a[8], a[1] * a[5] - a[2] * a[4],
        a[5] * a[6] - a[3] * a[8], a[0] * a[8] - a[2] * a[6], a[2] * a[3] - a[0] * a[5],
        a[3] * a[7] - a[4] * a[6], a[1] * a[6] - a[0] * a[7], a[0] * a[4] - a[1] * a[3],
    };
    const determinant = a[0] * adj[0] + a[1] * adj[3] + a[2] * adj[6];
    if (!std.math.isFinite(determinant) or @abs(determinant) < 1e-20) return error.SingularProjection;
    var inverse: Matrix = undefined;
    for (&inverse, adj) |*v, coefficient| {
        v.* = coefficient / determinant;
        if (!std.math.isFinite(v.*)) return error.SingularProjection;
    }
    return .{ .forward = matrix, .inverse = inverse };
}

pub fn point(matrix: Matrix, x: f32, y: f32) Error![2]f32 {
    const w = matrix[6] * x + matrix[7] * y + matrix[8];
    if (!std.math.isFinite(w) or w <= 1e-6) return error.CrossesProjectionPlane;
    const result = [2]f32{ (matrix[0] * x + matrix[1] * y + matrix[2]) / w, (matrix[3] * x + matrix[4] * y + matrix[5]) / w };
    if (!std.math.isFinite(result[0]) or !std.math.isFinite(result[1])) return error.InvalidTransform;
    return result;
}

/// A rectangle crossing w=0 has unbounded projected extent. Return an explicit error so the
/// caller can clip its 3D geometry first; neither a huge allocation nor silent flattening occurs.
pub fn bounds(rect: Rect, matrix: Matrix) Error!Rect {
    if (!brushes.validRect(rect)) return error.InvalidGeometry;
    const corners = [4][2]f32{ try point(matrix, rect.x0, rect.y0), try point(matrix, rect.x1, rect.y0), try point(matrix, rect.x1, rect.y1), try point(matrix, rect.x0, rect.y1) };
    var out: Rect = .{ .x0 = corners[0][0], .y0 = corners[0][1], .x1 = corners[0][0], .y1 = corners[0][1] };
    for (corners[1..]) |c| {
        out.x0 = @min(out.x0, c[0]);
        out.y0 = @min(out.y0, c[1]);
        out.x1 = @max(out.x1, c[0]);
        out.y1 = @max(out.y1, c[1]);
    }
    return out;
}

pub fn backFacing(rect: Rect, matrix: Matrix) Error!bool {
    const a = try point(matrix, rect.x0, rect.y0);
    const b = try point(matrix, rect.x1, rect.y0);
    const c = try point(matrix, rect.x0, rect.y1);
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]) < 0;
}

/// Samples a source image plane into an existing effect surface. The forward matrix maps
/// source pixel coordinates to logical destination coordinates. View sampling and clips use
/// the same coordinates as decoration; the inverse homography gives perspective-correct UVs.
pub fn paint(dst: surface.Surface, src: surface.Image, projection: Projection, view: decoration.View, options: Options) Error!void {
    try dst.validate();
    try src.validate();
    if (!std.math.isFinite(view.scale) or view.scale <= 0 or !std.math.isFinite(view.origin[0]) or !std.math.isFinite(view.origin[1])) return error.InvalidScale;
    try decoration.validateClipSources(dst.pixels, view.clips);
    if (!std.math.isFinite(options.opacity) or options.opacity < 0 or options.opacity > 1) return error.InvalidOpacity;
    if (surface.overlaps(dst.pixels, src.pixels)) return error.AliasedStorage;
    // Recheck public plain data, so constructing Projection directly cannot smuggle NaNs into
    // float-to-index conversions. `prepare` is a convenience, not a hidden resource registration.
    _ = try prepare(projection.forward);
    for (projection.inverse) |v| if (!std.math.isFinite(v)) return error.InvalidTransform;
    const source_rect: Rect = .{ .x1 = @floatFromInt(src.width), .y1 = @floatFromInt(src.height) };
    _ = try bounds(source_rect, projection.forward);
    const reverse = try backFacing(source_rect, projection.forward);
    if ((options.cull == .back and reverse) or (options.cull == .front and !reverse)) return;
    const grid: usize = switch (view.quality) {
        .one => 1,
        .four => 2,
        .sixteen => 4,
    };
    const step = 1 / (@as(f32, @floatFromInt(grid)) * view.scale);
    const m = projection.inverse;
    for (0..dst.height) |y| {
        const yy = simd.f(view.origin[1] + @as(f32, @floatFromInt(y)) / view.scale);
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx = simd.f(view.origin[0]) + @as(F, @floatFromInt(simd.iota + simd.u(@intCast(x)))) / simd.f(view.scale);
            var sum: surface.Batch = @splat(simd.f(0));
            for (0..grid) |sy| for (0..grid) |sx| {
                const px = xx + simd.f((@as(f32, @floatFromInt(sx)) + 0.5) * step);
                const py = yy + simd.f((@as(f32, @floatFromInt(sy)) + 0.5) * step);
                const w = simd.f(m[6]) * px + simd.f(m[7]) * py + simd.f(m[8]);
                const divisor = @select(f32, @abs(w) > simd.f(1e-6), w, simd.f(1));
                const u = (simd.f(m[0]) * px + simd.f(m[1]) * py + simd.f(m[2])) / divisor;
                const v = (simd.f(m[3]) * px + simd.f(m[4]) * py + simd.f(m[5])) / divisor;
                const visible = (w > simd.f(1e-6)) & (u >= simd.f(0)) & (u < simd.f(@floatFromInt(src.width))) & (v >= simd.f(0)) & (v < simd.f(@floatFromInt(src.height)));
                const sampled = brushes.sampleImage(src, @select(f32, visible, u, simd.f(0)), @select(f32, visible, v, simd.f(0)), options.sampling, .{ .clamp, .clamp });
                const coverage = @as(F, @floatFromInt(@intFromBool(visible))) * decoration.clipCoverage(view.clips, px, py);
                inline for (0..4) |k| sum[k] += sampled[k] * coverage;
            };
            inline for (0..4) |k| sum[k] /= simd.f(@floatFromInt(grid * grid));
            surface.store(dst, x, y, compositor.combine(surface.load(dst, x, y), sum, simd.f(options.opacity), options.operator, options.blend));
        }
    }
}

const testing = std.testing;

test "projective raster samples non-affine UVs through the ordinary surface path" {
    const pixels = [_]u32{ 0xff0000ff, 0xff00ff00, 0xffff0000, 0xffffffff };
    const image: surface.Image = .{ .pixels = &pixels, .width = 2, .height = 2, .stride = 2 };
    const matrix: Matrix = .{ 4, 0, 1, 0, 4, 1, 0.25, 0, 1 };
    const projection = try prepare(matrix);
    const extent = try bounds(.{ .x1 = 2, .y1 = 2 }, matrix);
    try testing.expectApproxEqAbs(@as(f32, 6), extent.x1, 0.00001);
    var storage: [simd.rows(10) * 10]u32 = undefined;
    const dst = try surface.init(&storage, 10, 10);
    try paint(dst, image, projection, .{ .quality = .one }, .{ .sampling = .nearest });
    try testing.expectEqual(@as(u32, 0xff0000ff), dst.pixels[2 * dst.stride + 2]);
    try testing.expectEqual(@as(u32, 0xff00ff00), dst.pixels[2 * dst.stride + 5]);
    try testing.expectEqual(@as(u32, 0), dst.pixels[9 * dst.stride + 9]);
}

test "3D origin rotation perspective and backface choices remain explicit" {
    const rotation = around(.{ 2, 2, 0 }, rotateY(std.math.pi));
    const transform = multiply(try perspective(100), multiply(translate(1, 0, 10), rotation));
    const projected = plane(transform);
    _ = try prepare(projected);
    try testing.expect(try backFacing(.{ .x1 = 4, .y1 = 4 }, projected));
    const crossing: Matrix = .{ 1, 0, 0, 0, 1, 0, -1, 0, 1 };
    try testing.expectError(error.CrossesProjectionPlane, bounds(.{ .x1 = 2, .y1 = 2 }, crossing));
    try testing.expectError(error.SingularProjection, prepare(@splat(0)));
}
