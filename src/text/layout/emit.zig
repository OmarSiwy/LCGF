//! Positioned paragraph glyphs to ordinary draw-list quads. The host supplies atlas images
//! as rows; this pass never calls a font/atlas callback, allocates, or chooses a renderer.

const std = @import("std");
const lines = @import("lines.zig");
const draw = @import("../../draw/draw_list.zig");
const utf8 = @import("../unicode/utf8.zig");

/// Atlas image bounds relative to the glyph pen and baseline, y down. A zero-sized image
/// contributes no quad (spaces commonly have an advance but no image).
pub const Image = struct {
    bounds: [4]f32 = .{ 0, 0, 0, 0 },
    uv: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const Images = struct {
    /// One image per Glyphs row; the caller can populate them from any atlas or cache.
    glyphs: []const Image,
    /// Image for the actual ellipsis face/glyph reported by Stack, when the text was cut.
    ellipsis: ?Image = null,
    /// Optional authored colours by Glyphs.span. Empty uses effective TextRun.color.
    /// Supplied colours are multiplied by TextRun.opacity, preserving inherited node alpha.
    colors: []const u32 = &.{},
};

pub const Error = error{ NoSpace, MissingEllipsis };

/// Emits the current paragraph at the text run's layout-space rect. Every image carries the
/// run's complete transform and rounded clip, so labels, boxes and hit geometry transform
/// together. Returns quads written. A short output returns NoSpace after a valid prefix.
pub fn quads(run: draw.TextRun, g: *const lines.Glyphs, l: *const lines.Lines, text: []const u8, images: Images, out: []draw.Quad) Error!u32 {
    if (images.glyphs.len < g.len) return error.NoSpace;
    if (l.ellipsis > 0 and images.ellipsis == null) return error.MissingEllipsis;
    var n: u32 = 0;
    for (0..l.len) |k| {
        for (l.first[k]..l.ink[k]) |i| {
            if (hiddenControl(utf8.decode(text, g.cluster[i]).cp)) continue;
            const image = images.glyphs[i];
            if (images.colors.len > 0 and g.span[i] >= images.colors.len) return error.NoSpace;
            const color = if (images.colors.len == 0) run.color else withOpacity(images.colors[g.span[i]], run.opacity);
            try append(run, image, .{
                run.rect[0] + l.x[k] + g.x[i] + g.x_offset[i],
                run.rect[1] + l.baseline[k] - g.y_offset[i],
            }, color, out, &n);
        }
    }
    if (l.len > 0 and l.ellipsis > 0) {
        const k = l.len - 1;
        const at = if (l.ink[k] > l.first[k]) l.ink[k] - 1 else l.first[k];
        const span = if (at < g.len) g.span[at] else 0;
        if (images.colors.len > 0 and span >= images.colors.len) return error.NoSpace;
        const color = if (images.colors.len == 0) run.color else withOpacity(images.colors[span], run.opacity);
        try append(run, images.ellipsis.?, .{
            run.rect[0] + l.x[k] + l.ellipsis_x,
            run.rect[1] + l.baseline[k],
        }, color, out, &n);
    }
    return n;
}

fn withOpacity(color: u32, opacity: f32) u32 {
    const c: @import("../../core/types.zig").Color = @bitCast(color);
    var out = c;
    out.a = @intFromFloat(@round(@as(f32, @floatFromInt(c.a)) * std.math.clamp(opacity, 0, 1)));
    return @bitCast(out);
}

fn append(run: draw.TextRun, image: Image, pen: [2]f32, color: u32, out: []draw.Quad, n: *u32) error{NoSpace}!void {
    const b = image.bounds;
    if (b[0] >= b[2] or b[1] >= b[3]) return;
    if (n.* == out.len) return error.NoSpace;
    out[n.*] = .{
        .rect = .{ pen[0] + b[0], pen[1] + b[1], pen[0] + b[2], pen[1] + b[3] },
        .clip = run.clip,
        .params = @splat(0),
        .uv = image.uv,
        .radii = @splat(0),
        .fill = color,
        .border_color = 0,
        .border = 0,
        .opacity = 1,
        .xform = run.xform,
        .clip_radii = run.clip_radii,
    };
    n.* += 1;
}

fn hiddenControl(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7f and cp <= 0x9f) or
        (cp >= 0x200b and cp <= 0x200f) or (cp >= 0x2028 and cp <= 0x202e) or
        (cp >= 0x2060 and cp <= 0x206f) or cp == 0xfeff;
}

test "paragraph quads carry placement, span colour, marker, transform and rounded clipping" {
    var p: @import("golden.zig").Para = .{};
    p.fixed("abc", 10);
    try lines.breakLines(&p.g, "abc", 100, &p.l);
    lines.ellipsize(&p.l, &p.g, "abc", 25, 1, 5);
    lines.place(&p.l, &p.g, "abc", &.{.{ .ascent = 8, .descent = 2 }}, .{ .width = 25 });
    const image: Image = .{ .bounds = .{ 1, -7, 9, 1 }, .uv = .{ 0, 0, 0.5, 0.5 } };
    const images: [3]Image = @splat(image);
    const run: draw.TextRun = .{
        .rect = .{ 100, 50, 125, 60 },
        .clip = .{ 90, 40, 140, 80 },
        .start = 0,
        .bytes = 3,
        .px = 10,
        .font = 0,
        .color = 0x334455ff,
        .xform = .{ 0, 2, -2, 0, 120, 30 },
        .clip_radii = .{ 2, 3, 4, 5 },
    };
    var out: [4]draw.Quad = undefined;
    try std.testing.expectError(error.MissingEllipsis, quads(run, &p.g, &p.l, "abc", .{ .glyphs = &images }, &out));
    const n = try quads(run, &p.g, &p.l, "abc", .{ .glyphs = &images, .ellipsis = image, .colors = &.{0xff0000ff} }, &out);
    try std.testing.expectEqual(3, n);
    try std.testing.expectEqual([4]f32{ 101, 51, 109, 59 }, out[0].rect);
    try std.testing.expectEqual(@as(f32, 121), out[2].rect[0]);
    try std.testing.expectEqual(0xff0000ff, out[0].fill);
    try std.testing.expectEqual(0xff0000ff, out[2].fill);
    for (out[0..n]) |q| {
        try std.testing.expectEqual(run.xform, q.xform);
        try std.testing.expectEqual(run.clip_radii, q.clip_radii);
    }
    try std.testing.expectError(error.NoSpace, quads(run, &p.g, &p.l, "abc", .{ .glyphs = &images, .ellipsis = image }, out[0..1]));
    p.g.span[0] = 2;
    try std.testing.expectError(error.NoSpace, quads(run, &p.g, &p.l, "abc", .{ .glyphs = &images, .ellipsis = image, .colors = &.{0xffffffff} }, &out));
}
