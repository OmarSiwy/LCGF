//! Resource selection is a pure operation on caller metadata, before decoding/loading.
//! Binding a loaded result produces the ordinary image brush, so the application keeps its
//! resource IDs, async jobs, cache and render loop. Logical placement never follows DPI.

const std = @import("std");
const brushes = @import("brushes.zig");
const surface = @import("surface.zig");
const color = @import("color_math.zig");
const Rect = @import("../core/types.zig").Rect;
pub const Error = brushes.Error || error{ NoCandidates, InvalidDensity, InconsistentIntrinsicSize };
pub const Candidate = struct { source_id: u64, pixel_size: [2]u32, pixels_per_logical: f32 = 1, orientation: brushes.Orientation = .normal };
pub const Request = struct { box: Rect, device_scale: f32 = 1, fit: brushes.Fit = .contain, alignment: [2]f32 = .{ 0.5, 0.5 } };
pub const Selection = struct {
    index: usize,
    source_id: u64,
    logical_intrinsic: [2]f32,
    destination: Rect,
    box: Rect,
    source_size: [2]u32,
    /// Raw encoded orientation, at most source_size, preserving the image's aspect ratio.
    /// A loader may honor this or decode full-size; either result can be bound below.
    decode_size: [2]u32,
    orientation: brushes.Orientation,
    device_scale: f32,
};
fn logical(candidate: Candidate) Error![2]f32 {
    if (candidate.pixel_size[0] == 0 or candidate.pixel_size[1] == 0 or !std.math.isFinite(candidate.pixels_per_logical) or candidate.pixels_per_logical <= 0) return error.InvalidDensity;
    return brushes.orientedSize(.{ @as(f32, @floatFromInt(candidate.pixel_size[0])) / candidate.pixels_per_logical, @as(f32, @floatFromInt(candidate.pixel_size[1])) / candidate.pixels_per_logical }, candidate.orientation);
}
/// Chooses the smallest sufficient resource; if all are undersized, chooses the greatest
/// available density. Variant logical sizes must agree within one source-pixel rounding unit.
pub fn select(candidates: []const Candidate, request: Request) Error!Selection {
    if (candidates.len == 0) return error.NoCandidates;
    if (!std.math.isFinite(request.device_scale) or request.device_scale <= 0) return error.InvalidDensity;
    const intrinsic = try logical(candidates[0]);
    const destination = try brushes.fitRect(intrinsic, request.box, request.fit, request.alignment);
    const need: [2]f32 = .{ destination.w() * request.device_scale, destination.h() * request.device_scale };
    var chosen: usize = 0;
    var best_quality: f32 = -1;
    var sufficient = false;
    var best_area = std.math.inf(f32);
    for (candidates, 0..) |candidate, i| {
        const size = try logical(candidate);
        const tolerance = @max(1 / candidates[0].pixels_per_logical, 1 / candidate.pixels_per_logical);
        if (@abs(size[0] - intrinsic[0]) > tolerance or @abs(size[1] - intrinsic[1]) > tolerance) return error.InconsistentIntrinsicSize;
        const pixels = brushes.orientedSize(.{ @floatFromInt(candidate.pixel_size[0]), @floatFromInt(candidate.pixel_size[1]) }, candidate.orientation);
        const quality = @min(pixels[0] / need[0], pixels[1] / need[1]);
        const area = pixels[0] * pixels[1];
        if ((quality >= 1 and (!sufficient or area < best_area)) or (!sufficient and quality > best_quality)) {
            chosen = i;
            best_quality = quality;
            best_area = area;
            sufficient = quality >= 1;
        }
    }
    const selected = candidates[chosen];
    const display_pixels = brushes.orientedSize(.{ @floatFromInt(selected.pixel_size[0]), @floatFromInt(selected.pixel_size[1]) }, selected.orientation);
    const ratio = @min(1, @max(need[0] / display_pixels[0], need[1] / display_pixels[1]));
    const decode_size: [2]u32 = .{ @intFromFloat(@max(1, @ceil(@as(f64, @floatFromInt(selected.pixel_size[0])) * ratio))), @intFromFloat(@max(1, @ceil(@as(f64, @floatFromInt(selected.pixel_size[1])) * ratio))) };
    return .{ .index = chosen, .source_id = selected.source_id, .logical_intrinsic = intrinsic, .destination = destination, .box = request.box, .source_size = selected.pixel_size, .decode_size = decode_size, .orientation = selected.orientation, .device_scale = request.device_scale };
}
/// Consumes the selected loaded image. The logical destination/box are stable if DPI changes.
/// Full source-size and hinted-size decodes are both accepted, with their own actual LOD.
pub fn bind(selection: Selection, loaded: surface.Image, mipmaps: []const surface.Image, sampling: brushes.Sampling, tint: color.Rgba) Error!brushes.Brush {
    try loaded.validate();
    const full = loaded.width == selection.source_size[0] and loaded.height == selection.source_size[1];
    const hinted = loaded.width == selection.decode_size[0] and loaded.height == selection.decode_size[1];
    if (!full and !hinted) return error.SizeMismatch;
    const pixels = brushes.orientedSize(.{ @floatFromInt(loaded.width), @floatFromInt(loaded.height) }, selection.orientation);
    const lod = if (mipmaps.len == 0) @as(f32, 0) else try brushes.imageLod(.{ pixels[0] / (selection.destination.w() * selection.device_scale), 0 }, .{ 0, pixels[1] / (selection.destination.h() * selection.device_scale) });
    const result: brushes.Brush = .{ .image = .{ .image = loaded, .source = .{ .x1 = @floatFromInt(loaded.width), .y1 = @floatFromInt(loaded.height) }, .destination = selection.destination, .area = selection.box, .orientation = selection.orientation, .mipmaps = mipmaps, .lod = lod, .sampling = sampling, .tint = tint } };
    try brushes.validate(result);
    return result;
}

const testing = std.testing;
test "DPI variant choice changes the actual resource without changing logical placement" {
    const choices = [_]Candidate{ .{ .source_id = 10, .pixel_size = .{ 2, 1 } }, .{ .source_id = 20, .pixel_size = .{ 4, 2 }, .pixels_per_logical = 2 } };
    const normal = try select(&choices, .{ .box = .{ .x1 = 2, .y1 = 1 } });
    const retina = try select(&choices, .{ .box = .{ .x1 = 2, .y1 = 1 }, .device_scale = 2 });
    try testing.expectEqual(@as(u64, 10), normal.source_id);
    try testing.expectEqual(@as(u64, 20), retina.source_id);
    try testing.expectEqual(normal.destination, retina.destination);
    const red: [2]u32 = @splat(0xff0000ff);
    const blue: [8]u32 = @splat(0xffff0000);
    const first = try bind(normal, .{ .pixels = &red, .width = 2, .height = 1, .stride = 2 }, &.{}, .nearest, .{ 1, 1, 1, 1 });
    const second = try bind(retina, .{ .pixels = &blue, .width = 4, .height = 2, .stride = 4 }, &.{}, .nearest, .{ 1, 1, 1, 1 });
    const simd = @import("../core/simd.zig");
    try testing.expectEqual(@as(f32, 1), brushes.sample(first, simd.f(0.5), simd.f(0.5))[0][0]);
    try testing.expectEqual(@as(f32, 1), brushes.sample(second, simd.f(0.5), simd.f(0.5))[2][0]);
    const reduced = try select(choices[1..], .{ .box = .{ .x1 = 1, .y1 = 0.5 } });
    try testing.expectEqual([2]u32{ 1, 1 }, reduced.decode_size);
}
