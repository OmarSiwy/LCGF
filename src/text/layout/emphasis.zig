//! Emphasis marks on actual grapheme/ligature geometry, including vertical upright marks.
//! A caller supplies an atlas image for a named mark or a custom shaped grapheme. Placement
//! and glyph emission are separate; optional horizontal reservation updates line metrics.
//! Unicode16 separator/punctuation/control exclusions follow the declared CSS Text Decor3
//! profile. A ligature's typographic units use the same equal-share geometry as caret queries.
//! https://www.w3.org/TR/css-text-decor-3/#text-emphasis-style-property

const std = @import("std");
const lines = @import("lines.zig");
const vertical_ = @import("vertical.zig");
const Graphemes = @import("../unicode/grapheme.zig").Graphemes;
const utf8 = @import("../unicode/utf8.zig");
const property = @import("../unicode/property.zig");
const optional = @import("../unicode/style_properties.zig");
const shape_ = @import("../shape/shape.zig");
const draw = @import("../../draw/draw_list.zig");
const Image = @import("emit.zig").Image;
const Rect = @import("../../core/types.zig").Rect;

pub const Shape = enum { dot, circle, double_circle, triangle, sesame };
pub const Fill = enum { filled, open };
pub const Error = error{ NoSpace, InvalidGeometry, InvalidRange };
pub const Placement = struct { rect: [4]f32, byte: u32, line: u32 };
pub const Options = struct { side: enum { over, under } = .over, gap: f32 = 1, reserve_space: bool = true };

pub fn markText(shape: Shape, fill: Fill) []const u8 {
    return switch (shape) {
        .dot => if (fill == .filled) "•" else "◦",
        .circle => if (fill == .filled) "●" else "○",
        .double_circle => if (fill == .filled) "◉" else "◎",
        .triangle => if (fill == .filled) "▲" else "△",
        .sesame => if (fill == .filled) "﹅" else "﹆",
    };
}

/// Optional native shaping convenience; atlas allocation/raster policy stays with the host.
/// Mark size is conventionally half the text size. A missing glyph is explicit so a host can
/// choose a suitable emphasis font or synthesize a mark rather than display .notdef.
pub fn shapeMark(shaper: *const shape_.Shaper, shape: Shape, fill: Fill, out: *shape_.Run) error{ NoSpace, MissingGlyph }!void {
    try shaper.shape(markText(shape, fill), out, .{});
    for (out.glyph[0..out.len]) |glyph| if (glyph == 0) return error.MissingGlyph;
}

fn eligible(text: []const u8) bool {
    if (text.len == 0) return false;
    const first = utf8.decode(text, 0);
    return switch (optional.emphasis(first.cp)) {
        .mark => true,
        .skip => false,
        .separator => blk: {
            var at: usize = first.len;
            while (at < text.len) {
                const cp = utf8.decode(text, at);
                const class = property.grapheme(cp.cp).gcb;
                if (class == .Extend or class == .SpacingMark) break :blk true;
                at += cp.len;
            }
            break :blk false;
        },
    };
}

fn valid(size: [2]f32, gap: f32, text: []const u8, range: [2]u32) Error!void {
    if (!std.math.isFinite(size[0]) or !std.math.isFinite(size[1]) or !std.math.isFinite(gap) or size[0] < 0 or size[1] < 0 or gap < 0) return error.InvalidGeometry;
    if (range[0] > range[1] or range[1] > text.len) return error.InvalidRange;
}

fn countUnits(bytes: []const u8) f32 {
    var iterator: Graphemes = .{ .text = bytes };
    var count: f32 = 0;
    while (iterator.next()) |_| count += 1;
    return @max(count, 1);
}

fn walkLine(comptime writing: bool, l: *const lines.Lines, g: *const lines.Glyphs, text: []const u8, range: [2]u32, line: u32, size: [2]f32, y: f32, out: []Placement) u32 {
    var n: u32 = 0;
    var i = l.first[line];
    while (i < l.end[line]) {
        const first = i;
        const start = g.cluster[i];
        var left = std.math.inf(f32);
        var width: f32 = 0;
        while (i < l.end[line] and g.cluster[i] == start) : (i += 1) {
            left = @min(left, g.x[i]);
            width += g.advance[i] + if (lines.isSpace(text, start)) l.extra[line] else 0;
        }
        const end: u32 = if (i < g.len) g.cluster[i] else @intCast(text.len);
        const bytes = text[start..end];
        const units = if (writing) countUnits(bytes) else 1;
        var graphemes: Graphemes = .{ .text = bytes };
        var before: usize = 0;
        var unit: f32 = 0;
        while (graphemes.next()) |after| {
            const byte: u32 = start + @as(u32, @intCast(before));
            if (byte >= range[0] and byte < range[1] and eligible(bytes[before..after])) {
                if (writing) {
                    var factor = (unit + 0.5) / units;
                    if (g.level[first] & 1 != 0) factor = 1 - factor;
                    const center = l.x[line] + left + width * factor;
                    out[n] = .{ .rect = .{ center - size[0] * 0.5, y, center + size[0] * 0.5, y + size[1] }, .byte = byte, .line = line };
                }
                n += 1;
            }
            before = after;
            unit += 1;
        }
    }
    return n;
}

/// After ordinary place/reorder. With reservation, marks extend each affected line's
/// height and move subsequent lines; text, caret and selection therefore share the new
/// layout. Commit the resulting extents through text_metrics.commit before arranging nodes.
/// Capacity is checked before changing any line geometry.
pub fn place(l: *lines.Lines, g: *const lines.Glyphs, text: []const u8, range: [2]u32, size: [2]f32, options: Options, out: []Placement) Error!u32 {
    try valid(size, options.gap, text, range);
    if (size[0] == 0 or size[1] == 0) return 0;
    var total: usize = 0;
    for (0..l.len) |line| total += walkLine(false, l, g, text, range, @intCast(line), size, 0, out[0..0]);
    if (total > out.len) return error.NoSpace;
    var n: u32 = 0;
    var shift: f32 = 0;
    const extra = size[1] + options.gap;
    for (0..l.len) |line| {
        const k: u32 = @intCast(line);
        const count = walkLine(false, l, g, text, range, k, size, 0, out[0..0]);
        l.top[line] += shift;
        l.baseline[line] += shift;
        if (count == 0) continue;
        const y = if (options.reserve_space) blk: {
            if (options.side == .over) l.baseline[line] += extra;
            l.height[line] += extra;
            shift += extra;
            break :blk if (options.side == .over) l.top[line] else l.top[line] + l.height[line] - size[1];
        } else if (options.side == .over) l.top[line] - extra else l.top[line] + l.height[line] + options.gap;
        n += walkLine(true, l, g, text, range, k, size, y, out[n..]);
    }
    return n;
}

pub const VerticalOptions = struct { side: enum { left, right } = .right, gap: f32 = 1 };

/// Uses actual vertical pens/advances and caller-arranged column rectangles. Mark images
/// stay upright even when the base glyph is sideways. Column gaps/widths reserve space in
/// the caller's vertical layout; this output does not silently move existing columns.
pub fn placeVertical(items: []const vertical_.Item, positions: []const vertical_.Position, columns: []const Rect, text: []const u8, range: [2]u32, size: [2]f32, options: VerticalOptions, out: []Placement) Error!u32 {
    try valid(size, options.gap, text, range);
    if (positions.len < items.len) return error.NoSpace;
    var n: u32 = 0;
    var i: usize = 0;
    while (i < items.len) {
        const first = i;
        const start = items[i].cluster;
        var height: f32 = 0;
        while (i < items.len and items[i].cluster == start) : (i += 1) height += items[i].advance;
        if (!positions[first].visible) continue;
        const column = positions[first].column;
        if (column >= columns.len) return error.InvalidGeometry;
        const end = if (i < items.len) items[i].cluster else text.len;
        const bytes = text[start..end];
        const units = countUnits(bytes);
        const top = positions[first].pen[1] - items[first].offset[1];
        const x = if (options.side == .right) columns[column].x1 + options.gap else columns[column].x0 - options.gap - size[0];
        var graphemes: Graphemes = .{ .text = bytes };
        var before: usize = 0;
        var unit: f32 = 0;
        while (graphemes.next()) |after| {
            const byte: u32 = start + @as(u32, @intCast(before));
            if (byte >= range[0] and byte < range[1] and eligible(bytes[before..after])) {
                if (n == out.len) return error.NoSpace;
                const center = top + height * (unit + 0.5) / units;
                out[n] = .{ .rect = .{ x, center - size[1] * 0.5, x + size[0], center + size[1] * 0.5 }, .byte = byte, .line = column };
                n += 1;
            }
            before = after;
            unit += 1;
        }
    }
    return n;
}

pub fn quads(run: draw.TextRun, positions: []const Placement, image: Image, color: ?u32, out: []draw.Quad) error{NoSpace}!u32 {
    if (out.len < positions.len) return error.NoSpace;
    for (positions, out[0..positions.len]) |position, *quad| {
        const r = position.rect;
        quad.* = .{
            .rect = .{ run.rect[0] + r[0], run.rect[1] + r[1], run.rect[0] + r[2], run.rect[1] + r[3] },
            .clip = run.clip,
            .params = @splat(0),
            .uv = image.uv,
            .radii = @splat(0),
            .fill = color orelse run.color,
            .border_color = 0,
            .border = 0,
            .opacity = if (color != null) run.opacity else 1,
            .xform = run.xform,
            .clip_radii = run.clip_radii,
        };
    }
    return @intCast(positions.len);
}

test "emphasis uses ligature shares grapheme exclusions and reserved real line geometry" {
    var p: @import("golden.zig").Para = .{};
    p.fixed("ffi A!", 10);
    p.g.cluster[1] = 0;
    p.g.cluster[2] = 0;
    try lines.breakLines(&p.g, "ffi A!", 100, &p.l);
    lines.place(&p.l, &p.g, "ffi A!", &.{.{ .ascent = 8, .descent = 2 }}, .{});
    var positions: [8]Placement = undefined;
    const n = try place(&p.l, &p.g, "ffi A!", .{ 0, 6 }, .{ 4, 4 }, .{ .gap = 2 }, &positions);
    try std.testing.expectEqual(@as(u32, 4), n);
    try std.testing.expectEqual([4]f32{ 3, 0, 7, 4 }, positions[0].rect);
    try std.testing.expectEqual([4]f32{ 13, 0, 17, 4 }, positions[1].rect);
    try std.testing.expectEqual([4]f32{ 43, 0, 47, 4 }, positions[3].rect);
    try std.testing.expectEqual(@as(f32, 14), p.l.baseline[0]);
    try std.testing.expectEqual(@as(f32, 16), lines.stackHeight(&p.l));
    try std.testing.expect(eligible(" \u{301}") and eligible("％") and !eligible("！") and !eligible("\u{a0}"));
    const run: draw.TextRun = .{ .rect = .{ 10, 20, 70, 36 }, .clip = .{ 0, 0, 100, 100 }, .px = 20, .start = 0, .bytes = 6, .font = 0, .color = 0xffffffff, .opacity = 0.5, .xform = .{ 2, 0, 0, 2, 5, 6 }, .clip_radii = @splat(3) };
    var output: [8]draw.Quad = undefined;
    try std.testing.expectEqual(n, try quads(run, positions[0..n], .{ .uv = .{ 0, 0, 1, 1 } }, 0xff0080ff, &output));
    try std.testing.expectEqual(run.xform, output[0].xform);
    try std.testing.expectEqual(run.clip_radii, output[0].clip_radii);
    try std.testing.expectEqual(@as(f32, 0.5), output[0].opacity);
    const combined = "か\u{3099} ";
    p.fixed(combined, 10);
    lines.graphemeClusters(&p.g, combined);
    try lines.breakLines(&p.g, combined, 100, &p.l);
    lines.place(&p.l, &p.g, combined, &.{.{ .ascent = 8, .descent = 2 }}, .{});
    try std.testing.expectEqual(@as(u32, 1), try place(&p.l, &p.g, combined, .{ 0, combined.len }, .{ 3, 3 }, .{ .reserve_space = false }, &positions));
    const face = try @import("../font/opentype.zig").Face.parse(@embedFile("../shape/testdata/variable.ttf"), 0);
    const shaper: shape_.Shaper = .init(face);
    var columns: shape_.TestRun = .{};
    var shaped = columns.run();
    try std.testing.expectError(error.MissingGlyph, shapeMark(&shaper, .circle, .filled, &shaped));
}

test "vertical emphasis remains upright beside actual column geometry" {
    const items = [_]vertical_.Item{ .{ .cluster = 0, .advance = 20, .orientation = .clockwise }, .{ .cluster = 3, .advance = 20 } };
    var positions: [2]vertical_.Position = undefined;
    var heights: [2]f32 = undefined;
    _ = try vertical_.place(&items, "漢字", .{ .column_extent = 20, .inline_limit = 40 }, &heights, &positions);
    var marks: [2]Placement = undefined;
    const count = try placeVertical(&items, &positions, &.{.{ .x0 = 0, .y0 = 0, .x1 = 20, .y1 = 40 }}, "漢字", .{ 0, 6 }, .{ 4, 4 }, .{ .gap = 2 }, &marks);
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expectEqual([4]f32{ 22, 8, 26, 12 }, marks[0].rect);
    try std.testing.expectEqual([4]f32{ 22, 28, 26, 32 }, marks[1].rect);
}
