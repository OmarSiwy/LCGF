//! Vertical glyph rows to bounded column layout and draw quads. The caller supplies real
//! vertical shaping advances (e.g. HarfBuzz vert/vrt2 output), so this does not invent vertical
//! metrics by rotating horizontal text. Per-glyph orientation is explicit and independently
//! selectable for mixed upright/sideways content.

const std = @import("std");
const shape = @import("../shape/shape.zig");
const utf8 = @import("../unicode/utf8.zig");
const draw = @import("../../draw/draw_list.zig");
const glyph_images = @import("emit.zig");

pub const Orientation = enum { upright, clockwise, counter_clockwise };
pub const Item = struct {
    cluster: u32,
    advance: f32,
    cross_advance: f32 = 0,
    offset: [2]f32 = .{ 0, 0 },
    orientation: Orientation = .upright,
};
pub const Position = struct { pen: [2]f32, column: u32, orientation: Orientation, visible: bool };
pub const Style = struct {
    inline_limit: f32 = std.math.inf(f32),
    column_extent: f32,
    gap: f32 = 0,
    right_to_left: bool = true,
    bottom_to_top: bool = false,
    /// Fraction of each column's remaining inline space placed before its glyphs.
    inline_factor: f32 = 0,
    max_columns: u32 = std.math.maxInt(u32),
};
pub const Result = struct { size: [2]f32, columns: u32, clamped: bool };

/// Resolves mixed orientation using the pinned Unicode 16 UAX #50 property. Pass true
/// only when vertical shaping supplied the Tr alternates; otherwise those rotate. A
/// caller may override individual Item orientations afterwards for explicit sideways text.
pub fn orient(items: []Item, text: []const u8, vertical_alternates: bool, sideways: Orientation) void {
    const display = @import("display.zig");
    for (items) |*item| {
        const property = display.vertical(utf8.decode(text, item.cluster).cp);
        item.orientation = switch (property) {
            .upright, .transformed_upright => .upright,
            .rotated => sideways,
            .transformed_rotated => if (vertical_alternates) .upright else sideways,
        };
    }
}

/// Converts the existing horizontal glyph columns plus explicit vertical advances from a
/// shaping adapter into logical-pixel rows. Y offsets flip from font y-up to screen y-down.
pub fn fromRun(run: *const shape.Run, vertical_advance: []const i32, scale: f32, orientation: Orientation, out: []Item) error{NoSpace}![]const Item {
    if (vertical_advance.len < run.len or out.len < run.len) return error.NoSpace;
    for (0..run.len) |i| out[i] = .{
        .cluster = run.cluster[i],
        .advance = @as(f32, @floatFromInt(@abs(vertical_advance[i]))) * scale,
        .cross_advance = @as(f32, @floatFromInt(run.advance[i])) * scale,
        .offset = .{ @as(f32, @floatFromInt(run.x_offset[i])) * scale, -@as(f32, @floatFromInt(run.y_offset[i])) * scale },
        .orientation = orientation,
    };
    return out[0..run.len];
}

/// Groups monotonic shaping clusters into columns without splitting them. Hard newlines
/// start a column. `heights` is caller-owned scratch, one entry per possible column. The
/// result is consumed directly by quads; max_columns hides complete excess columns.
pub fn place(items: []const Item, text: []const u8, style: Style, heights: []f32, out: []Position) error{NoSpace}!Result {
    if (out.len < items.len or heights.len == 0) return error.NoSpace;
    @memset(heights, 0);
    var column: u32 = 0;
    var inline_pos: f32 = 0;
    var cross_pos: f32 = 0;
    var i: usize = 0;
    while (i < items.len) {
        var end = i + 1;
        var advance = items[i].advance;
        while (end < items.len and items[end].cluster == items[i].cluster) : (end += 1) advance += items[end].advance;
        const cp = utf8.decode(text, items[i].cluster).cp;
        const hard = cp == '\n' or cp == '\r' or cp == 0x2028 or cp == 0x2029;
        if (!hard and inline_pos > 0 and inline_pos + advance > style.inline_limit) {
            column += 1;
            inline_pos = 0;
            cross_pos = 0;
        }
        if (column >= heights.len) return error.NoSpace;
        for (i..end) |j| {
            out[j] = .{ .pen = .{ cross_pos + items[j].offset[0], inline_pos + items[j].offset[1] }, .column = column, .orientation = items[j].orientation, .visible = !hard };
            if (!hard) {
                inline_pos += items[j].advance;
                cross_pos += items[j].cross_advance;
            }
        }
        heights[column] = inline_pos;
        if (hard) {
            column += 1;
            inline_pos = 0;
            cross_pos = 0;
        }
        i = end;
    }
    const count = column + 1;
    if (count > heights.len) return error.NoSpace;
    const shown = @min(count, @max(style.max_columns, 1));
    var height: f32 = 0;
    for (heights[0..shown]) |h| height = @max(height, h);
    const extent = if (std.math.isFinite(style.inline_limit)) style.inline_limit else height;
    for (items, out[0..items.len]) |item, *position| {
        position.visible = position.visible and position.column < shown;
        const physical_column = if (style.right_to_left) shown -| 1 -| position.column else position.column;
        position.pen[0] += @as(f32, @floatFromInt(physical_column)) * (style.column_extent + style.gap) + style.column_extent * 0.5;
        const lead = @max(extent - heights[position.column], 0) * std.math.clamp(style.inline_factor, 0, 1);
        if (style.bottom_to_top) position.pen[1] = extent - position.pen[1] - item.advance else position.pen[1] += lead;
    }
    return .{ .size = .{ @as(f32, @floatFromInt(shown)) * style.column_extent + @as(f32, @floatFromInt(shown -| 1)) * style.gap, height }, .columns = shown, .clamped = shown < count };
}

/// Emits vertical upright/sideways images in the original glyph order. The host supplies
/// images rasterized from the same face, axis coordinates, size and glyph IDs as shaping.
pub fn quads(run: draw.TextRun, positions: []const Position, images: []const glyph_images.Image, out: []draw.Quad) error{NoSpace}!u32 {
    if (images.len < positions.len) return error.NoSpace;
    var n: u32 = 0;
    for (positions, images[0..positions.len]) |position, image| {
        if (!position.visible or image.bounds[0] >= image.bounds[2] or image.bounds[1] >= image.bounds[3]) continue;
        if (n == out.len) return error.NoSpace;
        const sine: f32 = switch (position.orientation) {
            .upright => 0,
            .clockwise => 1,
            .counter_clockwise => -1,
        };
        const cosine: f32 = @floatFromInt(@intFromBool(position.orientation == .upright));
        const x = run.rect[0] + position.pen[0];
        const y = run.rect[1] + position.pen[1];
        const m = run.xform;
        out[n] = .{
            .rect = image.bounds,
            .clip = run.clip,
            .params = @splat(0),
            .uv = image.uv,
            .radii = @splat(0),
            .fill = run.color,
            .border_color = 0,
            .border = 0,
            .opacity = 1,
            .xform = .{ m[0] * cosine + m[2] * sine, m[1] * cosine + m[3] * sine, m[2] * cosine - m[0] * sine, m[3] * cosine - m[1] * sine, m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5] },
            .clip_radii = run.clip_radii,
        };
        n += 1;
    }
    return n;
}

test "real vertical advance rows form right-to-left columns and upright or sideways quads" {
    var columns: shape.TestRun = .{};
    var run = columns.run();
    run.len = 4;
    @memcpy(run.glyph[0..4], &[_]u16{ 1, 2, 3, 4 });
    @memcpy(run.cluster[0..4], &[_]u32{ 0, 1, 2, 3 });
    @memset(run.advance[0..4], 0);
    @memset(run.x_offset[0..4], -500);
    @memset(run.y_offset[0..4], -800);
    var items: [4]Item = undefined;
    const input = try fromRun(&run, &.{ -1000, -1000, -1000, -1000 }, 0.02, .upright, &items);
    items[2].orientation = .clockwise;
    var heights: [4]f32 = undefined;
    var positions: [4]Position = undefined;
    const result = try place(input, "ABCD", .{ .inline_limit = 40, .column_extent = 20, .gap = 4 }, &heights, &positions);
    try std.testing.expectEqual([2]f32{ 44, 40 }, result.size);
    try std.testing.expectEqual(2, result.columns);
    try std.testing.expectEqual([2]f32{ 24, 16 }, positions[0].pen);
    try std.testing.expectEqual([2]f32{ 0, 16 }, positions[2].pen);
    const images: [4]glyph_images.Image = @splat(.{ .bounds = .{ 0, -16, 16, 4 } });
    var out: [4]draw.Quad = undefined;
    const draw_run: draw.TextRun = .{ .rect = .{ 100, 50, 144, 90 }, .clip = .{ 0, 0, 500, 500 }, .px = 20, .start = 0, .bytes = 4, .font = 0, .color = 0xffffffff };
    try std.testing.expectEqual(4, try quads(draw_run, &positions, &images, &out));
    try std.testing.expectEqual([6]f32{ 1, 0, 0, 1, 124, 66 }, out[0].xform);
    try std.testing.expectEqual([6]f32{ 0, 1, -1, 0, 100, 66 }, out[2].xform);
    const clamped = try place(input, "ABCD", .{ .inline_limit = 40, .column_extent = 20, .max_columns = 1 }, &heights, &positions);
    try std.testing.expect(clamped.clamped and !positions[2].visible);
}
