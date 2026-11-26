//! The canvas batch in software: `DrawList.canvases[k]` drawn inside custom draw k, with the
//! distance functions of src/draw/canvas.zig, `simd.lanes` pixels of a row at a time as the
//! quad shader loop does (sw.zig `shadeRows`). The GPU back ends' canvas.wgsl (C4 in
//! docs/plans/schemify.md) repeats this file; the canvas golden holds them to the same pixels.
//!
//! Per instance: one decode (`canvas.Shape.of`), one test of its pixel box against the
//! target's scissor and the node, and one branch on its kind, which picks the loop compiled
//! for it. Per pixel there is no branch. The node clips like a quad's clip, by pixel centre
//! (its rect half open, its clip closed); rounded clip corners and a transformed node are not
//! applied (ponytail: canvases in transformed or rounded parents come with C4's shader).
//! Output is premultiplied "over", in 8 bits per channel through `sw.overColor`.

const std = @import("std");
const simd = @import("../../core/simd.zig");
const canvas = @import("../../draw/canvas.zig");
const DrawList = @import("../../draw/draw_list.zig").DrawList;
const sw = @import("sw.zig");
const draw_list = @import("../../draw/draw_list.zig");

const W = simd.lanes;
const F = simd.F;
const U = simd.U;
const B = simd.B;

/// Draws canvas command `k` of `list` into `t`, `scale` physical pixels per logical one;
/// glyph instances sample `atlas`.
pub fn draw(t: sw.Target, list: *const DrawList, k: u32, scale: f32, atlas: sw.Image) void {
    if (!std.math.isFinite(scale) or scale <= 0) return;
    const node = list.customs[k];
    const c = list.canvases[k];
    const s = c.instances;
    const rect: @Vector(4, f32) = @as(@Vector(4, f32), node.rect) * @as(@Vector(4, f32), @splat(scale));
    const clip: @Vector(4, f32) = @as(@Vector(4, f32), node.clip) * @as(@Vector(4, f32), @splat(scale));
    const half: @Vector(4, f32) = @splat(0.5);
    // Pixel x is drawn when its centre x + 0.5 is in [rect0, rect2) and in [clip0, clip2].
    const lo = @max(@ceil(rect - half), @ceil(clip - half));
    const hi = @min(@ceil(rect - half), @floor(clip - half) + @as(@Vector(4, f32), @splat(1)));
    const area = clampBox(pixels(.{ lo[0], lo[1], hi[2], hi[3] }), t.scissor);
    if (area[0] >= area[2] or area[1] >= area[3]) return;
    const v = canvas.View.of(c.camera, c.palette, .{ node.rect[0], node.rect[1] }, scale);
    const red: u5 = @as(u5, @intFromBool(t.fb.format == .bgra8)) * 16;
    // The area in world units from the origin, widened by the widest stroke the palette can
    // give and a pixel of antialiasing: an instance whose `reach` misses it is skipped on four
    // integer compares, before it is decoded.
    var widest: f32 = 0;
    for (c.palette.layers) |l| widest = @max(widest, l.width);
    const slop = (widest * 4 * v.line + 2) / v.scale;
    const limit: f32 = 2e9;
    const world = [4]i32{
        @intFromFloat(std.math.clamp(@floor((@as(f32, @floatFromInt(area[0])) - v.base[0]) / v.scale - slop), -limit, limit)),
        @intFromFloat(std.math.clamp(@floor((@as(f32, @floatFromInt(area[1])) - v.base[1]) / v.scale - slop), -limit, limit)),
        @intFromFloat(std.math.clamp(@ceil((@as(f32, @floatFromInt(area[2])) - v.base[0]) / v.scale + slop), -limit, limit)),
        @intFromFloat(std.math.clamp(@ceil((@as(f32, @floatFromInt(area[3])) - v.base[1]) / v.scale + slop), -limit, limit)),
    };
    const pos = s.c.pos;
    const looks = s.c.look;
    for (c.ranges) |r| {
        const end = @min(r.first +| r.count, s.len);
        var base: usize = @min(r.first, end);
        while (base < end) : (base += 64) {
            // A tight pass over 64 rows marks the ones that reach the area; only those are
            // decoded and shaded, so a band pays a few instructions for each row it skips.
            const n = @min(64, end - base);
            var hits: u64 = 0;
            for (0..n) |j| {
                const b = canvas.reach(pos[base + j], looks[base + j], v.origin);
                const in = (b[2] >= world[0]) & (b[0] <= world[2]) & (b[3] >= world[1]) & (b[1] <= world[3]);
                hits |= @as(u64, @intFromBool(in)) << @intCast(j);
            }
            while (hits != 0) : (hits &= hits - 1) {
                const i = base + @ctz(hits);
                instance(t, s, &c, v, area, red, node.opacity, atlas, i);
            }
        }
    }
}

/// Decodes and shades row `i`.
inline fn instance(t: sw.Target, s: *const canvas.Instances, c: *const draw_list.CanvasDraw, v: canvas.View, area: [4]u32, red: u5, opacity: f32, atlas: sw.Image, i: usize) void {
    const look = s.c.look[i];
    const layer = canvas.layerRow(c.palette, canvas.layerOf(look));
    if (!canvas.shown(look, layer)) return;
    const sh = canvas.Shape.of(v, s.c.pos[i], look, layer);
    const box = clampBox(pixels(.{ @floor(sh.box[0]), @floor(sh.box[1]), @ceil(sh.box[2]), @ceil(sh.box[3]) }), area);
    if (box[0] >= box[2] or box[1] >= box[3]) return;
    const over = canvas.overrideOf(c.overrides, @intCast(i));
    const ink: Ink = .{
        .fill = rgba(over orelse layer.fill),
        .stroke = rgba(over orelse layer.stroke),
        .filled = sh.filled and layer.flags & 1 != 0,
        .stroked = sh.stroked,
        .opacity = opacity,
    };
    switch (sh.kind) {
        .polygon => {
            const first = @min(look[1], s.vert_len);
            rows(.polygon, t.fb, red, box, &sh, ink, .{ .view = v, .verts = s.verts[first..][0..@min(look[2], s.vert_len - first)] });
        },
        .glyph => if (atlas.alpha8.len != 0)
            rows(.glyph, t.fb, red, box, &sh, ink, .{ .atlas = atlas, .uv = look, .alpha8 = true })
        else
            rows(.glyph, t.fb, red, box, &sh, ink, .{ .atlas = atlas, .uv = look, .alpha8 = false }),
        inline else => |kind| rows(kind, t.fb, red, box, &sh, ink, .{}),
    }
}

/// An instance's colours (straight rgba in 0..1, the layer's or the override's) and what of
/// it is drawn.
const Ink = struct { fill: [4]f32, stroke: [4]f32, filled: bool, stroked: bool, opacity: f32 };

/// What a kind reads besides its shape.
const Extra = struct {
    view: canvas.View = undefined,
    verts: []const [2]i32 = &.{},
    atlas: sw.Image = sw.Image.white,
    uv: [4]u32 = .{ 0, 0, 0, 0 },
    alpha8: bool = false,
};

inline fn rows(comptime kind: canvas.Kind, fb: *sw.Framebuffer, red: u5, box: [4]u32, sh: *const canvas.Shape, ink: Ink, x: Extra) void {
    const stroke: [4]F = .{ simd.f(ink.stroke[0]), simd.f(ink.stroke[1]), simd.f(ink.stroke[2]), simd.f(ink.stroke[3]) };
    // Inside an outline: the fill, or the stroke's colour at alpha 0 when unfilled, so the
    // stroke's inner edge fades out instead of darkening.
    const base: [4]F = if (ink.filled)
        .{ simd.f(ink.fill[0]), simd.f(ink.fill[1]), simd.f(ink.fill[2]), simd.f(ink.fill[3]) }
    else
        .{ stroke[0], stroke[1], stroke[2], simd.f(0) };
    const stroked = simd.f(simd.b2f(ink.stroked));
    const hw = simd.f(sh.half * simd.b2f(ink.stroked));
    // Glyph: texel coordinates per pixel, nearest, clamped to the atlas.
    const tu0 = unorm16(x.uv[1]);
    const tv0 = unorm16(x.uv[1] >> 16);
    const tu1 = unorm16(x.uv[2]);
    const tv1 = unorm16(x.uv[2] >> 16);
    const tw: f32 = @floatFromInt(x.atlas.width);
    const th: f32 = @floatFromInt(x.atlas.height);
    const du = (tu1 - tu0) / @max(sh.p[2], 1e-6);
    const dv = (tv1 - tv0) / @max(sh.p[3], 1e-6);
    for (box[1]..box[3]) |y| {
        const row = fb.pixels[y * fb.stride ..][0..fb.stride];
        const py = simd.f(@as(f32, @floatFromInt(y)) + 0.5);
        var at = std.mem.alignBackward(u32, box[0], W);
        while (at < box[2]) : (at += W) {
            const px = @as(F, @floatFromInt(simd.iota + simd.u(at))) + simd.f(0.5);
            var color = stroke;
            const alpha: F = switch (kind) {
                .segment => a: {
                    const d = canvas.segmentDist(F, px, py, sh);
                    break :a canvas.coverage(F, d[0]) * canvas.dashCover(F, d[1], sh);
                },
                .arc => canvas.coverage(F, canvas.arcDist(F, px, py, sh)),
                .rect, .polygon => a: {
                    // The stroke centred on the outline, mixed over the inside as the quad
                    // shader mixes its border over its fill.
                    const d = if (kind == .rect) canvas.rectDist(F, px, py, sh) else canvas.polygonDist(F, px, py, x.view, x.verts);
                    const outer = canvas.coverage(F, d - hw);
                    const on = (simd.f(1) - canvas.coverage(F, d + hw)) * stroked;
                    inline for (0..4) |c| color[c] = base[c] + (stroke[c] - base[c]) * on;
                    break :a outer;
                },
                .glyph => a: {
                    const l = canvas.glyphLocal(F, px, py, sh);
                    const inside = (l[0] >= simd.f(0)) & (l[0] < simd.f(sh.p[2])) & (l[1] >= simd.f(0)) & (l[1] < simd.f(sh.p[3]));
                    const u = simd.f(tu0) + l[0] * simd.f(du);
                    const v = simd.f(tv0) + l[1] * simd.f(dv);
                    const tx: U = @intFromFloat(@min(@max(@floor(u * simd.f(tw)), simd.f(0)), simd.f(tw - 1)));
                    const ty: U = @intFromFloat(@min(@max(@floor(v * simd.f(th)), simd.f(0)), simd.f(th - 1)));
                    const idx = ty * simd.u(x.atlas.width) + tx;
                    var texel: [4]F = undefined;
                    if (x.alpha8) {
                        var a8: U = undefined;
                        inline for (0..W) |lane| a8[lane] = x.atlas.alpha8[idx[lane]];
                        texel = .{ simd.f(1), simd.f(1), simd.f(1), @as(F, @floatFromInt(a8)) * simd.f(1.0 / 255.0) };
                    } else {
                        var p: U = undefined;
                        inline for (0..W) |lane| p[lane] = x.atlas.pixels[idx[lane]];
                        inline for (0..4) |c| texel[c] = @as(F, @floatFromInt((p >> @splat(8 * c)) & simd.u(255))) * simd.f(1.0 / 255.0);
                    }
                    inline for (0..4) |c| color[c] = stroke[c] * texel[c];
                    break :a @select(f32, inside, simd.f(1), simd.f(0));
                },
            };
            const old: U = row[at..][0..W].*;
            const mask = sw.spanMask(at, box[0], box[2]);
            row[at..][0..W].* = @select(u32, mask, sw.overColor(color, alpha * simd.f(ink.opacity), old, red), old);
        }
    }
}

fn unorm16(v: u32) f32 {
    return @as(f32, @floatFromInt(v & 0xffff)) / 65535;
}

fn rgba(c: u32) [4]f32 {
    const v: @Vector(4, f32) = @floatFromInt(@as(@Vector(4, u8), @bitCast(c)));
    return v / @as(@Vector(4, f32), @splat(255));
}

/// x0, y0, x1, y1 in whole pixels, clamped to [0, 2^24].
fn pixels(box: [4]f32) [4]u32 {
    const p: @Vector(4, u32) = @intFromFloat(@min(@max(@as(@Vector(4, f32), box), @as(@Vector(4, f32), @splat(0))), @as(@Vector(4, f32), @splat(1 << 24))));
    return p;
}

/// `a` cut to `b`, empty at `b`'s edge when it misses (sw.zig's `clampBox`).
fn clampBox(a: [4]u32, b: [4]u32) [4]u32 {
    const lo = @min(@max(a[0], b[0]), b[2]);
    const top = @min(@max(a[1], b[1]), b[3]);
    return .{ lo, top, @max(@min(a[2], b[2]), lo), @max(@min(a[3], b[3]), top) };
}

const testing = std.testing;
const mem = @import("../../core/mem.zig");
const Color = @import("../../core/types.zig").Color;

/// Layers of the tests: 0 red 4 px, 1 white fill and blue stroke 2 px, 2 translucent blue
/// fill, 3 hidden.
const palette: canvas.Palette = .{ .layers = &.{
    .of(.{ .stroke = .rgb(255, 0, 0), .width = 4 }),
    .of(.{ .stroke = .rgb(0, 0, 255), .fill = .white, .width = 2 }),
    .of(.{ .fill = .rgba(0, 0, 255, 128), .width = 0 }),
    .of(.{ .stroke = .white, .visible = false }),
} };

/// A 64 x 32 framebuffer, one canvas node covering `rect` clipped to `clip`, and its instances.
fn Scene(comptime cap: u32) type {
    return struct {
        const Self = @This();
        list_buf: [list_bytes]u8 align(mem.column_align) = undefined,
        shape_buf: [canvas.Instances.requiredBytes(cap, 8, 1)]u8 align(mem.column_align) = undefined,
        px: [sw.Framebuffer.len(64, 32)]u32 = undefined,
        rows: [1]draw_list.CanvasDraw = undefined,
        list: DrawList = undefined,
        shapes: canvas.Instances = undefined,
        overrides: []const canvas.Override = &.{},
        all: [1]canvas.Range = undefined,

        const list_bytes = blk: {
            var counter: mem.Carver = .{ .buf = null };
            _ = DrawList.init(&counter, 1, 1, 1);
            break :blk counter.off;
        };

        fn init(s: *Self, rect: [4]f32, clip: [4]f32) void {
            var a: mem.Carver = .{ .buf = &s.list_buf };
            s.list = DrawList.init(&a, 1, 1, 1);
            var b: mem.Carver = .{ .buf = &s.shape_buf };
            s.shapes = .init(&b, cap, 8, 1);
            s.list.customs[0] = .{ .rect = rect, .clip = clip, .data = 0, .id = 0, .node = 0 };
            s.list.custom_len = 1;
            s.list.canvases = &s.rows;
            s.list.cmd.kind[0] = @backingInt(DrawList.Kind.canvas);
            s.list.cmd.first[0] = 0;
            s.list.cmd.count[0] = 1;
            s.list.cmd_len = 1;
        }

        fn frame(s: *Self, cam: canvas.Camera, scissor: [4]u32, atlas: sw.Image) sw.Framebuffer {
            s.all = .{s.shapes.since(0)};
            s.rows[0] = .{ .instances = &s.shapes, .camera = cam, .ranges = &s.all, .palette = &palette, .overrides = s.overrides };
            var fb = sw.Framebuffer.init(&s.px, 64, 32, .rgba8);
            fb.clear(.black);
            draw(.{ .fb = &fb, .scissor = scissor }, &s.list, 0, 1, atlas);
            return fb;
        }
    };
}

test "sw canvas: each kind covers its pixels in its layer's colours, antialiased, premultiplied" {
    var sc: Scene(8) = .{};
    sc.init(.{ 0, 0, 64, 32 }, .{ 0, 0, 64, 32 });
    // A horizontal 4-wide butt segment along y = 4 from x 2 to 20: rows 2..5 full.
    _ = sc.shapes.segment(.{ 2, 4 }, .{ 20, 4 }, .{});
    // A white 10 x 10 box at (30, 2) stroked blue 2 px on its outline; a translucent disc of
    // radius 6 at (52, 20); a hidden one over the segment.
    _ = sc.shapes.rect(.{ 30, 2 }, .{ 40, 12 }, .{ .layer = 1 });
    _ = sc.shapes.circle(.{ 52, 20 }, 6, .{ .layer = 2, .stroke = false });
    _ = sc.shapes.circle(.{ 10, 4 }, 3, .{ .layer = 3 });
    var fb = sc.frame(.{}, .{ 0, 0, 64, 32 }, sw.Image.white);
    try testing.expectEqual(Color.rgb(255, 0, 0), fb.at(10, 2));
    try testing.expectEqual(Color.rgb(255, 0, 0), fb.at(10, 5));
    try testing.expectEqual(Color.black, fb.at(10, 6));
    try testing.expectEqual(Color.black, fb.at(20, 4));
    try testing.expectEqual(Color.white, fb.at(35, 7));
    try testing.expectEqual(Color.rgb(0, 0, 255), fb.at(30, 7));
    try testing.expectEqual(Color.rgb(0, 0, 255), fb.at(29, 7));
    try testing.expectEqual(Color.black, fb.at(41, 7));
    // Half-transparent blue over black: 128 of blue, alpha 255.
    try testing.expectEqual(Color.rgb(0, 0, 128), fb.at(52, 20));
    try testing.expectEqual(Color.black, fb.at(46, 14));
}

test "sw canvas: overrides recolour ranges, the last match winning; dead rows draw nothing" {
    var sc: Scene(8) = .{};
    sc.init(.{ 0, 0, 64, 32 }, .{ 0, 0, 64, 32 });
    for (0..3) |k| _ = sc.shapes.rect(.{ @intCast(4 + 20 * k), 4 }, .{ @intCast(14 + 20 * k), 14 }, .{ .layer = 1, .stroke = false });
    sc.overrides = &.{ .{ .range = .{ .first = 0, .count = 2 }, .color = @bitCast(Color.rgb(0, 255, 0)) }, .{ .range = .{ .first = 1, .count = 1 }, .color = @bitCast(Color.rgb(255, 255, 0)) } };
    sc.shapes.kill(2);
    const fb = sc.frame(.{}, .{ 0, 0, 64, 32 }, sw.Image.white);
    try testing.expectEqual(Color.rgb(0, 255, 0), fb.at(8, 8));
    try testing.expectEqual(Color.rgb(255, 255, 0), fb.at(28, 8));
    try testing.expectEqual(Color.black, fb.at(48, 8));
}

test "sw canvas: a dashed chain runs on across its joints; a turned glyph samples its texels" {
    var sc: Scene(8) = .{};
    sc.init(.{ 0, 0, 64, 32 }, .{ 0, 0, 64, 32 });
    // Dash 1: 2 px on, 2 off. The second segment starts 6 along the chain, so in the dash's
    // second half: its first two pixels are off.
    _ = sc.shapes.polyline(&.{ .{ 0, 2 }, .{ 6, 2 }, .{ 20, 2 } }, .{ .dash = 1 });
    // A 2 x 1 atlas, left texel 255, right 0, on a 4 x 2 glyph turned a quarter: its x axis runs
    // down the screen from the anchor (40, 10), so rows 10..11 are lit and 12..13 not.
    const texels = [_]u8{ 255, 0 };
    _ = sc.shapes.glyph(.{ 40, 10 }, .{ 4, 2 }, .{ 0, 0, 1, 1 }, .{ .turns = 1 });
    const fb = sc.frame(.{}, .{ 0, 0, 64, 32 }, .{ .width = 2, .height = 1, .alpha8 = &texels });
    try testing.expectEqual(Color.rgb(255, 0, 0), fb.at(0, 2));
    try testing.expectEqual(Color.rgb(255, 0, 0), fb.at(1, 2));
    try testing.expectEqual(Color.black, fb.at(2, 2));
    try testing.expectEqual(Color.black, fb.at(3, 2));
    try testing.expectEqual(Color.black, fb.at(6, 2));
    try testing.expectEqual(Color.black, fb.at(7, 2));
    try testing.expectEqual(Color.rgb(255, 0, 0), fb.at(8, 2));
    // Turned a quarter: the glyph's own y runs toward -x, so it covers x 38..39.
    try testing.expectEqual(Color.rgb(255, 0, 0), fb.at(39, 10));
    try testing.expectEqual(Color.rgb(255, 0, 0), fb.at(38, 11));
    try testing.expectEqual(Color.black, fb.at(39, 12));
    try testing.expectEqual(Color.black, fb.at(40, 10));
}

test "sw canvas: clipped to the node and the scissor, panned by the camera" {
    var sc: Scene(4) = .{};
    sc.init(.{ 8, 0, 40, 32 }, .{ 0, 0, 24, 32 });
    _ = sc.shapes.rect(.{ 0, 0 }, .{ 64, 32 }, .{ .layer = 1, .stroke = false });
    var fb = sc.frame(.{}, .{ 0, 0, 64, 32 }, sw.Image.white);
    try testing.expectEqual(Color.black, fb.at(7, 10));
    try testing.expectEqual(Color.white, fb.at(8, 10));
    try testing.expectEqual(Color.white, fb.at(23, 10));
    try testing.expectEqual(Color.black, fb.at(24, 10));
    fb = sc.frame(.{}, .{ 0, 4, 64, 8 }, sw.Image.white);
    try testing.expectEqual(Color.black, fb.at(10, 3));
    try testing.expectEqual(Color.white, fb.at(10, 4));
    try testing.expectEqual(Color.black, fb.at(10, 8));
    // Origin (60, 0) puts the rect's right edge at x 8 + 4 = 12.
    fb = sc.frame(.{ .origin = .{ 60, 0 } }, .{ 0, 0, 64, 32 }, sw.Image.white);
    try testing.expectEqual(Color.white, fb.at(11, 10));
    try testing.expectEqual(Color.black, fb.at(12, 10));
}

test "sw canvas: bands drawn separately give the whole frame" {
    var sc: Scene(8) = .{};
    sc.init(.{ 0, 0, 64, 32 }, .{ 0, 0, 64, 32 });
    _ = sc.shapes.arc(.{ 32, 16 }, 12, .{ .start = 0.3, .sweep = 4, .cap = .round, .layer = 1 });
    _ = sc.shapes.polygon(&.{ .{ 4, 4 }, .{ 28, 8 }, .{ 10, 28 } }, .{ .layer = 1, .stroke = true });
    _ = sc.shapes.segment(.{ 40, 30 }, .{ 60, 3 }, .{ .cap = .square, .dash = 2 });
    const whole = sc.frame(.{}, .{ 0, 0, 64, 32 }, sw.Image.white);
    var expect: [sw.Framebuffer.len(64, 32)]u32 = undefined;
    @memcpy(&expect, whole.pixels);
    var fb = sw.Framebuffer.init(&sc.px, 64, 32, .rgba8);
    fb.clear(.black);
    for (0..3) |b| draw(.{ .fb = &fb, .scissor = sw.tile(&fb, @intCast(b), 3) }, &sc.list, 0, 1, sw.Image.white);
    try testing.expectEqualSlices(u32, &expect, fb.pixels);
    try testing.expectEqual(Color.white, fb.at(14, 12));
    try testing.expectEqual(Color.rgb(0, 0, 255), fb.at(38, 26));
}
