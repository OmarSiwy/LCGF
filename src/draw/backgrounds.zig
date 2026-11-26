//! Background geometry and authoring helpers over the same decoration/brush primitives.
//! Caller-provided boxes and scroll/viewport facts are authoritative; no retained node state,
//! window query, style registry or resource lifetime is introduced.

const std = @import("std");
const types = @import("../core/types.zig");
const simd = @import("../core/simd.zig");
const decoration = @import("decoration.zig");
const brushes = @import("brushes.zig");
const surface = @import("surface.zig");
const Rect = types.Rect;
pub const Error = decoration.Error;
pub const Boxes = struct { border: decoration.RoundedRect, border_widths: [4]f32 = @splat(0), padding: [4]f32 = @splat(0) };
pub const Attachment = union(enum) {
    /// Travels with the element's border box, unaffected by its own content scroll.
    scroll,
    /// Unscrolled padding/overflow rectangle in the same logical coordinates as the border.
    /// Its contents move by -scroll_offset; the visible padding box is the scrollport clip.
    local: struct { overflow: Rect, scroll_offset: [2]f32 },
    /// Explicit viewport or transformed containing block. Origin boxes do not relocate it.
    fixed: Rect,
};
pub const Units = enum { logical, normalized };
pub const Layout = struct { origin: decoration.Box = .padding, clip: decoration.Box = .border, attachment: Attachment = .scroll, units: Units = .normalized };
pub const Prepared = struct { shape: decoration.RoundedRect, layer: decoration.Layer, positioning: Rect, window_clip: ?decoration.Clip = null };
pub const Length = struct { px: f32 = 0, percent: f32 = 0 };
pub const Position = struct { fraction: [2]f32 = .{ 0.5, 0.5 }, offset: [2]f32 = .{ 0, 0 } };
pub const RadialShape = enum { circle, ellipse };
pub const Extent = enum { closest_side, farthest_side, closest_corner, farthest_corner };
pub const RadialSize = union(enum) { extent: Extent, radii: [2]f32 };

fn finite2(value: [2]f32) bool {
    return std.math.isFinite(value[0]) and std.math.isFinite(value[1]);
}
fn inset(input: decoration.RoundedRect, edges: [4]f32) Error!decoration.RoundedRect {
    var out = try decoration.normalize(input);
    for (edges) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidGeometry;
    const x0 = input.rect.x0 + edges[0];
    const y0 = input.rect.y0 + edges[1];
    const x1 = input.rect.x1 - edges[2];
    const y1 = input.rect.y1 - edges[3];
    out.rect = .{ .x0 = @min(x0, (x0 + x1) * 0.5), .y0 = @min(y0, (y0 + y1) * 0.5), .x1 = @max(x1, (x0 + x1) * 0.5), .y1 = @max(y1, (y0 + y1) * 0.5) };
    const horizontal = [4]usize{ 0, 2, 2, 0 };
    const vertical = [4]usize{ 1, 1, 3, 3 };
    inline for (0..4) |i| out.radii[i] = .{ @max(0, out.radii[i][0] - edges[horizontal[i]]), @max(0, out.radii[i][1] - edges[vertical[i]]) };
    return decoration.normalize(out);
}
pub fn boxShape(boxes: Boxes, selected: decoration.Box) Error!decoration.RoundedRect {
    const border = try decoration.normalize(boxes.border);
    for (boxes.border_widths) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidGeometry;
    for (boxes.padding) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidGeometry;
    return switch (selected) {
        .border => border,
        .padding => inset(border, boxes.border_widths),
        .content => inset(try inset(border, boxes.border_widths), boxes.padding),
    };
}
fn translated(rect: Rect, offset: [2]f32) Rect {
    return .{ .x0 = rect.x0 + offset[0], .y0 = rect.y0 + offset[1], .x1 = rect.x1 + offset[0], .y1 = rect.y1 + offset[1] };
}

/// The brush is authored relative to the selected origin: logical pixels or a unit square.
/// Each layer independently selects origin, clip, and attachment. `Prepared.layer` remains
/// ordinary mutable data: set its opacity/operator/blend, or use it directly in another pass.
pub fn prepare(boxes: Boxes, layout: Layout, brush: brushes.Brush) Error!Prepared {
    try brushes.validate(brush);
    var shape = try boxShape(boxes, layout.clip);
    var positioning = (try boxShape(boxes, layout.origin)).rect;
    var window_clip: ?decoration.Clip = null;
    switch (layout.attachment) {
        .scroll => {},
        .fixed => |viewport| {
            if (!brushes.validRect(viewport)) return error.InvalidGeometry;
            positioning = viewport;
        },
        .local => |scroll| {
            if (!brushes.validRect(scroll.overflow) or !finite2(scroll.scroll_offset)) return error.InvalidGeometry;
            const padding_shape = try boxShape(boxes, .padding);
            const padding: decoration.RoundedRect = .{ .rect = scroll.overflow, .radii = padding_shape.radii, .corners = padding_shape.corners, .powers = padding_shape.powers };
            const content = try inset(padding, boxes.padding);
            const movement: [2]f32 = .{ -scroll.scroll_offset[0], -scroll.scroll_offset[1] };
            positioning = translated(if (layout.origin == .content) content.rect else padding.rect, movement);
            shape = if (layout.clip == .content) content else padding;
            shape.rect = translated(shape.rect, movement);
            window_clip = .{ .rounded = .{ .shape = padding_shape } };
        },
    }
    if (!brushes.validRect(positioning)) return error.InvalidGeometry;
    const sx: f32 = if (layout.units == .normalized) 1 / positioning.w() else 1;
    const sy: f32 = if (layout.units == .normalized) 1 / positioning.h() else 1;
    return .{ .shape = shape, .positioning = positioning, .window_clip = window_clip, .layer = .{ .brush = brush, .inverse = .{ sx, 0, 0, sy, -positioning.x0 * sx, -positioning.y0 * sy } } };
}
/// Paint one prepared layer; local attachment needs view.clips.len + 1 temporary clip rows.
/// Caller ordering determines layer order, and all borrowed image aliases are checked first.
pub fn paint(dst: surface.Surface, prepared: Prepared, view: decoration.View, clip_rows: []decoration.Clip) Error!void {
    if (prepared.window_clip) |clip| {
        if (clip_rows.len < view.clips.len + 1) return error.InsufficientStorage;
        try brushes.validateSource(prepared.layer.brush, dst.pixels);
        try decoration.validateClipSources(dst.pixels, view.clips);
        @memcpy(clip_rows[0..view.clips.len], view.clips);
        clip_rows[view.clips.len] = clip;
        var clipped_view = view;
        clipped_view.clips = clip_rows[0 .. view.clips.len + 1];
        try decoration.paintShape(dst, prepared.shape, prepared.layer, clipped_view);
    } else try decoration.paintShape(dst, prepared.shape, prepared.layer, view);
}

/// Resolve mixed absolute/percentage corner radii against the border box, then apply the
/// shared proportional overlap normalization. Percentages are fractions (0.5 means 50%).
pub fn radii(rect: Rect, values: [4][2]Length) Error!decoration.RoundedRect {
    if (!brushes.validRect(rect)) return error.InvalidGeometry;
    var out: decoration.RoundedRect = .{ .rect = rect };
    inline for (0..4) |corner| inline for (0..2) |axis| {
        const value = values[corner][axis];
        if (!std.math.isFinite(value.px) or !std.math.isFinite(value.percent)) return error.InvalidGeometry;
        out.radii[corner][axis] = value.px + value.percent * (if (axis == 0) rect.w() else rect.h());
    };
    return decoration.normalize(out);
}
pub fn capsule(rect: Rect) Error!decoration.RoundedRect {
    if (!brushes.validRect(rect)) return error.InvalidGeometry;
    const radius = @min(rect.w(), rect.h()) * 0.5;
    return .{ .rect = rect, .radii = @splat(.{ radius, radius }) };
}
fn positionPoint(rect: Rect, position: Position) Error![2]f32 {
    if (!brushes.validRect(rect) or !finite2(position.fraction) or !finite2(position.offset)) return error.InvalidGeometry;
    const p: [2]f32 = .{ rect.x0 + rect.w() * position.fraction[0] + position.offset[0], rect.y0 + rect.h() * position.fraction[1] + position.offset[1] };
    if (!finite2(p)) return error.InvalidGeometry;
    return p;
}
/// CSS-style gradient angle: zero points up, positive clockwise. Endpoints span the projected
/// rectangle, retaining the requested angle when the reference box changes aspect ratio.
pub fn linear(ramp: brushes.Ramp, rect: Rect, angle_radians: f32) Error!brushes.Brush {
    if (!std.math.isFinite(angle_radians)) return error.InvalidGeometry;
    const center = try positionPoint(rect, .{});
    const dx = @sin(angle_radians);
    const dy = -@cos(angle_radians);
    const length = (@abs(rect.w() * dx) + @abs(rect.h() * dy)) * 0.5;
    const result: brushes.Brush = .{ .linear = .{ .ramp = ramp, .from = .{ center[0] - dx * length, center[1] - dy * length }, .to = .{ center[0] + dx * length, center[1] + dy * length } } };
    try brushes.validate(result);
    return result;
}
/// Closest/farthest radial size, including centers outside the box. Explicit zero radii use
/// a documented limiting result: last stop for pad, the ramp's average for repeat/reflect.
/// Tiny nonzero radii remain available when a caller needs the infinitesimal center detail.
pub fn radial(ramp: brushes.Ramp, rect: Rect, center_position: Position, shape: RadialShape, size: RadialSize) Error!brushes.Brush {
    const center = try positionPoint(rect, center_position);
    const left = @abs(center[0] - rect.x0);
    const right = @abs(center[0] - rect.x1);
    const top = @abs(center[1] - rect.y0);
    const bottom = @abs(center[1] - rect.y1);
    const radius: [2]f32 = switch (size) {
        .radii => |r| r,
        .extent => |extent| blk: {
            const closest = extent == .closest_side or extent == .closest_corner;
            var rx = if (closest) @min(left, right) else @max(left, right);
            var ry = if (closest) @min(top, bottom) else @max(top, bottom);
            const corner = extent == .closest_corner or extent == .farthest_corner;
            if (shape == .circle) {
                rx = if (corner) std.math.hypot(rx, ry) else if (closest) @min(rx, ry) else @max(rx, ry);
                ry = rx;
            } else if (corner) {
                rx *= @sqrt(@as(f32, 2));
                ry *= @sqrt(@as(f32, 2));
            }
            break :blk .{ rx, ry };
        },
    };
    if (!finite2(radius) or radius[0] < 0 or radius[1] < 0 or (shape == .circle and radius[0] != radius[1])) return error.InvalidGeometry;
    if (radius[0] == 0 or radius[1] == 0) {
        try brushes.validate(.{ .radial = .{ .ramp = ramp, .center = center, .radius = .{ 1, 1 } } });
        const value = if (ramp.spread == .pad) brushes.sampleRamp(ramp, simd.f(ramp.segments[ramp.segments.len - 1].position)) else brushes.averageRamp(ramp);
        const straight = surface.unpremultiply(value);
        return .{ .solid = .{ straight[0][0], straight[1][0], straight[2][0], straight[3][0] } };
    }
    const result: brushes.Brush = .{ .radial = .{ .ramp = ramp, .center = center, .radius = radius } };
    try brushes.validate(result);
    return result;
}

const testing = std.testing;
test "background reference boxes and local/fixed attachment change actual sampled pixels" {
    const b: Boxes = .{ .border = .{ .rect = .{ .x1 = 12, .y1 = 8 } }, .border_widths = @splat(1), .padding = @splat(1) };
    var segments: [2]brushes.Segment = undefined;
    const ramp = try brushes.prepareStops(&.{ .{ .position = 0, .color = .{ 1, 0, 0, 1 } }, .{ .position = 1, .color = .{ 0, 0, 1, 1 } } }, &segments, .{}, .pad);
    const brush: brushes.Brush = .{ .linear = .{ .ramp = ramp, .from = .{ 0, 0 }, .to = .{ 1, 0 } } };
    var pixels: [simd.rows(12) * 8]u32 = undefined;
    const dst = try surface.init(&pixels, 12, 8);
    var clips: [1]decoration.Clip = undefined;
    const ordinary = try prepare(b, .{ .origin = .content, .clip = .padding }, brush);
    try paint(dst, ordinary, .{ .quality = .one }, &clips);
    try testing.expectEqual(@as(u32, 0), dst.pixels[0]);
    const before = dst.pixels[4 * dst.stride + 4];
    const scrolled = try prepare(b, .{ .origin = .content, .clip = .content, .attachment = .{ .local = .{ .overflow = .{ .x0 = 1, .y0 = 1, .x1 = 19, .y1 = 15 }, .scroll_offset = .{ 4, 0 } } } }, brush);
    try surface.clear(dst, .{ 0, 0, 0, 0 });
    try paint(dst, scrolled, .{ .quality = .one }, &clips);
    try testing.expect(dst.pixels[4 * dst.stride + 4] != before);
    try testing.expectEqual(@as(u32, 0), dst.pixels[4 * dst.stride]);
    const fixed = try prepare(b, .{ .attachment = .{ .fixed = .{ .x1 = 24, .y1 = 8 } } }, brush);
    var moved = b;
    moved.border.rect = translated(b.border.rect, .{ 2, 0 });
    const fixed_moved = try prepare(moved, .{ .attachment = .{ .fixed = .{ .x1 = 24, .y1 = 8 } } }, brush);
    try testing.expectEqual(fixed.layer.inverse, fixed_moved.layer.inverse);
    var padded = b;
    padded.padding = @splat(2);
    const padding_changed = try prepare(padded, .{ .origin = .content }, brush);
    try testing.expect(padding_changed.layer.inverse[4] != ordinary.layer.inverse[4]);
}
test "percentage radii capsule and radial extent helpers feed real decoration" {
    const rect: Rect = .{ .x1 = 20, .y1 = 10 };
    const rounded = try radii(rect, @splat(.{ .{ .percent = 0.75 }, .{ .percent = 0.75 } }));
    try testing.expectEqual([2]f32{ 10, 5 }, rounded.radii[0]);
    try testing.expectEqual([2]f32{ 5, 5 }, (try capsule(rect)).radii[0]);
    var segments: [2]brushes.Segment = undefined;
    const ramp = try brushes.prepareStops(&.{ .{ .position = 0, .color = .{ 0, 0, 0, 1 } }, .{ .position = 1, .color = .{ 1, 1, 1, 1 } } }, &segments, .{}, .pad);
    const gradient = try radial(ramp, rect, .{ .fraction = .{ 0.25, 0.5 } }, .ellipse, .{ .extent = .closest_side });
    try testing.expectEqual([2]f32{ 5, 5 }, gradient.radial.radius);
    var pixels: [simd.rows(20) * 10]u32 = undefined;
    const dst = try surface.init(&pixels, 20, 10);
    try decoration.paintShape(dst, rounded, .{ .brush = gradient }, .{});
    try testing.expect(dst.pixels[5 * dst.stride + 10] > dst.pixels[5 * dst.stride + 5]);
    const degenerate = try radial(ramp, rect, .{ .fraction = .{ 0, 0 } }, .circle, .{ .extent = .closest_side });
    try testing.expectEqual(@as(f32, 1), degenerate.solid[0]);
    const angled = try linear(ramp, rect, std.math.pi / 2.0);
    try testing.expectApproxEqAbs(@as(f32, 0), angled.linear.from[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 20), angled.linear.to[0], 0.0001);
}
