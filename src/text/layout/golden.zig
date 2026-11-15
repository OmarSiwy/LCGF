//! Golden pictures for text layout: test helpers, no tests of their own.
//!
//! A scene is laid out here with the built-in shaper and src/text/layout/, every inked glyph is
//! rasterised with src/text/raster/ at its pen position, and the picture is compared with
//! testdata/<scene>.pgm, which testdata/make.py drew independently (HarfBuzz, its own breaking
//! rules, FreeType). The scenes below and make.py's SCENES must agree.
//!
//! Only the rasterisers differ when the layout agrees, so the bound is raster.zig's: at most 16
//! levels of 255 on any pixel, and under 2 levels per inked reference pixel on average. A glyph
//! one pixel off, a different break or a missing glyph fails both by far.

const std = @import("std");
const lines_ = @import("lines.zig");
const shape = @import("../shape/shape.zig");
const raster = @import("../raster/raster.zig");
const opentype = @import("../font/opentype.zig");

const Glyphs = lines_.Glyphs;
const Lines = lines_.Lines;

pub const font = @embedFile("testdata/layout.ttf");

/// Columns for a test paragraph: up to 256 glyphs and 32 lines.
pub const Para = struct {
    glyph: [256]u16 = undefined,
    cluster: [256]u32 = undefined,
    advance: [256]f32 = undefined,
    x_offset: [256]f32 = undefined,
    y_offset: [256]f32 = undefined,
    x: [256]f32 = undefined,
    first: [32]u32 = undefined,
    end: [32]u32 = undefined,
    ink: [32]u32 = undefined,
    start: [32]u32 = undefined,
    width: [32]f32 = undefined,
    hard: [32]f32 = undefined,
    lx: [32]f32 = undefined,
    top: [32]f32 = undefined,
    baseline: [32]f32 = undefined,
    height: [32]f32 = undefined,
    g: Glyphs = undefined,
    l: Lines = undefined,

    /// Points `g` and `l` at the arrays. `Para` must not move afterwards.
    pub fn bind(p: *Para) void {
        p.g = .{ .glyph = &p.glyph, .cluster = &p.cluster, .advance = &p.advance, .x_offset = &p.x_offset, .y_offset = &p.y_offset, .x = &p.x };
        p.l = .{ .first = &p.first, .end = &p.end, .ink = &p.ink, .start = &p.start, .width = &p.width, .hard = &p.hard, .x = &p.lx, .top = &p.top, .baseline = &p.baseline, .height = &p.height };
    }

    /// One glyph per byte of ASCII `text`, each `adv` px wide.
    pub fn fixed(p: *Para, text: []const u8, adv: f32) void {
        p.bind();
        for (text, 0..) |byte, k| {
            p.glyph[k] = byte;
            p.cluster[k] = @intCast(k);
            p.advance[k] = adv;
            p.x_offset[k] = 0;
            p.y_offset[k] = 0;
            p.x[k] = 0;
        }
        p.g.len = @intCast(text.len);
    }

    /// `text` shaped with the built-in shaper at `px`.
    pub fn shaped(p: *Para, shaper: *const shape.Shaper, text: []const u8, px: f32) !void {
        p.bind();
        var cols: RunCols = .{};
        var run = cols.run();
        try shaper.shape(text, &run, .{});
        try p.g.append(&run, px / @as(f32, @floatFromInt(shaper.face.units_per_em)), 0);
    }
};

/// Scratch for one shaped run of up to 256 glyphs.
pub const RunCols = struct {
    glyph: [256]u16 = undefined,
    cluster: [256]u32 = undefined,
    advance: [256]i32 = undefined,
    x_offset: [256]i32 = undefined,
    y_offset: [256]i32 = undefined,

    pub fn run(t: *RunCols) shape.Run {
        return .{ .glyph = &t.glyph, .cluster = &t.cluster, .advance = &t.advance, .x_offset = &t.x_offset, .y_offset = &t.y_offset };
    }
};

pub const Scene = enum { wrap, narrow };

const Spec = struct {
    text: []const u8,
    px: f32,
    /// Left, top and width of the paragraph's box.
    box: [3]f32,
    size: [2]u32,
};

fn spec(s: Scene) Spec {
    return switch (s) {
        .wrap => .{ .text = "Type office fluff into a lovely file, then copy every line of it.", .px = 20, .box = .{ 4, 2, 200 }, .size = .{ 208, 88 } },
        .narrow => .{ .text = "Pneumonoultramicroscopic words\nbreak hard.", .px = 16, .box = .{ 3, 1, 90 }, .size = .{ 96, 92 } },
    };
}

const max_w = 208;
const max_h = 120;

/// Lays scene `s` out, draws it and compares it with its reference picture.
pub fn expectScene(s: Scene) !void {
    const sp = spec(s);
    const shaper: shape.Shaper = .init(try opentype.Face.parse(font, 0));
    var p: Para = .{};
    try p.shaped(&shaper, sp.text, sp.px);
    try lines_.breakLines(&p.g, sp.text, sp.box[2], &p.l);
    lines_.place(&p.l, &p.g, .of(&shaper.face, sp.px));

    var img: [max_w * max_h]u8 = @splat(0);
    const w = sp.size[0];
    const h = sp.size[1];
    try draw(&shaper.face, &p, sp.px, .{ sp.box[0], sp.box[1] }, img[0 .. w * h], w);
    try compare(s, img[0 .. w * h], w, h);
}

/// Composites every inked glyph of `p` (laid out at `px`) at `origin` + its position, by
/// maximum coverage. Baselines snap to whole pixels (round half up), pen x stays fractional.
pub fn draw(face: *const opentype.Face, p: *const Para, px: f32, origin: [2]f32, img: []u8, w: u32) !void {
    const h = img.len / w;
    const scale = px / @as(f32, @floatFromInt(face.units_per_em));
    var ocols: raster.TestOutline = .{};
    var acc: [64 * 64]f32 = undefined;
    var cov: [64 * 64]u8 = undefined;
    for (0..p.l.len) |k| {
        const base: i32 = @intFromFloat(@floor(origin[1] + p.l.baseline[k] + 0.5));
        for (p.l.first[k]..p.l.ink[k]) |i| {
            try std.testing.expectEqual(0, p.g.y_offset[i]);
            var o = ocols.outline();
            try face.outline(p.g.glyph[i], &o);
            const x = origin[0] + p.l.x[k] + p.g.x[i] + p.g.x_offset[i];
            const pixel = @floor(x);
            const b = raster.box(&o, scale, x - pixel);
            if (b.w == 0) continue;
            raster.fill(&o, scale, x - pixel, b, &acc);
            raster.coverage(&acc, &cov, @as(usize, b.w) * b.h);
            for (0..b.h) |r| for (0..b.w) |c| {
                const ix = @as(i32, @intFromFloat(pixel)) + b.left + @as(i32, @intCast(c));
                const iy = base - b.top + @as(i32, @intCast(r));
                if (ix < 0 or iy < 0 or ix >= w or iy >= h) continue;
                const at = @as(usize, @intCast(iy)) * w + @as(usize, @intCast(ix));
                img[at] = @max(img[at], cov[r * b.w + c]);
            };
        }
    }
}

fn reference(s: Scene) []const u8 {
    return switch (s) {
        inline else => |t| @embedFile("testdata/" ++ @tagName(t) ++ ".pgm"),
    };
}

fn compare(s: Scene, img: []const u8, w: u32, h: u32) !void {
    const pgm = reference(s);
    var buf: [32]u8 = undefined;
    const header = try std.fmt.bufPrint(&buf, "P5\n{d} {d}\n255\n", .{ w, h });
    try std.testing.expectEqualStrings(header, pgm[0..header.len]);
    const ref = pgm[header.len..];
    try std.testing.expectEqual(img.len, ref.len);
    var max: u32 = 0;
    var sum: u64 = 0;
    var ink: u64 = 0;
    for (img, ref) |a, b| {
        const d: u32 = @abs(@as(i32, a) - b);
        max = @max(max, d);
        sum += d;
        ink += @intFromBool(b != 0);
    }
    errdefer std.debug.print("scene {s}: max {d}, sum {d} over {d} inked pixels\n", .{ @tagName(s), max, sum, ink });
    try std.testing.expect(max <= 16);
    try std.testing.expect(sum < 2 * ink);
    try std.testing.expect(ink > 500);
}
