//! Explicit device-grid rounding. Always round cumulative endpoints, not each item's width:
//! shared boundaries then stay shared and fractional gaps do not accumulate drift. The
//! same optional text pass updates glyph, line and caret-query metrics before emission.

const std = @import("std");
const simd = @import("../core/simd.zig");
const Rect = @import("../core/types.zig").Rect;
const lines = @import("../text/layout/lines.zig");

pub const Mode = enum { none, nearest, floor, ceil };
pub const Options = struct {
    mode: Mode = .nearest,
    /// Physical pixels per logical pixel.
    scale: f32 = 1,
    /// Logical coordinate of grid index zero, independently on each axis.
    origin: [2]f32 = .{ 0, 0 },
    pub fn validate(options: Options) error{InvalidScale}!void {
        if (!std.math.isFinite(options.scale) or options.scale <= 0 or !std.math.isFinite(options.origin[0]) or !std.math.isFinite(options.origin[1])) return error.InvalidScale;
    }
};
pub const Interval = struct { start: f32, end: f32 };

pub fn validate(options: Options) error{InvalidScale}!void {
    try options.validate();
}

pub inline fn vector(comptime mode: Mode, values: simd.F, scale: f32, origin: f32) simd.F {
    if (mode == .none) return values;
    const scaled = (values - simd.f(origin)) * simd.f(scale);
    return simd.f(origin) + switch (mode) {
        .nearest => @round(scaled),
        .floor => @floor(scaled),
        .ceil => @ceil(scaled),
        .none => unreachable,
    } / simd.f(scale);
}

pub inline fn scalar(comptime mode: Mode, value: f32, scale: f32, origin: f32) f32 {
    if (mode == .none) return value;
    const scaled = (value - origin) * scale;
    return origin + switch (mode) {
        .nearest => @round(scaled),
        .floor => @floor(scaled),
        .ceil => @ceil(scaled),
        .none => unreachable,
    } / scale;
}

pub fn rect(value: Rect, options: Options) error{InvalidScale}!Rect {
    try options.validate();
    return switch (options.mode) {
        inline else => |mode| .{
            .x0 = scalar(mode, value.x0, options.scale, options.origin[0]),
            .y0 = scalar(mode, value.y0, options.scale, options.origin[1]),
            .x1 = scalar(mode, value.x1, options.scale, options.origin[0]),
            .y1 = scalar(mode, value.y1, options.scale, options.origin[1]),
        },
    };
}

/// Outputs track intervals directly consumable by grid/table/custom placement. Axis chooses
/// the physical grid origin. All sizes and gaps remain measured in logical coordinates.
pub fn tracks(start: f32, sizes: []const f32, gap: f32, axis: u1, options: Options, out: []Interval) error{ InvalidScale, InvalidGeometry, NoSpace }!void {
    try options.validate();
    if (out.len < sizes.len) return error.NoSpace;
    if (!std.math.isFinite(start) or !std.math.isFinite(gap) or gap < 0) return error.InvalidGeometry;
    for (sizes) |size| if (!std.math.isFinite(size) or size < 0) return error.InvalidGeometry;
    switch (options.mode) {
        inline else => |mode| {
            var at = start;
            for (sizes, out[0..sizes.len]) |size, *interval| {
                interval.* = .{ .start = scalar(mode, at, options.scale, options.origin[axis]), .end = scalar(mode, at + size, options.scale, options.origin[axis]) };
                at += size + gap;
            }
        },
    }
}

/// Call after line placement/bidi reorder, before glyph, selection, decoration and caret
/// emission. `run_origin` is the TextRun rect's top-left. Justification is folded into the
/// snapped advance column, so queries never add it twice. Re-layout recreates raw advances
/// when the scale or policy changes; repeatedly snapping already-snapped metrics is avoided.
pub fn text(run_origin: [2]f32, l: *lines.Lines, g: *lines.Glyphs, bytes: []const u8, options: Options) error{InvalidScale}!void {
    try options.validate();
    if (options.mode == .none) return;
    switch (options.mode) {
        inline else => |mode| {
            for (0..l.len) |line| {
                const old_x = run_origin[0] + l.x[line];
                const new_x = scalar(mode, old_x, options.scale, options.origin[0]);
                const old_top = run_origin[1] + l.top[line];
                const old_baseline = run_origin[1] + l.baseline[line];
                const new_top = scalar(mode, old_top, options.scale, options.origin[1]);
                const new_baseline = scalar(mode, old_baseline, options.scale, options.origin[1]);
                for (l.first[line]..l.end[line]) |i| {
                    const pen = old_x + g.x[i];
                    const new_pen = scalar(mode, pen, options.scale, options.origin[0]);
                    const advance = g.advance[i] + if (lines.isSpace(bytes, g.cluster[i])) l.extra[line] else 0;
                    g.advance[i] = scalar(mode, pen + advance, options.scale, options.origin[0]) - new_pen;
                    g.x_offset[i] = scalar(mode, pen + g.x_offset[i], options.scale, options.origin[0]) - new_pen;
                    g.y_offset[i] = new_baseline - scalar(mode, old_baseline - g.y_offset[i], options.scale, options.origin[1]);
                    g.x[i] = new_pen - new_x;
                }
                l.width[line] = scalar(mode, old_x + l.width[line], options.scale, options.origin[0]) - new_x;
                l.height[line] = scalar(mode, old_top + l.height[line], options.scale, options.origin[1]) - new_top;
                l.x[line] = new_x - run_origin[0];
                l.top[line] = new_top - run_origin[1];
                l.baseline[line] = new_baseline - run_origin[1];
                l.extra[line] = 0;
                if (line + 1 == l.len and l.ellipsis > 0) {
                    const marker = scalar(mode, old_x + l.ellipsis_x, options.scale, options.origin[0]);
                    l.ellipsis = scalar(mode, old_x + l.ellipsis_x + l.ellipsis, options.scale, options.origin[0]) - marker;
                    l.ellipsis_x = marker - new_x;
                }
            }
        },
    }
}

test "cumulative rounding preserves shared edges and glyph caret geometry at fractional scale" {
    var spans: [100]Interval = undefined;
    const widths: [100]f32 = @splat(0.6);
    try tracks(0, &widths, 0, 0, .{}, &spans);
    try std.testing.expectEqual(@as(f32, 60), spans[99].end);
    for (1..spans.len) |i| try std.testing.expectEqual(spans[i - 1].end, spans[i].start);
    try tracks(0, widths[0..10], 0.2, 0, .{}, &spans);
    try std.testing.expectEqual(@as(f32, 8), spans[9].end);

    var p: @import("../text/layout/golden.zig").Para = .{};
    p.fixed("aaa", 0.6);
    try lines.breakLines(&p.g, "aaa", 10, &p.l);
    lines.place(&p.l, &p.g, "aaa", &.{.{ .ascent = 0.7, .descent = 0.2 }}, .{});
    try text(.{ 0.2, 0.3 }, &p.l, &p.g, "aaa", .{ .scale = 1.25 });
    const caret = @import("../text/layout/query.zig").caret(&p.l, &p.g, "aaa", 3);
    try std.testing.expectApproxEqAbs(@as(f32, 2.4), 0.2 + caret.x, 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), p.g.x[1], 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), p.g.advance[2], 0.00001);
    try std.testing.expectEqual(@as(f32, 0), p.l.extra[0]);
    try std.testing.expectError(error.InvalidScale, (Options{ .scale = 0 }).validate());
    const exact: Rect = .{ .x0 = 0.25, .y0 = -0.25, .x1 = 3.6, .y1 = 4.8 };
    try std.testing.expectEqual(exact, try rect(exact, .{ .mode = .none }));
}
