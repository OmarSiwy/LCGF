//! Composed decoration rasterization into caller-owned RGBA8 surfaces. A solid primitive can
//! still use the existing compact Quad directly. Rich paint uses the same textures on all stock
//! renderers after `surface.exportRGBA(..., .straight)`; the Quad ABI does not grow.
//!
//! Coordinates are logical pixels. Corner order is TL, TR, BR, BL; edge order is left, top,
//! right, bottom. Backgrounds and shadows are supplied back-to-front. Borders and outlines are
//! independent paint, so keyboard focus does not replace a selected control's border.

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const color = @import("color_math.zig");
const surface = @import("surface.zig");
const brushes = @import("brushes.zig");
const compositor = @import("compositor.zig");
const paths = @import("paths.zig");
const F = simd.F;
const Rect = types.Rect;
const identity = [6]f32{ 1, 0, 0, 1, 0, 0 };

pub const Error = brushes.Error || error{ InvalidDecoration, InvalidTransform, InvalidScale };
pub const Corner = enum { round, square, bevel, scoop, notch, squircle, superellipse };
pub const RoundedRect = struct {
    rect: Rect,
    radii: [4][2]f32 = @splat(.{ 0, 0 }),
    corners: [4]Corner = @splat(.round),
    /// Used only by `.superellipse`. Positive exponents describe convex power curves;
    /// values below one are concave. `round` and `squircle` specialize powers two and four.
    powers: [4]f32 = @splat(2),
};

pub const RoundedClip = struct { shape: RoundedRect, inverse: [6]f32 = identity };
pub const CoverageClip = struct {
    image: surface.Image,
    /// Maps logical paint coordinates to image pixel coordinates, whose centers are i+.5.
    inverse: [6]f32 = identity,
    sampling: brushes.Sampling = .linear,
    mode: compositor.MaskMode = .alpha,
    invert: bool = false,
};
pub const Clip = union(enum) { rounded: RoundedClip, coverage: CoverageClip };
pub const Quality = enum { one, four, sixteen };
pub const View = struct { origin: [2]f32 = .{ 0, 0 }, scale: f32 = 1, quality: Quality = .four, clips: []const Clip = &.{} };
pub const Box = enum { border, padding, content };
pub const Alignment = enum { inside, center, outside };
pub const BorderStyle = enum { none, solid, dashed, dotted, double, groove, ridge, inset, outset };

pub const Layer = struct {
    brush: brushes.Brush,
    clip: Box = .border,
    inverse: [6]f32 = identity,
    opacity: f32 = 1,
    blend: compositor.Blend = .normal,
    operator: compositor.Operator = .source_over,
};
pub const Edge = struct {
    width: f32 = 0,
    brush: brushes.Brush = .{ .solid = .{ 0, 0, 0, 0 } },
    style: BorderStyle = .solid,
    /// Dash and gap lengths in logical pixels. Zero selects 3*width for dashes and width
    /// for dotted gaps. Phase is distance along the clockwise rounded-rectangle centerline.
    dash: f32 = 0,
    gap: f32 = 0,
    phase: f32 = 0,
};
pub const Border = struct { edges: [4]Edge = @splat(.{}), alignment: Alignment = .inside };
pub const Outline = struct { width: f32, offset: f32 = 0, brush: brushes.Brush, style: BorderStyle = .solid, dash: f32 = 0, gap: f32 = 0, phase: f32 = 0 };
pub const Shadow = struct {
    offset: [2]f32 = .{ 0, 0 },
    sigma: f32 = 0,
    spread: f32 = 0,
    color: color.Rgba = .{ 0, 0, 0, 0.3 },
    inset: bool = false,
};
pub const Description = struct {
    backgrounds: []const Layer = &.{},
    border: ?Border = null,
    shadows: []const Shadow = &.{},
    outline: ?Outline = null,
    /// Insets between the padding and content boxes. Border widths are taken from `border`.
    padding: [4]f32 = @splat(0),
};
pub const Dimensions = struct { width: u32, height: u32, origin: [2]f32, rect: Rect };

fn finiteRect(r: Rect) bool {
    return std.math.isFinite(r.x0) and std.math.isFinite(r.y0) and std.math.isFinite(r.x1) and std.math.isFinite(r.y1) and r.x1 >= r.x0 and r.y1 >= r.y0;
}

/// CSS-style proportional radius normalization: when sums overlap, every radius is scaled
/// by one common factor. This preserves corner proportions instead of clamping independently.
pub fn normalize(shape: RoundedRect) Error!RoundedRect {
    if (!finiteRect(shape.rect)) return error.InvalidGeometry;
    for (shape.radii) |r| if (!std.math.isFinite(r[0]) or !std.math.isFinite(r[1]) or r[0] < 0 or r[1] < 0) return error.InvalidGeometry;
    for (shape.powers) |p| if (!std.math.isFinite(p) or p <= 0) return error.InvalidGeometry;
    const r = shape.radii;
    const w = shape.rect.w();
    const h = shape.rect.h();
    const scale = @min(@min(@min(w / @max(r[0][0] + r[1][0], 1e-20), w / @max(r[3][0] + r[2][0], 1e-20)), @min(h / @max(r[0][1] + r[3][1], 1e-20), h / @max(r[1][1] + r[2][1], 1e-20))), 1);
    var out = shape;
    for (&out.radii) |*radius| radius.* = .{ radius[0] * scale, radius[1] * scale };
    return out;
}

fn insetShape(shape: RoundedRect, edges: [4]f32) RoundedRect {
    const r = shape.rect;
    const x0 = r.x0 + edges[0];
    const y0 = r.y0 + edges[1];
    const x1 = r.x1 - edges[2];
    const y1 = r.y1 - edges[3];
    var out = shape;
    out.rect = .{ .x0 = @min(x0, (x0 + x1) * 0.5), .y0 = @min(y0, (y0 + y1) * 0.5), .x1 = @max(x1, (x0 + x1) * 0.5), .y1 = @max(y1, (y0 + y1) * 0.5) };
    const horizontal = [4]usize{ 0, 2, 2, 0 };
    const vertical = [4]usize{ 1, 1, 3, 3 };
    inline for (0..4) |k| out.radii[k] = .{ @max(shape.radii[k][0] - edges[horizontal[k]], 0), @max(shape.radii[k][1] - edges[vertical[k]], 0) };
    return normalize(out) catch unreachable;
}

fn offsetShape(shape: RoundedRect, offset: [2]f32) RoundedRect {
    var out = shape;
    out.rect.x0 += offset[0];
    out.rect.x1 += offset[0];
    out.rect.y0 += offset[1];
    out.rect.y1 += offset[1];
    return out;
}

inline fn power(v: F, exponent: f32) F {
    return @select(f32, v > simd.f(0), @exp(@log(@max(v, simd.f(1e-30))) * simd.f(exponent)), simd.f(0));
}

/// Boolean geometry at SIMD points. Antialiasing and clip intersection are handled together
/// by the caller, so two coincident rounded clips do not darken a shared edge twice.
pub fn contains(shape: RoundedRect, x: F, y: F) simd.B {
    const r = shape.rect;
    var inside = (x >= simd.f(r.x0)) & (x < simd.f(r.x1)) & (y >= simd.f(r.y0)) & (y < simd.f(r.y1));
    inline for (0..4) |k| {
        const left = k == 0 or k == 3;
        const top = k < 2;
        const rx = shape.radii[k][0];
        const ry = shape.radii[k][1];
        const cx = if (left) r.x0 + rx else r.x1 - rx;
        const cy = if (top) r.y0 + ry else r.y1 - ry;
        const dx = (if (left) simd.f(cx) - x else x - simd.f(cx)) / simd.f(@max(rx, 1e-20));
        const dy = (if (top) simd.f(cy) - y else y - simd.f(cy)) / simd.f(@max(ry, 1e-20));
        const corner_region = (dx > simd.f(0)) & (dy > simd.f(0));
        const nx = @min(@max(dx, simd.f(0)), simd.f(1));
        const ny = @min(@max(dy, simd.f(0)), simd.f(1));
        const corner_inside: simd.B = switch (shape.corners[k]) {
            .round => nx * nx + ny * ny <= simd.f(1),
            .square => @splat(true),
            .bevel => nx + ny <= simd.f(1),
            .scoop => (simd.f(1) - nx) * (simd.f(1) - nx) + (simd.f(1) - ny) * (simd.f(1) - ny) >= simd.f(1),
            .notch => @splat(false),
            .squircle => nx * nx * nx * nx + ny * ny * ny * ny <= simd.f(1),
            .superellipse => power(nx, shape.powers[k]) + power(ny, shape.powers[k]) <= simd.f(1),
        };
        inside &= !corner_region | corner_inside;
    }
    return inside;
}

fn validTransform(matrix: [6]f32) Error!void {
    for (matrix) |v| if (!std.math.isFinite(v)) return error.InvalidTransform;
    if (@abs(matrix[0] * matrix[3] - matrix[1] * matrix[2]) < 1e-20) return error.InvalidTransform;
}

pub fn validateClips(clips: []const Clip) Error!void {
    for (clips) |clip| switch (clip) {
        .rounded => |c| {
            _ = try normalize(c.shape);
            try validTransform(c.inverse);
        },
        .coverage => |c| {
            try c.image.validate();
            try validTransform(c.inverse);
        },
    };
}

pub fn validateClipSources(destination: []const u32, clips: []const Clip) Error!void {
    try validateClips(clips);
    for (clips) |clip| if (clip == .coverage and surface.overlaps(destination, clip.coverage.image.pixels)) return error.AliasedStorage;
}

/// Checks all borrowed paint/clip images before a clear or write. Applications that want a
/// feedback effect first capture the source into separate, caller-owned storage.
pub fn validateSources(destination: []const u32, description: Description, clips: []const Clip) Error!void {
    for (description.backgrounds) |layer| try brushes.validateSource(layer.brush, destination);
    if (description.border) |border| for (border.edges) |edge| try brushes.validateSource(edge.brush, destination);
    if (description.outline) |outline| try brushes.validateSource(outline.brush, destination);
    try validateClipSources(destination, clips);
}

pub inline fn transformed(matrix: [6]f32, x: F, y: F) [2]F {
    return .{ simd.f(matrix[0]) * x + simd.f(matrix[2]) * y + simd.f(matrix[4]), simd.f(matrix[1]) * x + simd.f(matrix[3]) * y + simd.f(matrix[5]) };
}

pub fn clipCoverage(clips: []const Clip, x: F, y: F) F {
    var result = simd.f(1);
    for (clips) |clip| switch (clip) {
        .rounded => |c| {
            const xy = transformed(c.inverse, x, y);
            const shape = normalize(c.shape) catch unreachable;
            result *= @as(F, @floatFromInt(@intFromBool(contains(shape, xy[0], xy[1]))));
        },
        .coverage => |c| {
            const xy = transformed(c.inverse, x, y);
            const coverage = compositor.maskCoverage(brushes.sampleImage(c.image, xy[0], xy[1], c.sampling, .{ .transparent, .transparent }), c.mode);
            result *= if (c.invert) simd.f(1) - coverage else coverage;
        },
    };
    return result;
}

/// Converts the existing path rasterizer's u8 output to a borrowed RGBA coverage clip. `box`
/// is the same paths.Box passed to paths.coverage; path coordinates are logical pixels, unless
/// the caller pre-scaled them, in which case pass that scale. No second path rasterizer exists.
pub fn pathClip(coverage: []const u8, box: paths.Box, scale: f32, rgba: []u32) Error!Clip {
    if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidScale;
    const count = std.math.mul(usize, box.w, box.h) catch return error.InvalidSize;
    if (box.w == 0 or box.h == 0) return error.InvalidSize;
    if (coverage.len < count or rgba.len < count) return error.InsufficientStorage;
    // This is a representation boundary, not a retained table; arbitrary caller byte lengths
    // need no padding. SIMD pixel passes start after this compact import.
    for (coverage[0..count], rgba[0..count]) |a, *out| out.* = @as(u32, a) * 0x01010101;
    return .{ .coverage = .{
        .image = .{ .pixels = rgba[0..count], .width = box.w, .height = box.h, .stride = box.w, .alpha = .premultiplied },
        .inverse = .{ scale, 0, 0, scale, -@as(f32, @floatFromInt(box.x)), -@as(f32, @floatFromInt(box.y)) },
    } };
}

fn validEdge(edge: Edge) Error!void {
    if (!std.math.isFinite(edge.width) or edge.width < 0 or !std.math.isFinite(edge.dash) or edge.dash < 0 or !std.math.isFinite(edge.gap) or edge.gap < 0 or !std.math.isFinite(edge.phase)) return error.InvalidDecoration;
    try brushes.validate(edge.brush);
}

pub fn validate(description: Description) Error!void {
    for (description.padding) |p| if (!std.math.isFinite(p) or p < 0) return error.InvalidDecoration;
    for (description.backgrounds) |layer| {
        try brushes.validate(layer.brush);
        try validTransform(layer.inverse);
        if (!std.math.isFinite(layer.opacity) or layer.opacity < 0 or layer.opacity > 1) return error.InvalidDecoration;
    }
    if (description.border) |border| for (border.edges) |edge| try validEdge(edge);
    if (description.outline) |outline| {
        try validEdge(.{ .width = outline.width, .brush = outline.brush, .style = outline.style, .dash = outline.dash, .gap = outline.gap, .phase = outline.phase });
        if (!std.math.isFinite(outline.offset)) return error.InvalidDecoration;
    }
    for (description.shadows) |s| {
        if (!std.math.isFinite(s.offset[0]) or !std.math.isFinite(s.offset[1]) or !std.math.isFinite(s.sigma) or s.sigma < 0 or !std.math.isFinite(s.spread)) return error.InvalidDecoration;
        if (!color.finite(s.color) or s.color[3] < 0 or s.color[3] > 1) return error.InvalidColor;
    }
}

fn edgeWidths(border: ?Border) [4]f32 {
    var widths: [4]f32 = @splat(0);
    if (border) |b| for (b.edges, 0..) |edge, k| {
        widths[k] = if (edge.style == .none) 0 else edge.width;
    };
    return widths;
}

fn borderOuter(shape: RoundedRect, border: Border) RoundedRect {
    const factor: f32 = switch (border.alignment) {
        .inside => 0,
        .center => -0.5,
        .outside => -1,
    };
    const w = edgeWidths(border);
    return insetShape(shape, .{ w[0] * factor, w[1] * factor, w[2] * factor, w[3] * factor });
}

/// Conservative logical paint bounds, including outward border, outline, and three-sigma
/// shadow halos. Clips can only reduce this result. Empty geometry remains empty.
pub fn bounds(shape: RoundedRect, description: Description) Error!Rect {
    const normalized = try normalize(shape);
    try validate(description);
    if (shape.rect.w() == 0 or shape.rect.h() == 0) return shape.rect;
    var result = normalized.rect;
    if (description.border) |border| result = borderOuter(normalized, border).rect;
    if (description.outline) |outline| {
        const expansion = @max(outline.offset + outline.width, 0);
        result = unionRect(result, insetShape(normalized, @splat(-expansion)).rect);
    }
    for (description.shadows) |s| {
        if (s.inset) continue;
        const shadow_shape = offsetShape(insetShape(normalized, @splat(-s.spread)), s.offset);
        result = unionRect(result, insetShape(shadow_shape, @splat(-3 * s.sigma)).rect);
    }
    return result;
}

fn unionRect(a: Rect, b: Rect) Rect {
    return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
}

/// Device-pixel alignment is outward and includes fractional origins. The returned rect is
/// the texture quad's logical rectangle; retain it with the pixels to avoid placement drift.
pub fn dimensions(rect: Rect, scale: f32) Error!Dimensions {
    if (!finiteRect(rect)) return error.InvalidGeometry;
    if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidScale;
    const x0 = @floor(rect.x0 * scale);
    const y0 = @floor(rect.y0 * scale);
    const x1 = @ceil(rect.x1 * scale);
    const y1 = @ceil(rect.y1 * scale);
    const width = x1 - x0;
    const height = y1 - y0;
    if (!std.math.isFinite(width) or !std.math.isFinite(height) or width >= 4_294_967_296.0 or height >= 4_294_967_296.0) return error.InvalidSize;
    return .{ .width = @intFromFloat(width), .height = @intFromFloat(height), .origin = .{ x0 / scale, y0 / scale }, .rect = .{ .x0 = x0 / scale, .y0 = y0 / scale, .x1 = x1 / scale, .y1 = y1 / scale } };
}

fn validateView(view: View) Error!void {
    if (!std.math.isFinite(view.origin[0]) or !std.math.isFinite(view.origin[1]) or !std.math.isFinite(view.scale) or view.scale <= 0) return error.InvalidScale;
    try validateClips(view.clips);
}

fn sampleCount(quality: Quality) usize {
    return switch (quality) {
        .one => 1,
        .four => 2,
        .sixteen => 4,
    };
}

fn shapeCoverage(shape: RoundedRect, inner: ?RoundedRect, view: View, x: F, y: F) F {
    const count = sampleCount(view.quality);
    const step = 1 / (@as(f32, @floatFromInt(count)) * view.scale);
    var sum = simd.f(0);
    for (0..count) |sy| for (0..count) |sx| {
        const xx = x + simd.f((@as(f32, @floatFromInt(sx)) + 0.5) * step);
        const yy = y + simd.f((@as(f32, @floatFromInt(sy)) + 0.5) * step);
        var included = contains(shape, xx, yy);
        if (inner) |hole| included &= !contains(hole, xx, yy);
        sum += @as(F, @floatFromInt(@intFromBool(included))) * clipCoverage(view.clips, xx, yy);
    };
    return sum / simd.f(@floatFromInt(count * count));
}

/// Low-level shape paint on an existing surface, also used by the full decoration helper.
/// Only `.border` is valid here: there is no padding/content box in this smaller operation.
pub fn paintShape(dst: surface.Surface, shape: RoundedRect, layer: Layer, view: View) Error!void {
    try dst.validate();
    const normalized = try normalize(shape);
    if (layer.clip != .border) return error.InvalidDecoration;
    try validate(.{ .backgrounds = &.{layer} });
    try validateView(view);
    try brushes.validateSource(layer.brush, dst.pixels);
    try validateClipSources(dst.pixels, view.clips);
    paintLayer(dst, normalized, null, layer, view);
}

fn paintLayer(dst: surface.Surface, shape: RoundedRect, inner: ?RoundedRect, layer: Layer, view: View) void {
    for (0..dst.height) |y| {
        const yy = simd.f(view.origin[1] + @as(f32, @floatFromInt(y)) / view.scale);
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx = simd.f(view.origin[0]) + @as(F, @floatFromInt(simd.iota + simd.u(@intCast(x)))) / simd.f(view.scale);
            const coverage = shapeCoverage(shape, inner, view, xx, yy);
            const sample_xy = transformed(layer.inverse, xx + simd.f(0.5 / view.scale), yy + simd.f(0.5 / view.scale));
            const source = brushes.sample(layer.brush, sample_xy[0], sample_xy[1]);
            surface.store(dst, x, y, compositor.combine(surface.load(dst, x, y), source, coverage * simd.f(layer.opacity), layer.operator, layer.blend));
        }
    }
}

inline fn erf(value: F) F {
    const x = @abs(value);
    const t = simd.f(1) / (simd.f(1) + simd.f(0.3275911) * x);
    const p = ((((simd.f(1.061405429) * t - simd.f(1.453152027)) * t + simd.f(1.421413741)) * t - simd.f(0.284496736)) * t + simd.f(0.254829592)) * t;
    const result = simd.f(1) - p * @exp(-x * x);
    return @select(f32, value < simd.f(0), -result, result);
}

/// Signed distance approximation used only by the inexpensive box shadow. Round ellipses
/// use the normalized-gradient distance; other corner contours use their implicit gradient.
/// For exact alpha-shaped Gaussian convolution use compositor.dropShadow with explicit scratch.
fn distance(shape: RoundedRect, x: F, y: F) F {
    const r = shape.rect;
    const dx = @max(simd.f(r.x0) - x, x - simd.f(r.x1));
    const dy = @max(simd.f(r.y0) - y, y - simd.f(r.y1));
    var result = @sqrt(@max(dx, simd.f(0)) * @max(dx, simd.f(0)) + @max(dy, simd.f(0)) * @max(dy, simd.f(0))) + @min(@max(dx, dy), simd.f(0));
    inline for (0..4) |k| {
        const rx = shape.radii[k][0];
        const ry = shape.radii[k][1];
        const left = k == 0 or k == 3;
        const top = k < 2;
        const cx = if (left) r.x0 + rx else r.x1 - rx;
        const cy = if (top) r.y0 + ry else r.y1 - ry;
        const px = if (left) simd.f(cx) - x else x - simd.f(cx);
        const py = if (top) simd.f(cy) - y else y - simd.f(cy);
        const nx = @max(px, simd.f(0)) / simd.f(@max(rx, 1e-20));
        const ny = @max(py, simd.f(0)) / simd.f(@max(ry, 1e-20));
        const ell = @sqrt(nx * nx + ny * ny);
        const grad = @sqrt(nx * nx / simd.f(@max(rx * rx, 1e-20)) + ny * ny / simd.f(@max(ry * ry, 1e-20)));
        const d = switch (shape.corners[k]) {
            .round => (ell - simd.f(1)) * ell / @max(grad, simd.f(1e-20)),
            .square => result,
            .bevel => blk: {
                const t = @min(@max(((simd.f(rx) - px) * simd.f(rx) + py * simd.f(ry)) / simd.f(@max(rx * rx + ry * ry, 1e-20)), simd.f(0)), simd.f(1));
                const ax = px - simd.f(rx) * (simd.f(1) - t);
                const ay = py - simd.f(ry) * t;
                const magnitude = @sqrt(ax * ax + ay * ay);
                break :blk @select(f32, nx + ny <= simd.f(1), -magnitude, magnitude);
            },
            .notch => blk: {
                const ax = px - @min(@max(px, simd.f(0)), simd.f(rx));
                const ay = py - @min(@max(py, simd.f(0)), simd.f(ry));
                break :blk @min(@sqrt(ax * ax + py * py), @sqrt(px * px + ay * ay));
            },
            .scoop => blk: {
                const qx = simd.f(1) - @min(nx, simd.f(1));
                const qy = simd.f(1) - @min(ny, simd.f(1));
                const length = @sqrt(qx * qx + qy * qy);
                const gradient = @sqrt(qx * qx / simd.f(@max(rx * rx, 1e-20)) + qy * qy / simd.f(@max(ry * ry, 1e-20)));
                const radius = @select(f32, length > simd.f(1e-10), length / @max(gradient, simd.f(1e-20)), simd.f(@min(rx, ry)));
                const ox = @max(px - simd.f(rx), simd.f(0));
                const oy = @max(py - simd.f(ry), simd.f(0));
                break :blk (simd.f(1) - length) * radius + @sqrt(ox * ox + oy * oy);
            },
            .squircle, .superellipse => blk: {
                const exponent: f32 = if (shape.corners[k] == .squircle) 4 else shape.powers[k];
                const implicit = power(nx, exponent) + power(ny, exponent) - simd.f(1);
                const gx = simd.f(exponent / @max(rx, 1e-20)) * power(@max(nx, simd.f(1e-10)), exponent - 1);
                const gy = simd.f(exponent / @max(ry, 1e-20)) * power(@max(ny, simd.f(1e-10)), exponent - 1);
                break :blk implicit / @max(@sqrt(gx * gx + gy * gy), simd.f(1e-20));
            },
        };
        const valid_corner = (px > simd.f(0)) & (py > simd.f(0)) & @as(simd.B, @splat(rx > 0 and ry > 0));
        result = @select(f32, valid_corner, d, result);
    }
    return result;
}

fn paintShadow(dst: surface.Surface, base: RoundedRect, shadow: Shadow, view: View) void {
    const shape = offsetShape(insetShape(base, @splat(if (shadow.inset) shadow.spread else -shadow.spread)), shadow.offset);
    const count = sampleCount(view.quality);
    const step = 1 / (@as(f32, @floatFromInt(count)) * view.scale);
    const brush = brushes.Brush{ .solid = shadow.color };
    for (0..dst.height) |y| {
        const yy = simd.f(view.origin[1] + @as(f32, @floatFromInt(y)) / view.scale);
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx = simd.f(view.origin[0]) + @as(F, @floatFromInt(simd.iota + simd.u(@intCast(x)))) / simd.f(view.scale);
            var sum = simd.f(0);
            for (0..count) |sy| for (0..count) |sx| {
                const px = xx + simd.f((@as(f32, @floatFromInt(sx)) + 0.5) * step);
                const py = yy + simd.f((@as(f32, @floatFromInt(sy)) + 0.5) * step);
                const base_inside = contains(base, px, py);
                const soft = if (shadow.sigma > 0) simd.f(0.5) * (simd.f(1) - erf(distance(shape, px, py) / simd.f(shadow.sigma * @sqrt(2.0)))) else @as(F, @floatFromInt(@intFromBool(contains(shape, px, py))));
                const allowed = if (shadow.inset) base_inside else !base_inside;
                const mask = if (shadow.inset) simd.f(1) - soft else soft;
                sum += @as(F, @floatFromInt(@intFromBool(allowed))) * mask * clipCoverage(view.clips, px, py);
            };
            const coverage = sum / simd.f(@floatFromInt(count * count));
            surface.store(dst, x, y, compositor.combine(surface.load(dst, x, y), brushes.sample(brush, xx, yy), coverage, .source_over, .normal));
        }
    }
}

const BorderPosition = struct { edge: simd.U, fraction: F };
fn borderPosition(outer: RoundedRect, widths: [4]f32, x: F, y: F) BorderPosition {
    const d = [4]F{ x - simd.f(outer.rect.x0), y - simd.f(outer.rect.y0), simd.f(outer.rect.x1) - x, simd.f(outer.rect.y1) - y };
    var edge = simd.u(0);
    var fraction = simd.f(std.math.floatMax(f32));
    inline for (0..4) |k| {
        const v = if (widths[k] > 0) d[k] / simd.f(widths[k]) else simd.f(std.math.floatMax(f32));
        const closer = v < fraction;
        edge = @select(u32, closer, simd.u(k), edge);
        fraction = @min(fraction, v);
    }
    return .{ .edge = edge, .fraction = fraction };
}

// Five-point Gaussian quadrature of an ellipse arc, vectorized over endpoint angles. Dash
// phase therefore continues through elliptical corners rather than restarting on each edge.
fn ellipseArc(rx: f32, ry: f32, theta: F) F {
    const nodes = [5]f32{ -0.9061798459, -0.5384693101, 0, 0.5384693101, 0.9061798459 };
    const weights = [5]f32{ 0.2369268851, 0.4786286705, 0.5688888889, 0.4786286705, 0.2369268851 };
    var sum = simd.f(0);
    inline for (0..5) |i| {
        const phi = theta * simd.f((nodes[i] + 1) * 0.5);
        const a = simd.f(rx) * @cos(phi);
        const b = simd.f(ry) * @sin(phi);
        sum += simd.f(weights[i]) * @sqrt(a * a + b * b);
    }
    return sum * theta * simd.f(0.5);
}

fn perimeter(shape: RoundedRect, owner: simd.U, x: F, y: F) F {
    const r = shape.rect;
    const radii = shape.radii;
    var arcs: [4]f32 = undefined;
    inline for (0..4) |k| arcs[k] = ellipseArc(radii[k][0], radii[k][1], simd.f(std.math.pi / 2.0))[0];
    const top = @max(r.w() - radii[0][0] - radii[1][0], 0);
    const right = @max(r.h() - radii[1][1] - radii[2][1], 0);
    const bottom = @max(r.w() - radii[2][0] - radii[3][0], 0);
    const left = @max(r.h() - radii[3][1] - radii[0][1], 0);
    const right_start = top + arcs[1];
    const bottom_start = right_start + right + arcs[2];
    const left_start = bottom_start + bottom + arcs[3];
    var result = @select(f32, owner == simd.u(1), x - simd.f(r.x0 + radii[0][0]), simd.f(left_start + r.y1 - radii[3][1]) - y);
    result = @select(f32, owner == simd.u(2), simd.f(right_start) + y - simd.f(r.y0 + radii[1][1]), result);
    result = @select(f32, owner == simd.u(3), simd.f(bottom_start + r.x1 - radii[2][0]) - x, result);
    const starts = [4]f32{ left_start + left, top, right_start + right, bottom_start + bottom };
    inline for (0..4) |k| {
        const is_left = k == 0 or k == 3;
        const is_top = k < 2;
        const rx = radii[k][0];
        const ry = radii[k][1];
        const cx = if (is_left) r.x0 + rx else r.x1 - rx;
        const cy = if (is_top) r.y0 + ry else r.y1 - ry;
        const dx = if (is_left) simd.f(cx) - x else x - simd.f(cx);
        const dy = if (is_top) simd.f(cy) - y else y - simd.f(cy);
        const nx = @max(dx, simd.f(0)) / simd.f(@max(rx, 1e-20));
        const ny = @max(dy, simd.f(0)) / simd.f(@max(ry, 1e-20));
        const theta = if (k == 1 or k == 3) brushes.angle(nx, ny) else brushes.angle(ny, nx);
        const arc = if (k == 1 or k == 3) ellipseArc(rx, ry, theta) else ellipseArc(ry, rx, theta);
        result = @select(f32, (dx >= simd.f(0)) & (dy >= simd.f(0)), simd.f(starts[k]) + arc, result);
    }
    return result;
}

fn pattern(style: Edge, position: BorderPosition, q: F) F {
    return switch (style.style) {
        .none => simd.f(0),
        .double => @as(F, @floatFromInt(@intFromBool((position.fraction < simd.f(1.0 / 3.0)) | (position.fraction > simd.f(2.0 / 3.0))))),
        .dashed => blk: {
            const dash = if (style.dash > 0) style.dash else 3 * style.width;
            const gap = if (style.gap > 0) style.gap else 3 * style.width;
            break :blk @as(F, @floatFromInt(@intFromBool(@mod(q + simd.f(style.phase), simd.f(@max(dash + gap, 1e-20))) < simd.f(dash))));
        },
        .dotted => blk: {
            const gap = if (style.gap > 0) style.gap else style.width;
            const tangent = @mod(q + simd.f(style.phase), simd.f(@max(style.width + gap, 1e-20))) - simd.f(style.width * 0.5);
            const normal = (position.fraction - simd.f(0.5)) * simd.f(style.width);
            break :blk @as(F, @floatFromInt(@intFromBool(tangent * tangent + normal * normal <= simd.f(style.width * style.width * 0.25))));
        },
        else => simd.f(1),
    };
}

fn paintBorder(dst: surface.Surface, original: RoundedRect, border: Border, view: View) void {
    const outer = borderOuter(original, border);
    const widths = edgeWidths(border);
    const inner = insetShape(outer, widths);
    const center = insetShape(outer, .{ widths[0] * 0.5, widths[1] * 0.5, widths[2] * 0.5, widths[3] * 0.5 });
    const count = sampleCount(view.quality);
    const step = 1 / (@as(f32, @floatFromInt(count)) * view.scale);
    for (0..dst.height) |y| {
        const yy = simd.f(view.origin[1] + @as(f32, @floatFromInt(y)) / view.scale);
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx = simd.f(view.origin[0]) + @as(F, @floatFromInt(simd.iota + simd.u(@intCast(x)))) / simd.f(view.scale);
            // Edge masks partition the same samples. Add their premultiplied contributions
            // before source-over, otherwise a diagonal color join would have a translucent seam.
            var total: surface.Batch = @splat(simd.f(0));
            for (border.edges, 0..) |edge, edge_index| {
                if (edge.width == 0 or edge.style == .none) continue;
                var coverage = simd.f(0);
                var light = simd.f(0);
                for (0..count) |sy| for (0..count) |sx| {
                    const px = xx + simd.f((@as(f32, @floatFromInt(sx)) + 0.5) * step);
                    const py = yy + simd.f((@as(f32, @floatFromInt(sy)) + 0.5) * step);
                    const position = borderPosition(outer, widths, px, py);
                    const chosen = contains(outer, px, py) & !contains(inner, px, py) & (position.edge == simd.u(@intCast(edge_index)));
                    const q = if (edge.style == .dashed or edge.style == .dotted) perimeter(center, position.edge, px, py) else simd.f(0);
                    const mask = @as(F, @floatFromInt(@intFromBool(chosen))) * pattern(edge, position, q) * clipCoverage(view.clips, px, py);
                    coverage += mask;
                    const leading: simd.B = @splat(edge_index < 2);
                    const first = position.fraction < simd.f(0.5);
                    const bright = switch (edge.style) {
                        .inset => !leading,
                        .outset => leading,
                        .groove => leading != first,
                        .ridge => leading == first,
                        else => @as(simd.B, @splat(false)),
                    };
                    light += mask * @as(F, @floatFromInt(@intFromBool(bright)));
                };
                var source = brushes.sample(edge.brush, xx + simd.f(0.5 / view.scale), yy + simd.f(0.5 / view.scale));
                if (edge.style == .inset or edge.style == .outset or edge.style == .groove or edge.style == .ridge) {
                    const bright = light / @max(coverage, simd.f(1e-20));
                    inline for (0..3) |k| source[k] = source[k] * simd.f(0.65) + bright * source[3] * simd.f(0.35);
                }
                inline for (0..4) |k| total[k] += source[k] * coverage / simd.f(@floatFromInt(count * count));
            }
            surface.store(dst, x, y, compositor.combine(surface.load(dst, x, y), total, simd.f(1), .source_over, .normal));
        }
    }
}

/// Paints into an existing surface. All inputs are validated before the first write. The
/// application's ordinary rendering loop decides when to clear, composite, filter, and upload.
pub fn paint(dst: surface.Surface, shape: RoundedRect, description: Description, view: View) Error!void {
    try dst.validate();
    const normalized = try normalize(shape);
    try validate(description);
    try validateView(view);
    try validateSources(dst.pixels, description, view.clips);
    if (shape.rect.w() == 0 or shape.rect.h() == 0) return;
    const widths = edgeWidths(description.border);
    const inner_widths = if (description.border) |b| switch (b.alignment) {
        .inside => widths,
        .center => [4]f32{ widths[0] * 0.5, widths[1] * 0.5, widths[2] * 0.5, widths[3] * 0.5 },
        .outside => @as([4]f32, @splat(0)),
    } else widths;
    const padding_box = insetShape(normalized, inner_widths);
    const content_box = insetShape(padding_box, description.padding);
    for (description.shadows) |shadow| if (!shadow.inset) paintShadow(dst, normalized, shadow, view);
    for (description.backgrounds) |layer| paintLayer(dst, switch (layer.clip) {
        .border => normalized,
        .padding => padding_box,
        .content => content_box,
    }, null, layer, view);
    for (description.shadows) |shadow| if (shadow.inset) paintShadow(dst, padding_box, shadow, view);
    if (description.border) |border| paintBorder(dst, normalized, border, view);
    if (description.outline) |outline| {
        const outline_shape = insetShape(normalized, @splat(-outline.offset));
        const edge: Edge = .{ .width = outline.width, .brush = outline.brush, .style = outline.style, .dash = outline.dash, .gap = outline.gap, .phase = outline.phase };
        paintBorder(dst, outline_shape, .{ .edges = @splat(edge), .alignment = .outside }, view);
    }
}

/// Common prepared-texture sequence. It expands to clear + paint and does not retain anything.
pub fn rasterize(dst: surface.Surface, shape: RoundedRect, description: Description, view: View) Error!void {
    try dst.validate();
    _ = try normalize(shape);
    try validate(description);
    try validateView(view);
    try validateSources(dst.pixels, description, view.clips);
    try surface.clear(dst, @splat(0));
    try paint(dst, shape, description, view);
}

const testing = std.testing;

test "gradient border shadow and separate focus outline coexist in one texture" {
    var stops: [3]brushes.Segment = undefined;
    const ramp = try brushes.prepareStops(&.{ .{ .position = 0, .color = .{ 1, 0, 0, 1 } }, .{ .position = 0.5, .color = .{ 0, 1, 0, 1 } }, .{ .position = 1, .color = .{ 0, 0, 1, 1 } } }, &stops, .{}, .pad);
    const shape: RoundedRect = .{ .rect = .{ .x0 = 5, .y0 = 5, .x1 = 25, .y1 = 25 }, .radii = @splat(.{ 4, 2 }) };
    const desc: Description = .{
        .backgrounds = &.{.{ .brush = .{ .linear = .{ .ramp = ramp, .from = .{ 5, 5 }, .to = .{ 25, 5 } } } }},
        .border = .{ .edges = @splat(.{ .width = 2, .brush = .{ .solid = .{ 1, 1, 1, 1 } } }) },
        .shadows = &.{.{ .offset = .{ 1, 1 }, .sigma = 1, .spread = 1, .color = .{ 0, 0, 0, 0.5 } }},
        .outline = .{ .width = 1, .offset = 1, .brush = .{ .solid = .{ 1, 1, 0, 1 } } },
    };
    const size = try dimensions(try bounds(shape, desc), 1);
    var pixels: [simd.rows(40) * 40]u32 = undefined;
    const target = try surface.init(&pixels, size.width, size.height);
    try rasterize(target, shape, desc, .{ .origin = size.origin });
    const ix = struct {
        fn pixel(s: surface.Surface, origin: [2]f32, x: f32, y: f32) u32 {
            return s.pixels[@as(usize, @intFromFloat(y - origin[1])) * s.stride + @as(usize, @intFromFloat(x - origin[0]))];
        }
    }.pixel;
    try testing.expectEqual(@as(u32, 0xffffffff), ix(target, size.origin, 6, 15));
    try testing.expectEqual(@as(u32, 0xff00ffff), ix(target, size.origin, 3, 15));
    const center = color.unpack(ix(target, size.origin, 15, 15));
    try testing.expect(center[1] > 0.8 and center[3] == 1);
    try testing.expect(ix(target, size.origin, 27, 15) >> 24 > 0);
}

test "radii normalize proportionally and elliptical clips transform coherently" {
    const shape = try normalize(.{ .rect = .{ .x1 = 10, .y1 = 10 }, .radii = @splat(.{ 20, 10 }) });
    try testing.expectEqual([2]f32{ 5, 2.5 }, shape.radii[0]);
    var a: [simd.rows(12) * 12]u32 = undefined;
    const target = try surface.init(&a, 12, 12);
    const clip: Clip = .{ .rounded = .{ .shape = .{ .rect = .{ .x1 = 6, .y1 = 8 }, .radii = @splat(.{ 2, 3 }) }, .inverse = .{ 1, 0, 0, 1, -3, -2 } } };
    try paintShape(target, .{ .rect = .{ .x1 = 12, .y1 = 12 } }, .{ .brush = .{ .solid = .{ 1, 0, 0, 1 } } }, .{ .clips = &.{clip}, .quality = .sixteen });
    try testing.expectEqual(@as(u32, 0), target.pixels[0]);
    try testing.expectEqual(@as(u32, 0xff0000ff), target.pixels[6 * target.stride + 6]);
    // Exactly three of sixteen sample centers satisfy ((x-5)/2)^2+((y-5)/3)^2 <= 1.
    try testing.expectEqual(@as(u32, 0x30000030), target.pixels[2 * target.stride + 3]);
    try testing.expectEqual(@as(u32, 0), target.pixels[target.stride + 3]);
}

test "aliased background and mask fail before rasterize clears the source" {
    var storage: [simd.rows(2) * 2]u32 = undefined;
    const target = try surface.init(&storage, 2, 2);
    try surface.clear(target, .{ 1, 0, 0, 1 });
    const shape: RoundedRect = .{ .rect = .{ .x1 = 2, .y1 = 2 } };
    const layer: Layer = .{ .brush = .{ .image = .{ .image = target.view(), .source = shape.rect, .destination = shape.rect, .area = shape.rect } } };
    try testing.expectError(error.AliasedStorage, rasterize(target, shape, .{ .backgrounds = &.{layer} }, .{}));
    try testing.expectEqual(@as(u32, 0xff0000ff), target.pixels[0]);
    const clip: Clip = .{ .coverage = .{ .image = target.view() } };
    try testing.expectError(error.AliasedStorage, rasterize(target, shape, .{}, .{ .clips = &.{clip} }));
    try testing.expectEqual(@as(u32, 0xff0000ff), target.pixels[0]);
}

test "existing path coverage feeds clips without a retained path manager" {
    const coverage = [_]u8{ 0, 255, 255, 0 };
    var rgba_words: [4]u32 = undefined;
    const clip = try pathClip(&coverage, .{ .x = 2, .y = 3, .w = 2, .h = 2 }, 1, &rgba_words);
    try validateClips(&.{clip});
    try testing.expectEqual(@as(f32, 1), clipCoverage(&.{clip}, simd.f(3.5), simd.f(3.5))[0]);
    try testing.expectEqual(@as(f32, 0), clipCoverage(&.{clip}, simd.f(2.5), simd.f(3.5))[0]);
}

test "per-edge widths and colors leave the content box intact" {
    var a: [simd.rows(20) * 20]u32 = undefined;
    const target = try surface.init(&a, 20, 20);
    const shape: RoundedRect = .{ .rect = .{ .x1 = 20, .y1 = 20 } };
    const edges = [4]Edge{
        .{ .width = 2, .brush = .{ .solid = .{ 1, 0, 0, 1 } } },
        .{ .width = 3, .brush = .{ .solid = .{ 0, 1, 0, 1 } } },
        .{ .width = 4, .brush = .{ .solid = .{ 0, 0, 1, 1 } } },
        .{ .width = 5, .brush = .{ .solid = .{ 1, 1, 1, 1 } } },
    };
    try rasterize(target, shape, .{ .border = .{ .edges = edges } }, .{ .quality = .four });
    try testing.expectEqual(@as(u32, 255), target.pixels[0] >> 24);
    try testing.expectEqual(@as(u32, 0xff0000ff), target.pixels[10 * target.stride]);
    try testing.expectEqual(@as(u32, 0xff00ff00), target.pixels[10]);
    try testing.expectEqual(@as(u32, 0xffff0000), target.pixels[10 * target.stride + 19]);
    try testing.expectEqual(@as(u32, 0xffffffff), target.pixels[19 * target.stride + 10]);
    try testing.expectEqual(@as(u32, 0), target.pixels[10 * target.stride + 10]);
}

test "corner shapes and inset shadows consume their supplied options" {
    var a: [simd.rows(12) * 12]u32 = undefined;
    const target = try surface.init(&a, 12, 12);
    const shape: RoundedRect = .{ .rect = .{ .x1 = 12, .y1 = 12 }, .radii = @splat(.{ 4, 4 }), .corners = .{ .bevel, .scoop, .squircle, .notch } };
    try rasterize(target, shape, .{ .backgrounds = &.{.{ .brush = .{ .solid = .{ 1, 1, 1, 1 } } }}, .shadows = &.{.{ .inset = true, .spread = 1, .sigma = 0, .color = .{ 0, 0, 0, 1 } }} }, .{ .quality = .one });
    try testing.expectEqual(@as(u32, 0), target.pixels[0]);
    try testing.expectEqual(@as(u32, 0xff000000), target.pixels[6]);
    try testing.expectEqual(@as(u32, 0xffffffff), target.pixels[6 * target.stride + 6]);
}

test "non round shadow distances follow bevel scoop and notch contours" {
    var shape: RoundedRect = .{ .rect = .{ .x1 = 20, .y1 = 20 }, .radii = @splat(.{ 6, 6 }), .corners = @splat(.bevel) };
    try testing.expectApproxEqAbs(@as(f32, 0), distance(shape, simd.f(3), simd.f(3))[0], 0.0001);
    try testing.expect(distance(shape, simd.f(1), simd.f(1))[0] > 2);
    shape.corners = @splat(.scoop);
    try testing.expectApproxEqAbs(@as(f32, 6), distance(shape, simd.f(0), simd.f(0))[0], 0.0001);
    shape.corners = @splat(.notch);
    try testing.expectApproxEqAbs(@as(f32, 3), distance(shape, simd.f(3), simd.f(3))[0], 0.0001);
}
