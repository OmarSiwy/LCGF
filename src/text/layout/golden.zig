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
const spans_ = @import("spans.zig");
const query = @import("query.zig");

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
    span: [256]u32 = undefined,
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
    extra: [32]f32 = undefined,
    s_start: [8]u32 = undefined,
    s_font: [8]u16 = undefined,
    s_px: [8]f32 = undefined,
    s_color: [8]u32 = undefined,
    ellipsis_glyph: u16 = 0,
    g: Glyphs = undefined,
    l: Lines = undefined,
    s: spans_.Spans = undefined,

    /// Points `g`, `l` and `s` at the arrays. `Para` must not move afterwards.
    pub fn bind(p: *Para) void {
        p.g = .{ .glyph = &p.glyph, .cluster = &p.cluster, .advance = &p.advance, .x_offset = &p.x_offset, .y_offset = &p.y_offset, .span = &p.span, .x = &p.x };
        p.l = .{ .first = &p.first, .end = &p.end, .ink = &p.ink, .start = &p.start, .width = &p.width, .hard = &p.hard, .x = &p.lx, .top = &p.top, .baseline = &p.baseline, .height = &p.height, .extra = &p.extra };
        p.s = .{ .start = &p.s_start, .font = &p.s_font, .px = &p.s_px, .color = &p.s_color };
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
            p.span[k] = 0;
            p.x[k] = 0;
        }
        p.g.len = @intCast(text.len);
    }

    /// `text` shaped with the built-in shaper, in the spans already pushed to `s`.
    pub fn shaped(p: *Para, shapers: []const shape.Shaper, text: []const u8) !void {
        var cols: RunCols = .{};
        var run = cols.run();
        try spans_.shape(shapers, text, &p.s, &run, &p.g);
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

pub const Scene = enum { wrap, narrow, center, end, justify, clamp, single, rich, carets, frame };

/// A span after the first (which starts at 0 at the scene's `px`).
const SpanSpec = struct { start: u32, px: f32 };

const Spec = struct {
    text: []const u8,
    px: f32,
    /// Left, top and width of the paragraph's box.
    box: [3]f32,
    size: [2]u32,
    factor: f32 = 0,
    justify: bool = false,
    /// Text that does not wrap is broken at an infinite width.
    wrap: bool = true,
    max_lines: u32 = std.math.maxInt(u32),
    spans: []const SpanSpec = &.{},
    /// Draw a caret bar at every byte offset (query.caret).
    carets: bool = false,
};

const para = "Lines of a paragraph can sit at the start, the centre or the end of the box, or fill it.";

fn spec(s: Scene) Spec {
    return switch (s) {
        .wrap => .{ .text = "Type office fluff into a lovely file, then copy every line of it.", .px = 20, .box = .{ 4, 2, 200 }, .size = .{ 208, 88 } },
        .center => .{ .text = para, .px = 18, .box = .{ 4, 2, 200 }, .size = .{ 208, 104 }, .factor = 0.5 },
        .end => .{ .text = para, .px = 18, .box = .{ 4, 2, 200 }, .size = .{ 208, 104 }, .factor = 1 },
        .justify => .{ .text = para, .px = 18, .box = .{ 4, 2, 200 }, .size = .{ 208, 104 }, .justify = true },
        .clamp => .{ .text = para, .px = 18, .box = .{ 4, 2, 200 }, .size = .{ 208, 56 }, .max_lines = 2 },
        .single => .{ .text = "Type office fluff into a lovely file", .px = 16, .box = .{ 4, 2, 150 }, .size = .{ 160, 28 }, .wrap = false, .max_lines = 1 },
        .rich => .{ .text = "Small words, BIG words and small again, all in one paragraph.", .px = 16, .box = .{ 4, 2, 200 }, .size = .{ 208, 124 }, .spans = &.{ .{ .start = 13, .px = 28 }, .{ .start = 22, .px = 16 } } },
        .carets => .{ .text = "An office fluff\nflows on, justified to the end of the box.", .px = 18, .box = .{ 4, 2, 200 }, .size = .{ 208, 84 }, .justify = true, .carets = true },
        .frame => unreachable, // expectFrame
        .narrow => .{ .text = "Pneumonoultramicroscopic words\nbreak hard.", .px = 16, .box = .{ 3, 1, 90 }, .size = .{ 96, 92 } },
    };
}

const max_w = 208;
const max_h = 128;

/// Lays scene `s` out, draws it and compares it with its reference picture.
pub fn expectScene(s: Scene) !void {
    const sp = spec(s);
    const shapers = [_]shape.Shaper{.init(try opentype.Face.parse(font, 0))};
    const shaper = &shapers[0];
    var p: Para = .{};
    p.bind();
    _ = try p.s.push(0, 0, sp.px, 0);
    for (sp.spans) |x| _ = try p.s.push(x.start, 0, x.px, 0);
    try p.shaped(&shapers, sp.text);
    try lines_.breakLines(&p.g, sp.text, if (sp.wrap) sp.box[2] else std.math.inf(f32), &p.l);
    // The ellipsis, shaped like any text.
    var ecols: RunCols = .{};
    var erun = ecols.run();
    try shaper.shape("\u{2026}", &erun, .{});
    try std.testing.expectEqual(1, erun.len);
    p.ellipsis_glyph = erun.glyph[0];
    const ellipsis_w = @as(f32, @floatFromInt(erun.advance[0])) * sp.px / @as(f32, @floatFromInt(shaper.face.units_per_em));
    lines_.ellipsize(&p.l, &p.g, sp.text, sp.box[2], sp.max_lines, ellipsis_w);
    var m: [8]lines_.Metrics = undefined;
    spans_.metrics(&shapers, &p.s, &m);
    lines_.place(&p.l, &p.g, sp.text, m[0..p.s.len], .{ .width = sp.box[2], .factor = sp.factor, .justify = sp.justify });

    var img: [max_w * max_h]u8 = @splat(0);
    const w = sp.size[0];
    const h = sp.size[1];
    // Every line is in the picture.
    try std.testing.expect(sp.box[1] + lines_.stackHeight(&p.l) <= @as(f32, @floatFromInt(h)));
    try draw(&shaper.face, &p, .{ sp.box[0], sp.box[1] }, img[0 .. w * h], w);
    if (sp.carets) for (0..sp.text.len + 1) |i| {
        const c = query.caret(&p.l, &p.g, sp.text, @intCast(i));
        bar(img[0 .. w * h], w, sp.box[0] + c.x, sp.box[1] + c.top, c.height);
    };
    try compare(s, img[0 .. w * h], w, h);
}

/// Composites every inked glyph of `p` at `origin` + its position, by maximum coverage, each at
/// its span's size; the ellipsis at the first span's. Baselines snap to whole pixels (round
/// half up), pen x stays fractional.
pub fn draw(face: *const opentype.Face, p: *const Para, origin: [2]f32, img: []u8, w: u32) !void {
    const em: f32 = @floatFromInt(face.units_per_em);
    for (0..p.l.len) |k| {
        const base: i32 = @intFromFloat(@floor(origin[1] + p.l.baseline[k] + 0.5));
        const left = origin[0] + p.l.x[k];
        for (p.l.first[k]..p.l.ink[k]) |i| {
            try std.testing.expectEqual(0, p.g.y_offset[i]);
            try glyphAt(face, p.g.glyph[i], p.s.px[p.g.span[i]] / em, left + p.g.x[i] + p.g.x_offset[i], base, img, w);
        }
        if (k == p.l.len - 1 and p.l.ellipsis > 0)
            try glyphAt(face, p.ellipsis_glyph, p.s.px[0] / em, left + p.l.width[k] - p.l.ellipsis, base, img, w);
    }
}

/// Composites glyph `id` with its pen at (`x`, baseline row `base`).
fn glyphAt(face: *const opentype.Face, id: u16, scale: f32, x: f32, base: i32, img: []u8, w: u32) !void {
    const h = img.len / w;
    var ocols: raster.TestOutline = .{};
    var acc: [64 * 64]f32 = undefined;
    var cov: [64 * 64]u8 = undefined;
    var o = ocols.outline();
    try face.outline(id, &o);
    const pixel = @floor(x);
    const b = raster.box(&o, scale, x - pixel);
    if (b.w == 0) return;
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

/// A one pixel wide caret bar at fractional `x`, its coverage split between two columns, from
/// row `top` down `height` px (both rounded half up).
fn bar(img: []u8, w: u32, x: f32, top: f32, height: f32) void {
    const col: i32 = @intFromFloat(@floor(x));
    const f = x - @floor(x);
    const cov = [2]u8{ @intFromFloat(@round(255 * (1 - f))), @intFromFloat(@round(255 * f)) };
    const r0: usize = @intFromFloat(@floor(top + 0.5));
    const r1: usize = @intFromFloat(@floor(top + height + 0.5));
    for (r0..@min(r1, img.len / w)) |r| for (0..2) |d| {
        const c = col + @as(i32, @intCast(d));
        if (c < 0 or c >= w) continue;
        const at = r * w + @as(usize, @intCast(c));
        img[at] = @max(img[at], cov[d]);
    };
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

// ---------------------------------------------------------------------------------------------
// The frame scene: the whole stack on the measure / wrap protocol, through layout and paint.

const frame_title = "Text layout";
const frame_para = "The measure and wrap protocol hands every run to the shaper and the line breaker.";

/// Builds a tree, measures and wraps its text with `stack.Stack` in the order of prototype
/// `Frame.end`, lays out and paints it, then draws every draw-list run as the stack lays it out
/// again (`Stack.paragraph`) at the run's rect, and compares with testdata/frame.pgm.
///
///   root  px(240) x px(140), pad 8, gap 6
///   ├ title  "Text layout", 22 px, does not wrap
///   └ col    px(200) x fit
///     └ para   shrinks; 16 px, wraps
pub fn expectFrame() !void {
    const mem = @import("../../core/mem.zig");
    const types = @import("../../core/types.zig");
    const Tree = @import("../../core/tree.zig").Tree;
    const Texts = @import("../../core/texts.zig").Texts;
    const Customs = @import("../../core/customs.zig").Customs;
    const Strings = @import("../../core/strings.zig").Strings;
    const layout = @import("../../layout/layout.zig");
    const paint = @import("../../draw/paint.zig");
    const DrawList = @import("../../draw/draw_list.zig").DrawList;
    const Stack = @import("stack.zig").Stack;

    const Parts = struct {
        t: Tree,
        tx: Texts,
        cu: Customs,
        d: DrawList,
        fn carve(c: *mem.Carver) @This() {
            return .{ .t = .init(c, 8), .tx = .init(c, 4), .cu = .init(c, 1), .d = .init(c, 8, 4, 1) };
        }
    };
    const bytes = comptime blk: {
        @setEvalBranchQuota(10_000);
        var counter: mem.Carver = .{ .buf = null };
        _ = Parts.carve(&counter);
        break :blk counter.off;
    };
    var buf: [bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var parts: Parts = .carve(&carver);
    const t = &parts.t;
    const tx = &parts.tx;
    var str_buf: [256]u8 = undefined;
    var strings: Strings = .{ .buf = &str_buf };

    const root = t.push(0, types.Id.from("root"), &.{ .size = .{ .px(240), .px(140) }, .pad = @splat(8), .gap = 6 });
    const title = t.push(root, .none, &.{});
    t.c.text[title] = tx.push(title, strings.add(frame_title), &.{ .px = 22 });
    const col = t.push(root, .none, &.{ .size = .{ .px(200), .fit } });
    const body = t.push(col, .none, &.{ .shrink = true });
    t.c.text[body] = tx.push(body, strings.add(frame_para), &.{ .px = 16, .wrap = true });
    t.seal(col);
    t.seal(root);

    const shapers = [_]shape.Shaper{.init(try opentype.Face.parse(font, 0))};
    var p: Para = .{};
    p.bind();
    var cols: RunCols = .{};
    var st: Stack = .{ .shapers = &shapers, .run = cols.run(), .g = p.g, .l = p.l };
    var ascent: [4]f32 = undefined;

    // prototype Frame.end, with the stack where Mono was.
    st.measure(tx, &strings, &ascent);
    layout.prepare(t);
    layout.applyText(t, tx, .x);
    layout.fit(t, .x);
    layout.resolve(t, .x, 240);
    layout.textAvail(t, tx);
    st.wrap(tx, &strings, &ascent);
    layout.applyText(t, tx, .y);
    layout.fit(t, .y);
    layout.resolve(t, .y, 140);
    layout.place(t);
    layout.finalize(t);
    paint.emit(t, tx, &parts.cu, strings.buf[0..strings.len], &parts.d);
    try std.testing.expect(!st.overflow);

    const w = 240;
    const h = 140;
    var img: [w * h]u8 = @splat(0);
    const d = &parts.d;
    try std.testing.expectEqual(2, d.run_len);
    for (d.runs[0..d.run_len], 0..) |r, k| {
        try st.paragraph(tx, &strings, k);
        // The draw-time layout is the measured one, and fits its rect.
        try std.testing.expectEqual(tx.c.h[k], lines_.stackHeight(&st.l));
        try std.testing.expect(r.rect[1] + tx.c.h[k] <= r.rect[3] + 0.5);
        p.g.len = st.g.len;
        p.l.len = st.l.len;
        p.l.ellipsis = 0;
        p.s.len = 0;
        _ = try p.s.push(0, 0, r.px, 0);
        try draw(&shapers[0].face, &p, .{ r.rect[0], r.rect[1] }, &img, w);
    }
    try compare(.frame, &img, w, h);
}
