//! Text decorations, selections and carets as ordinary quads. Positions come from the same
//! paragraph/query data as glyphs, including bidi fragments. The caller owns all output and
//! selection scratch; no renderer-specific shader or per-widget callback is required.

const std = @import("std");
const lines = @import("lines.zig");
const query = @import("query.zig");
const images = @import("emit.zig");
const draw = @import("../../draw/draw_list.zig");
const Rect = @import("../../core/types.zig").Rect;
const Face = @import("../font/opentype.zig").Face;
const tag = @import("../font/opentype.zig").tag;

pub const Pattern = enum { solid, double, dotted, dashed, wavy };
pub const Style = struct {
    underline: bool = false,
    overline: bool = false,
    strike: bool = false,
    pattern: Pattern = .solid,
    color: ?u32 = null,
    thickness: ?f32 = null,
    /// Offsets from the baseline, positive downwards. Null uses the face's metrics.
    underline_offset: ?f32 = null,
    overline_offset: ?f32 = null,
    strike_offset: ?f32 = null,
    /// Cut decoration segments around actual glyph ink. `ink` must contain a glyph image
    /// per Glyphs row; no heuristic based on character names or script is used.
    skip_ink: bool = false,
};

pub const Metrics = struct {
    thickness: f32,
    underline: f32,
    overline: f32,
    strike: f32,

    /// OpenType post underline and OS/2 strikeout metrics, scaled to logical pixels. Missing
    /// tables use explicit proportional fallbacks, so malformed optional metadata is harmless.
    pub fn of(face: *const Face, px: f32) Metrics {
        const scale = px / @as(f32, @floatFromInt(face.units_per_em));
        const post = (face.dir.find(tag("post")) catch null) orelse &.{};
        const os2 = (face.dir.find(tag("OS/2")) catch null) orelse &.{};
        return .{
            .thickness = @max(0.5, @as(f32, @floatFromInt(metric(post, 10, @intCast(@max(face.units_per_em / 16, 1))))) * scale),
            .underline = -@as(f32, @floatFromInt(metric(post, 8, -@as(i16, @intCast(face.units_per_em / 10))))) * scale,
            .overline = -@as(f32, @floatFromInt(face.ascender)) * scale,
            .strike = -@as(f32, @floatFromInt(metric(os2, 28, @intCast(face.units_per_em / 3)))) * scale,
        };
    }
};

fn metric(table: []const u8, at: usize, fallback: i16) i16 {
    return if (at + 2 <= table.len) std.mem.readInt(i16, table[at..][0..2], .big) else fallback;
}

/// Emits decorations for the source byte range. `rects` needs at least g.len rows: this is
/// an explicit conservative bound for every possible bidi selection fragment. Output
/// exhaustion returns NoSpace after a valid prefix. Pattern tessellation is bounded by out.
pub fn quads(run: draw.TextRun, l: *const lines.Lines, g: *const lines.Glyphs, text: []const u8, range: [2]u32, style: Style, metrics: Metrics, ink: []const images.Image, rects: []Rect, out: []draw.Quad) error{NoSpace}!u32 {
    if (rects.len < g.len or (style.skip_ink and ink.len < g.len)) return error.NoSpace;
    const count = query.selection(l, g, text, range[0], range[1], rects);
    var n: u32 = 0;
    var line: usize = 0;
    const thickness = @max(style.thickness orelse metrics.thickness, 0);
    if (thickness == 0) return 0;
    for (rects[0..count]) |r| {
        while (line + 1 < l.len and l.top[line + 1] <= r.y0) line += 1;
        const offsets = [_]f32{
            style.underline_offset orelse metrics.underline,
            style.overline_offset orelse metrics.overline,
            style.strike_offset orelse metrics.strike,
        };
        for ([_]bool{ style.underline, style.overline, style.strike }, offsets) |enabled, offset| {
            if (!enabled) continue;
            const y = l.baseline[line] + offset;
            if (!style.skip_ink) {
                try patterned(run, r.x0, r.x1, y, thickness, style, out, &n);
                continue;
            }
            // Find the next ink interval intersecting the decoration. Visual x can run in
            // either direction, so each step searches the line's glyph rows without sorting.
            var left = r.x0;
            while (left < r.x1) {
                var block0 = r.x1;
                var block1 = r.x1;
                for (l.first[line]..l.ink[line]) |i| {
                    const b = ink[i].bounds;
                    const base = l.baseline[line] - g.y_offset[i];
                    if (base + b[3] <= y - thickness or base + b[1] >= y + thickness) continue;
                    const x = l.x[line] + g.x[i] + g.x_offset[i];
                    const x0 = x + b[0] - thickness;
                    const x1 = x + b[2] + thickness;
                    if (x1 <= left or x0 >= r.x1) continue;
                    if (x0 < block0) {
                        block0 = x0;
                        block1 = x1;
                    } else if (x0 <= block1) block1 = @max(block1, x1);
                }
                try patterned(run, left, @min(block0, r.x1), y, thickness, style, out, &n);
                left = @min(@max(block1, left + thickness), r.x1);
            }
        }
    }
    return n;
}

fn patterned(run: draw.TextRun, left: f32, right: f32, y: f32, thickness: f32, style: Style, out: []draw.Quad, n: *u32) error{NoSpace}!void {
    if (right <= left) return;
    const color = style.color orelse run.color;
    switch (style.pattern) {
        .solid => try segment(run, .{ left, y }, .{ right, y }, thickness, 0, color, out, n),
        .double => {
            try segment(run, .{ left, y - thickness }, .{ right, y - thickness }, thickness, 0, color, out, n);
            try segment(run, .{ left, y + thickness }, .{ right, y + thickness }, thickness, 0, color, out, n);
        },
        .dotted, .dashed => {
            const length = if (style.pattern == .dotted) thickness else 3 * thickness;
            const radius = if (style.pattern == .dotted) thickness * 0.5 else 0;
            var x = left;
            while (x < right) : (x += length + 2 * thickness)
                try segment(run, .{ x, y }, .{ @min(x + length, right), y }, thickness, radius, color, out, n);
        },
        .wavy => {
            // A sine wave sampled at quarter-thickness intervals. Each segment is an ordinary
            // transformed quad; the output bound is explicit and the phase is paragraph-wide.
            const step = @max(thickness * 0.5, 0.25);
            const omega = 2 * std.math.pi / (6 * thickness);
            var x = left;
            while (x < right) {
                const end = @min(x + step, right);
                try segment(run, .{ x, y + @sin(x * omega) * thickness }, .{ end, y + @sin(end * omega) * thickness }, thickness, thickness * 0.5, color, out, n);
                x = end;
            }
        },
    }
}

fn segment(run: draw.TextRun, from: [2]f32, to: [2]f32, thickness: f32, radius: f32, color: u32, out: []draw.Quad, n: *u32) error{NoSpace}!void {
    if (n.* == out.len) return error.NoSpace;
    const dx = to[0] - from[0];
    const dy = to[1] - from[1];
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    const c = dx / len;
    const s = dy / len;
    const x = run.rect[0] + from[0];
    const y = run.rect[1] + from[1];
    const m = run.xform;
    out[n.*] = .{
        .rect = .{ 0, -thickness * 0.5, len, thickness * 0.5 },
        .clip = run.clip,
        .params = @splat(0),
        .uv = @splat(0),
        .radii = @splat(radius),
        .fill = color,
        .border_color = 0,
        .border = 0,
        .opacity = 1,
        .xform = .{ m[0] * c + m[2] * s, m[1] * c + m[3] * s, m[2] * c - m[0] * s, m[3] * c - m[1] * s, m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5] },
        .clip_radii = run.clip_radii,
    };
    n.* += 1;
}

/// Highlight backgrounds from bidi-aware selection geometry. Call before emitting glyphs.
pub fn selection(run: draw.TextRun, l: *const lines.Lines, g: *const lines.Glyphs, text: []const u8, range: [2]u32, color: u32, scratch: []Rect, out: []draw.Quad) error{NoSpace}!u32 {
    if (scratch.len < g.len) return error.NoSpace;
    const count = query.selection(l, g, text, range[0], range[1], scratch);
    if (out.len < count) return error.NoSpace;
    for (scratch[0..count], out[0..count]) |r, *q| q.* = box(run, r.array(), color);
    return count;
}

pub const CaretShape = enum { bar, block, underline };

/// A caret at a grapheme boundary. `advance` is the desired block/underline width, usually
/// the next grapheme's measured advance; `thickness` is the bar/underline stroke width.
pub fn caret(run: draw.TextRun, l: *const lines.Lines, g: *const lines.Glyphs, text: []const u8, at: u32, shape: CaretShape, thickness: f32, advance: f32, color: u32) draw.Quad {
    const c = query.caret(l, g, text, at);
    const w = if (shape == .bar) thickness else advance;
    const h = if (shape == .underline) thickness else c.height;
    const y = if (shape == .underline) c.top + c.height - h else c.top;
    return box(run, .{ c.x, y, c.x + w, y + h }, color);
}

fn box(run: draw.TextRun, rect: [4]f32, color: u32) draw.Quad {
    return .{
        .rect = .{ run.rect[0] + rect[0], run.rect[1] + rect[1], run.rect[0] + rect[2], run.rect[1] + rect[3] },
        .clip = run.clip,
        .params = @splat(0),
        .uv = @splat(0),
        .radii = @splat(0),
        .fill = color,
        .border_color = 0,
        .border = 0,
        .opacity = 1,
        .xform = run.xform,
        .clip_radii = run.clip_radii,
    };
}

test "decorations consume font metrics patterns ink and transformed selection geometry" {
    const golden = @import("golden.zig");
    var p: golden.Para = .{};
    p.fixed("ab cd", 10);
    try lines.breakLines(&p.g, "ab cd", 30, &p.l);
    lines.place(&p.l, &p.g, "ab cd", &.{.{ .ascent = 8, .descent = 2 }}, .{ .width = 30 });
    const run: draw.TextRun = .{
        .rect = .{ 10, 20, 40, 40 },
        .clip = .{ 0, 0, 100, 100 },
        .start = 0,
        .bytes = 5,
        .px = 10,
        .font = 0,
        .color = 0xffffffff,
        .xform = .{ 2, 0, 0, 2, 3, 4 },
        .clip_radii = @splat(5),
    };
    const face = try Face.parse(golden.font, 0);
    const metrics: Metrics = .of(&face, 10);
    try std.testing.expect(metrics.thickness > 0);
    var rects: [16]Rect = undefined;
    var out: [512]draw.Quad = undefined;
    inline for (.{ Pattern.solid, .double, .dotted, .dashed, .wavy }) |pattern| {
        const n = try quads(run, &p.l, &p.g, "ab cd", .{ 0, 5 }, .{ .underline = true, .strike = true, .pattern = pattern }, metrics, &.{}, &rects, &out);
        try std.testing.expect(n >= 4);
        try std.testing.expectEqual(run.clip_radii, out[0].clip_radii);
    }
    const ink: [5]images.Image = @splat(.{ .bounds = .{ 2, 0, 8, 4 } });
    const n = try quads(run, &p.l, &p.g, "ab cd", .{ 0, 5 }, .{ .underline = true, .skip_ink = true, .underline_offset = 2, .thickness = 1 }, metrics, &ink, &rects, &out);
    try std.testing.expect(n > 2);
    const selected = try selection(run, &p.l, &p.g, "ab cd", .{ 1, 5 }, 0x336699ff, &rects, &out);
    try std.testing.expectEqual(2, selected);
    try std.testing.expectEqual(run.xform, out[0].xform);
    const mark = caret(run, &p.l, &p.g, "ab cd", 1, .underline, 1, 10, 0xff0000ff);
    try std.testing.expectEqual([4]f32{ 20, 29, 30, 30 }, mark.rect);
}
