//! Inline replaced content and ruby composition, over caller-owned paragraph data. Objects
//! participate in advances/line metrics before breaking, then become ordinary textured quads
//! at their baseline after placement. Ruby composes two separately shaped/measured paragraphs.

const std = @import("std");
const lines = @import("lines.zig");
const utf8 = @import("../unicode/utf8.zig");
const draw = @import("../../draw/draw_list.zig");

pub const Alignment = enum { baseline, text_top, text_bottom, text_center, line_top, line_bottom };
pub const Object = struct {
    /// Source offset of a U+FFFC replacement character, in ascending order.
    byte: u32,
    size: [2]f32,
    /// A dedicated caller-reserved metrics/span row for this object.
    span: u32,
    alignment: Alignment = .baseline,
    /// Its own baseline below its top. Null aligns its bottom to the text baseline.
    baseline: ?f32 = null,
};
pub const Placement = struct { rect: [4]f32, line: u32, glyph: u32 };
pub const Error = error{ NoSpace, MissingPlaceholder, InvalidSpan };

/// After shaping, before breakLines: replace U+FFFC's nominal advance with the object's
/// width and write its dedicated font-metric row. Other glyphs in its cluster receive zero
/// advance, so selection and emergency wrapping keep the whole object together. When rich
/// font mapping is used, its table must also cover the reserved object span rows.
pub fn measure(g: *lines.Glyphs, text: []const u8, objects: []const Object, metrics: []lines.Metrics, parent: lines.Metrics) Error!void {
    var glyph: usize = 0;
    for (objects) |object| {
        if (object.span >= metrics.len) return error.InvalidSpan;
        switch (g.fonts) {
            .spans => |fonts| if (object.span >= fonts.len) {
                return error.InvalidSpan;
            },
            else => {},
        }
        while (glyph < g.len and g.cluster[glyph] < object.byte) glyph += 1;
        if (glyph == g.len or g.cluster[glyph] != object.byte or utf8.decode(text, object.byte).cp != 0xfffc) return error.MissingPlaceholder;
        const height = @max(object.size[1], 0);
        const ascent = switch (object.alignment) {
            .baseline, .line_top, .line_bottom => object.baseline orelse height,
            .text_top => parent.ascent,
            .text_bottom => height - parent.descent,
            .text_center => (height + parent.ascent - parent.descent) * 0.5,
        };
        metrics[object.span] = .{ .ascent = ascent, .descent = height - ascent };
        g.advance[glyph] = @max(object.size[0], 0);
        g.span[glyph] = object.span;
        glyph += 1;
        while (glyph < g.len and g.cluster[glyph] == object.byte) : (glyph += 1) {
            g.advance[glyph] = 0;
            g.span[glyph] = object.span;
        }
    }
}

/// After line placement/reordering, locate each visible object's box. Objects omitted by
/// line clamping are omitted from the result. Output order matches the input objects that
/// remain visible; the returned count is exact, and no coordinates are guessed from bytes.
pub fn place(l: *const lines.Lines, g: *const lines.Glyphs, objects: []const Object, metrics: []const lines.Metrics, out: []Placement) Error!u32 {
    var n: u32 = 0;
    var glyph: u32 = 0;
    for (objects) |object| {
        while (glyph < g.len and g.cluster[glyph] < object.byte) glyph += 1;
        if (glyph == g.len or g.cluster[glyph] != object.byte) return error.MissingPlaceholder;
        var line: u32 = 0;
        while (line < l.len and l.end[line] <= glyph) line += 1;
        if (line == l.len or glyph >= l.ink[line]) continue;
        if (n == out.len) return error.NoSpace;
        if (object.span >= metrics.len) return error.InvalidSpan;
        const x = l.x[line] + g.x[glyph];
        const y = switch (object.alignment) {
            .line_top => l.top[line],
            .line_bottom => l.top[line] + l.height[line] - object.size[1],
            else => l.baseline[line] - metrics[object.span].ascent,
        };
        out[n] = .{ .rect = .{ x, y, x + object.size[0], y + object.size[1] }, .line = line, .glyph = glyph };
        n += 1;
    }
    return n;
}

pub const Image = struct { uv: [4]f32 = .{ 0, 0, 1, 1 }, color: u32 = 0xffffffff };

/// Object image quads share the text run's transform, rounded clip and inherited opacity.
/// Images correspond to the visible placement rows, allowing an atlas page batch per call.
pub fn quads(run: draw.TextRun, placements: []const Placement, images: []const Image, out: []draw.Quad) error{NoSpace}!u32 {
    if (images.len < placements.len or out.len < placements.len) return error.NoSpace;
    for (placements, images[0..placements.len], out[0..placements.len]) |object, image, *q| {
        const r = object.rect;
        q.* = .{
            .rect = .{ run.rect[0] + r[0], run.rect[1] + r[1], run.rect[0] + r[2], run.rect[1] + r[3] },
            .clip = run.clip,
            .params = @splat(0),
            .uv = image.uv,
            .radii = @splat(0),
            .fill = image.color,
            .border_color = 0,
            .border = 0,
            .opacity = run.opacity,
            .xform = run.xform,
            .clip_radii = run.clip_radii,
        };
    }
    return @intCast(placements.len);
}

pub const Box = struct { width: f32, height: f32, baseline: f32 };
pub const RubyOptions = struct {
    side: enum { over, under } = .over,
    gap: f32 = 0,
    /// Alignment of each narrower paragraph inside the composed inline width, 0..1.
    base_factor: f32 = 0.5,
    annotation_factor: f32 = 0.5,
    /// Maximum annotation extension beyond either side of the reserved inline box.
    overhang: f32 = 0,
    reserve_block_space: bool = true,
};
pub const Ruby = struct { box: Box, base: [4]f32, annotation: [4]f32 };

/// Compose measured base and annotation paragraphs. The result's box can be inserted as one
/// inline Object, and its two rects position the original paragraph TextRuns. Shape language,
/// font, size and ruby-specific OpenType features remain explicit inputs to those paragraphs.
pub fn ruby(base: Box, annotation: Box, options: RubyOptions) Ruby {
    const width = @max(base.width, annotation.width - 2 * @max(options.overhang, 0));
    const extension = annotation.height + @max(options.gap, 0);
    const reserve: f32 = @floatFromInt(@intFromBool(options.reserve_block_space));
    const over: f32 = @floatFromInt(@intFromBool(options.side == .over));
    const base_y = extension * reserve * over;
    const note_y = if (options.side == .over) base_y - extension else base_y + base.height + @max(options.gap, 0);
    const base_x = (width - base.width) * std.math.clamp(options.base_factor, 0, 1);
    const note_x = (width - annotation.width) * std.math.clamp(options.annotation_factor, 0, 1);
    return .{
        .box = .{ .width = width, .height = base.height + extension * reserve, .baseline = base_y + base.baseline },
        .base = .{ base_x, base_y, base_x + base.width, base_y + base.height },
        .annotation = .{ note_x, note_y, note_x + annotation.width, note_y + annotation.height },
    };
}

test "inline replacement participates in wrapping baseline metrics and transformed image emission" {
    var p: @import("golden.zig").Para = .{};
    const text = "a\u{fffc}b";
    p.fixed(text, 10);
    var metrics = [_]lines.Metrics{ .{ .ascent = 8, .descent = 2 }, undefined };
    const objects = [_]Object{.{ .byte = 1, .size = .{ 20, 16 }, .baseline = 12, .span = 1 }};
    try measure(&p.g, text, &objects, &metrics, metrics[0]);
    try lines.breakLines(&p.g, text, 30, &p.l);
    lines.place(&p.l, &p.g, text, &metrics, .{ .width = 30 });
    try std.testing.expectEqual(16, p.l.height[0]);
    var placed: [1]Placement = undefined;
    const n = try place(&p.l, &p.g, &objects, &metrics, &placed);
    try std.testing.expectEqual(1, n);
    try std.testing.expectEqual([4]f32{ 10, 0, 30, 16 }, placed[0].rect);
    var out: [1]draw.Quad = undefined;
    const run: draw.TextRun = .{ .rect = .{ 100, 50, 130, 100 }, .clip = .{ 0, 0, 300, 300 }, .px = 10, .start = 0, .bytes = text.len, .font = 0, .color = 0xffffffff, .opacity = 0.5, .xform = .{ 2, 0, 0, 2, 0, 0 } };
    try std.testing.expectEqual(1, try quads(run, &placed, &.{.{}}, &out));
    try std.testing.expectEqual([4]f32{ 110, 50, 130, 66 }, out[0].rect);
    try std.testing.expectEqual(run.xform, out[0].xform);
    try std.testing.expectEqual(0.5, out[0].opacity);
}

test "ruby reserves measured annotation space and becomes one inline object" {
    const composed = ruby(.{ .width = 20, .height = 16, .baseline = 12 }, .{ .width = 30, .height = 8, .baseline = 6 }, .{ .gap = 2 });
    try std.testing.expectEqual(Box{ .width = 30, .height = 26, .baseline = 22 }, composed.box);
    try std.testing.expectEqual([4]f32{ 5, 10, 25, 26 }, composed.base);
    try std.testing.expectEqual([4]f32{ 0, 0, 30, 8 }, composed.annotation);
    var p: @import("golden.zig").Para = .{};
    p.fixed("\u{fffc}", 10);
    var metrics = [_]lines.Metrics{.{ .ascent = 12, .descent = 4 }};
    const object = [_]Object{.{ .byte = 0, .size = .{ composed.box.width, composed.box.height }, .baseline = composed.box.baseline, .span = 0 }};
    try measure(&p.g, "\u{fffc}", &object, &metrics, metrics[0]);
    try lines.breakLines(&p.g, "\u{fffc}", 100, &p.l);
    lines.place(&p.l, &p.g, "\u{fffc}", &metrics, .{ .width = 100 });
    try std.testing.expectEqual(30, lines.widest(&p.l));
    try std.testing.expectEqual(26, lines.stackHeight(&p.l));
}
