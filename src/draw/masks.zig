//! Explicit mask placement and combination. Layers are ordinary brushes (including image
//! fit/repeat/orientation/mips and gradients) sampled in caller-selected logical coordinates.
//! The destination is one reusable white-premultiplied alpha image; it can mask a completed
//! group with compositor.applyMask, or become a decoration coverage clip. No surface pool,
//! retained registry, loading callback or per-layer temporary image is required.

const std = @import("std");
const simd = @import("../core/simd.zig");
const brushes = @import("brushes.zig");
const decoration = @import("decoration.zig");
const compositor = @import("compositor.zig");
const surface = @import("surface.zig");
const Rect = @import("../core/types.zig").Rect;
const F = simd.F;
pub const Error = decoration.Error || compositor.Error;
pub const Layer = struct {
    brush: brushes.Brush,
    inverse: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
    /// Optional paint-space region, independent of brush positioning. Inversion is applied
    /// before this region, so an inverted tile does not unexpectedly fill the whole target.
    region: ?decoration.RoundedRect = null,
    mode: compositor.MaskMode = .alpha,
    invert: bool = false,
    opacity: f32 = 1,
    operator: compositor.MaskOperator = .add,
};

fn validateLayer(layer: Layer, dst: surface.Surface) Error!void {
    try brushes.validateSource(layer.brush, dst.pixels);
    if (!std.math.isFinite(layer.opacity) or layer.opacity < 0 or layer.opacity > 1) return error.InvalidOpacity;
    for (layer.inverse) |v| if (!std.math.isFinite(v)) return error.InvalidTransform;
    if (@abs(layer.inverse[0] * layer.inverse[3] - layer.inverse[1] * layer.inverse[2]) < 1e-20) return error.InvalidTransform;
    if (layer.region) |region| _ = try decoration.normalize(region);
}

/// Layers are supplied back-to-front. Every operator is applied, including the first, to
/// `initial` coverage (normally zero, or one for an intersection-only stack). Subtract means
/// new-source * (1 - accumulated-backdrop), matching mask-composite/source-out. Coincident
/// shape/clip edges share subpixel samples; they are not multiplied after separate AA passes.
/// All parameters, source aliases and capacities are validated before the first pixel write.
pub fn rasterize(dst: surface.Surface, layers: []const Layer, view: decoration.View, initial: f32) Error!void {
    try dst.validate();
    if (!std.math.isFinite(initial) or initial < 0 or initial > 1) return error.InvalidOpacity;
    if (!std.math.isFinite(view.scale) or view.scale <= 0 or !std.math.isFinite(view.origin[0]) or !std.math.isFinite(view.origin[1])) return error.InvalidScale;
    try decoration.validateClipSources(dst.pixels, view.clips);
    for (layers) |layer| try validateLayer(layer, dst);
    const count: usize = switch (view.quality) {
        .one => 1,
        .four => 2,
        .sixteen => 4,
    };
    const step = 1 / (@as(f32, @floatFromInt(count)) * view.scale);
    for (0..dst.height) |y| {
        const yy = simd.f(view.origin[1] + @as(f32, @floatFromInt(y)) / view.scale);
        var x: usize = 0;
        while (x < simd.padded(dst.width)) : (x += simd.lanes) {
            const xx = simd.f(view.origin[0]) + @as(F, @floatFromInt(simd.iota + simd.u(@intCast(x)))) / simd.f(view.scale);
            var sum = simd.f(0);
            for (0..count) |sy| for (0..count) |sx| {
                const px = xx + simd.f((@as(f32, @floatFromInt(sx)) + 0.5) * step);
                const py = yy + simd.f((@as(f32, @floatFromInt(sy)) + 0.5) * step);
                var accumulated = simd.f(initial);
                for (layers) |layer| {
                    const xy = decoration.transformed(layer.inverse, px, py);
                    var source = compositor.maskCoverage(brushes.sample(layer.brush, xy[0], xy[1]), layer.mode);
                    if (layer.invert) source = simd.f(1) - source;
                    source *= simd.f(layer.opacity);
                    if (layer.region) |region| source *= @as(F, @floatFromInt(@intFromBool(decoration.contains(decoration.normalize(region) catch unreachable, px, py))));
                    accumulated = switch (layer.operator) {
                        .add => source + accumulated - source * accumulated,
                        .subtract => source * (simd.f(1) - accumulated),
                        .intersect => source * accumulated,
                        .exclude => source * (simd.f(1) - accumulated) + accumulated * (simd.f(1) - source),
                    };
                }
                sum += accumulated * decoration.clipCoverage(view.clips, px, py);
            };
            const coverage = sum / simd.f(@floatFromInt(count * count));
            surface.store(dst, x, y, .{ coverage, coverage, coverage, coverage });
        }
    }
}

/// Prepares an actual nine-slice mask border. Independent fractional source/destination
/// cuts, edge repeat/round/space, omitted center and alpha/luminance are retained. Each patch
/// is bounded by its own destination area, preventing a repeated edge from painting adjacent
/// corners. Supply nine output rows even when the center is omitted; no pixels are allocated.
pub fn nineSlice(image: surface.Image, source: Rect, destination: Rect, source_cuts: [4]f32, destination_cuts: [4]f32, repeat: [2]brushes.Repeat, fill_center: bool, sampling: brushes.Sampling, mode: compositor.MaskMode, out: []Layer) Error![]Layer {
    if (out.len < 9) return error.InsufficientStorage;
    var patches: [9]brushes.ImageBrush = undefined;
    const items = try brushes.nineSlice(image, source, destination, source_cuts, destination_cuts, repeat, fill_center, sampling, &patches);
    for (items, out[0..items.len]) |item, *layer| layer.* = .{ .brush = .{ .image = item }, .region = .{ .rect = item.area }, .mode = mode };
    return out[0..items.len];
}

const testing = std.testing;

test "placed repeated masks combine in order with explicit coverage mode" {
    var pixels: [simd.rows(6) * 2]u32 = undefined;
    const dst = try surface.init(&pixels, 6, 2);
    const pattern = [_]u32{ 0xff0000ff, 0 };
    const tiled: brushes.Brush = .{ .image = .{ .image = .{ .pixels = &pattern, .width = 2, .height = 1, .stride = 2 }, .source = .{ .x1 = 2, .y1 = 1 }, .destination = .{ .x0 = 1, .x1 = 3, .y1 = 1 }, .area = .{ .x1 = 6, .y1 = 2 }, .repeat = .{ .repeat, .repeat }, .sampling = .nearest } };
    const layers = [_]Layer{
        .{ .brush = tiled, .mode = .luminance },
        .{ .brush = .{ .solid = .{ 1, 1, 1, 0.5 } }, .operator = .intersect },
    };
    try rasterize(dst, &layers, .{ .quality = .one }, 0);
    try testing.expectEqual(@as(u32, 0), dst.pixels[0]);
    try testing.expectEqual(@as(u32, 27), dst.pixels[1] >> 24);
    try testing.expectEqual(dst.pixels[1], dst.pixels[3]);
    const inverted = [_]Layer{.{ .brush = tiled, .invert = true, .region = .{ .rect = .{ .x0 = 2, .x1 = 4, .y1 = 2 } } }};
    try rasterize(dst, &inverted, .{ .quality = .one }, 0);
    try testing.expectEqual(@as(u32, 0), dst.pixels[0]);
    try testing.expectEqual(@as(u32, 255), dst.pixels[2] >> 24);
    try testing.expectEqual(@as(u32, 0), dst.pixels[3]);
}

test "nine slice mask border is consumed by a completed group and preflights storage" {
    var mask_pixels: [simd.rows(8) * 8]u32 = undefined;
    var group_pixels: [simd.rows(8) * 8]u32 = undefined;
    const mask = try surface.init(&mask_pixels, 8, 8);
    const group = try surface.init(&group_pixels, 8, 8);
    const source_pixels: [9]u32 = @splat(0xffffffff);
    const image: surface.Image = .{ .pixels = &source_pixels, .width = 3, .height = 3, .stride = 3 };
    var rows: [9]Layer = undefined;
    const layers = try nineSlice(image, .{ .x1 = 3, .y1 = 3 }, .{ .x1 = 8, .y1 = 8 }, @splat(1), @splat(2), .{ .round, .space }, false, .nearest, .alpha, &rows);
    try rasterize(mask, layers, .{ .quality = .four }, 0);
    try surface.clear(group, .{ 1, 0, 0, 1 });
    try compositor.applyMask(group, mask.view(), .{});
    try testing.expectEqual(@as(u32, 0xff0000ff), group.pixels[0]);
    try testing.expectEqual(@as(u32, 0), group.pixels[4 * group.stride + 4]);
    try testing.expectError(error.InsufficientStorage, nineSlice(image, .{ .x1 = 3, .y1 = 3 }, .{ .x1 = 8, .y1 = 8 }, @splat(1), @splat(2), .{ .repeat, .repeat }, false, .nearest, .alpha, rows[0..8]));
    const before = mask.pixels[0];
    const feedback = [_]Layer{.{ .brush = .{ .image = .{ .image = mask.view(), .source = .{ .x1 = 8, .y1 = 8 }, .destination = .{ .x1 = 8, .y1 = 8 }, .area = .{ .x1 = 8, .y1 = 8 } } } }};
    try testing.expectError(error.AliasedStorage, rasterize(mask, &feedback, .{}, 0));
    try testing.expectEqual(before, mask.pixels[0]);
}
