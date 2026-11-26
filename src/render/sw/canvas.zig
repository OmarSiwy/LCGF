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
    const v = canvas.View.of(c.camera, .{ node.rect[0], node.rect[1] }, scale);
    const red: u5 = @as(u5, @intFromBool(t.fb.format == .bgra8)) * 16;
    for (c.ranges) |r| {
        const end = @min(r.first +| r.count, s.len);
        for (@min(r.first, end)..end) |i| {
            const look = s.c.look[i];
            const sh = canvas.Shape.of(v, s.c.pos[i], look);
            const box = clampBox(pixels(.{ @floor(sh.box[0]), @floor(sh.box[1]), @ceil(sh.box[2]), @ceil(sh.box[3]) }), area);
            // The one coarse branch: most instances of a big canvas are outside this band.
            if (box[0] >= box[2] or box[1] >= box[3]) continue;
            const ink: Ink = .{ .fill = rgba(look[1]), .stroke = rgba(look[3]), .stroked = look[2] != 0, .opacity = node.opacity };
            switch (sh.kind) {
                .polygon => {
                    const first = @min(look[2], s.vert_len);
                    rows(.polygon, t.fb, red, box, &sh, ink, .{ .view = v, .verts = s.verts[first..][0..@min(look[3], s.vert_len - first)] });
                },
                .glyph => if (atlas.alpha8.len != 0)
                    rows(.glyph, t.fb, red, box, &sh, ink, .{ .atlas = atlas, .uv = look, .alpha8 = true })
                else
                    rows(.glyph, t.fb, red, box, &sh, ink, .{ .atlas = atlas, .uv = look, .alpha8 = false }),
                inline else => |kind| rows(kind, t.fb, red, box, &sh, ink, .{}),
            }
        }
    }
}

/// An instance's colours: straight rgba in 0..1.
const Ink = struct { fill: [4]f32, stroke: [4]f32, stroked: bool, opacity: f32 };

/// What a kind reads besides its shape.
const Extra = struct {
    view: canvas.View = undefined,
    verts: []const [2]i32 = &.{},
    atlas: sw.Image = sw.Image.white,
    uv: [4]u32 = .{ 0, 0, 0, 0 },
    alpha8: bool = false,
};

inline fn rows(comptime kind: canvas.Kind, fb: *sw.Framebuffer, red: u5, box: [4]u32, sh: *const canvas.Shape, ink: Ink, x: Extra) void {
    const fill: [4]F = .{ simd.f(ink.fill[0]), simd.f(ink.fill[1]), simd.f(ink.fill[2]), simd.f(ink.fill[3]) };
    const stroke: [4]F = .{ simd.f(ink.stroke[0]), simd.f(ink.stroke[1]), simd.f(ink.stroke[2]), simd.f(ink.stroke[3]) };
    const stroked = simd.f(simd.b2f(ink.stroked));
    // Glyph: the box, and texel coordinates per pixel (nearest, clamped to the uv rect).
    const tu0 = unorm16(x.uv[2]);
    const tv0 = unorm16(x.uv[2] >> 16);
    const tu1 = unorm16(x.uv[3]);
    const tv1 = unorm16(x.uv[3] >> 16);
    const tw: f32 = @floatFromInt(x.atlas.width);
    const th: f32 = @floatFromInt(x.atlas.height);
    const du = (tu1 - tu0) / @max(sh.p[2] - sh.p[0], 1e-6);
    const dv = (tv1 - tv0) / @max(sh.p[3] - sh.p[1], 1e-6);
    for (box[1]..box[3]) |y| {
        const row = fb.pixels[y * fb.stride ..][0..fb.stride];
        const py = simd.f(@as(f32, @floatFromInt(y)) + 0.5);
        var at = std.mem.alignBackward(u32, box[0], W);
        while (at < box[2]) : (at += W) {
            const px = @as(F, @floatFromInt(simd.iota + simd.u(at))) + simd.f(0.5);
            var color = fill;
            const alpha: F = switch (kind) {
                .segment => canvas.coverage(F, canvas.segmentDist(F, px, py, sh)),
                .arc => canvas.coverage(F, canvas.arcDist(F, px, py, sh)),
                .polygon => canvas.coverage(F, canvas.polygonDist(F, px, py, x.view, x.verts)),
                .rect => a: {
                    // Fill inside the outline, the stroke centred on it, as the quad shader
                    // mixes its border over its fill.
                    const d = canvas.rectDist(F, px, py, sh);
                    const outer = canvas.coverage(F, d - simd.f(sh.half));
                    const inner = canvas.coverage(F, d + simd.f(sh.half));
                    const on = (simd.f(1) - inner) * stroked;
                    inline for (0..4) |c| color[c] = fill[c] + (stroke[c] - fill[c]) * on;
                    break :a outer;
                },
                .glyph => a: {
                    const inside = (px >= simd.f(sh.p[0])) & (px < simd.f(sh.p[2])) & (py >= simd.f(sh.p[1])) & (py < simd.f(sh.p[3]));
                    const u = simd.f(tu0) + (px - simd.f(sh.p[0])) * simd.f(du);
                    const v = simd.f(tv0) + (py - simd.f(sh.p[1])) * simd.f(dv);
                    const tx: U = @intFromFloat(@min(@max(@floor(u * simd.f(tw)), simd.f(0)), simd.f(tw - 1)));
                    const ty: U = @intFromFloat(@min(@max(@floor(v * simd.f(th)), simd.f(0)), simd.f(th - 1)));
                    const idx = ty * simd.u(x.atlas.width) + tx;
                    var texel: [4]F = undefined;
                    if (x.alpha8) {
                        var a8: U = undefined;
                        inline for (0..W) |l| a8[l] = x.atlas.alpha8[idx[l]];
                        texel = .{ simd.f(1), simd.f(1), simd.f(1), @as(F, @floatFromInt(a8)) * simd.f(1.0 / 255.0) };
                    } else {
                        var p: U = undefined;
                        inline for (0..W) |l| p[l] = x.atlas.pixels[idx[l]];
                        inline for (0..4) |c| texel[c] = @as(F, @floatFromInt((p >> @splat(8 * c)) & simd.u(255))) * simd.f(1.0 / 255.0);
                    }
                    inline for (0..4) |c| color[c] = fill[c] * texel[c];
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
const draw_list = @import("../../draw/draw_list.zig");

/// A 64 x 32 framebuffer, one canvas node covering `rect` clipped to `clip`, and its instances.
fn Scene(comptime cap: u32) type {
    return struct {
        const Self = @This();
        list_buf: [list_bytes]u8 align(mem.column_align) = undefined,
        shape_buf: [canvas.Instances.requiredBytes(cap, 8)]u8 align(mem.column_align) = undefined,
        px: [sw.Framebuffer.len(64, 32)]u32 = undefined,
        rows: [1]draw_list.CanvasDraw = undefined,
        list: DrawList = undefined,
        shapes: canvas.Instances = undefined,

        const list_bytes = blk: {
            var counter: mem.Carver = .{ .buf = null };
            _ = DrawList.init(&counter, 1, 1, 1);
            break :blk counter.off;
        };

        fn init(s: *Self, rect: [4]f32, clip: [4]f32) void {
            var a: mem.Carver = .{ .buf = &s.list_buf };
            s.list = DrawList.init(&a, 1, 1, 1);
            var b: mem.Carver = .{ .buf = &s.shape_buf };
            s.shapes = .init(&b, cap, 8);
            s.list.customs[0] = .{ .rect = rect, .clip = clip, .data = 0, .id = 0, .node = 0 };
            s.list.custom_len = 1;
            s.list.canvases = &s.rows;
            s.list.cmd.kind[0] = @backingInt(DrawList.Kind.canvas);
            s.list.cmd.first[0] = 0;
            s.list.cmd.count[0] = 1;
            s.list.cmd_len = 1;
        }

        fn frame(s: *Self, cam: canvas.Camera, scissor: [4]u32) sw.Framebuffer {
            s.rows[0] = .{ .instances = &s.shapes, .camera = cam, .ranges = &.{s.shapes.since(0)} };
            var fb = sw.Framebuffer.init(&s.px, 64, 32, .rgba8);
            fb.clear(.black);
            draw(.{ .fb = &fb, .scissor = scissor }, &s.list, 0, 1, sw.Image.white);
            return fb;
        }
    };
}

test "sw canvas: each kind covers its pixels, antialiased at its edge, premultiplied over" {
    var sc: Scene(8) = .{};
    sc.init(.{ 0, 0, 64, 32 }, .{ 0, 0, 64, 32 });
    const red: @import("../../core/types.zig").Color = .rgb(255, 0, 0);
    // A horizontal 4-wide butt segment along y = 4 from x 2 to 20: rows 2..5 full.
    _ = sc.shapes.segment(.{ 2, 4 }, .{ 20, 4 }, .{ .width = 4, .color = red });
    // A 10 x 10 white box at (30, 2) with no stroke; a translucent disc of radius 6 at (52, 20).
    _ = sc.shapes.rect(.{ 30, 2 }, .{ 40, 12 }, .{ .fill = .white });
    _ = sc.shapes.circle(.{ 52, 20 }, 6, .{ .fill = .rgba(0, 0, 255, 128) });
    var fb = sc.frame(.{}, .{ 0, 0, 64, 32 });
    try testing.expectEqual(red, fb.at(10, 2));
    try testing.expectEqual(red, fb.at(10, 5));
    try testing.expectEqual(@import("../../core/types.zig").Color.black, fb.at(10, 6));
    try testing.expectEqual(@import("../../core/types.zig").Color.black, fb.at(20, 4));
    try testing.expectEqual(@import("../../core/types.zig").Color.white, fb.at(35, 7));
    try testing.expectEqual(@import("../../core/types.zig").Color.black, fb.at(40, 7));
    // Half-transparent blue over black: 128 of blue, alpha 255.
    try testing.expectEqual(@import("../../core/types.zig").Color.rgb(0, 0, 128), fb.at(52, 20));
    // The disc's corner box pixel is outside it.
    try testing.expectEqual(@import("../../core/types.zig").Color.black, fb.at(46, 14));
}

test "sw canvas: clipped to the node and the scissor, panned by the camera" {
    var sc: Scene(4) = .{};
    sc.init(.{ 8, 0, 40, 32 }, .{ 0, 0, 24, 32 });
    _ = sc.shapes.rect(.{ 0, 0 }, .{ 64, 32 }, .{ .fill = .white });
    var fb = sc.frame(.{}, .{ 0, 0, 64, 32 });
    const black: @import("../../core/types.zig").Color = .black;
    try testing.expectEqual(black, fb.at(7, 10));
    try testing.expectEqual(@import("../../core/types.zig").Color.white, fb.at(8, 10));
    try testing.expectEqual(@import("../../core/types.zig").Color.white, fb.at(23, 10));
    try testing.expectEqual(black, fb.at(24, 10));
    // A scissor of rows 4..8 only.
    fb = sc.frame(.{}, .{ 0, 4, 64, 8 });
    try testing.expectEqual(black, fb.at(10, 3));
    try testing.expectEqual(@import("../../core/types.zig").Color.white, fb.at(10, 4));
    try testing.expectEqual(black, fb.at(10, 8));
    // The camera moves the world: origin (60, 0) puts the rect's right edge at x 8 + 4 = 12.
    fb = sc.frame(.{ .origin = .{ 60, 0 } }, .{ 0, 0, 64, 32 });
    try testing.expectEqual(@import("../../core/types.zig").Color.white, fb.at(11, 10));
    try testing.expectEqual(black, fb.at(12, 10));
}

test "sw canvas: bands drawn separately give the whole frame" {
    var sc: Scene(8) = .{};
    sc.init(.{ 0, 0, 64, 32 }, .{ 0, 0, 64, 32 });
    _ = sc.shapes.arc(.{ 32, 16 }, 12, .{ .start = 0.3, .sweep = 4, .width = 3, .cap = .round, .color = .white });
    _ = sc.shapes.polygon(&.{ .{ 4, 4 }, .{ 28, 8 }, .{ 10, 28 } }, .{ .fill = .rgba(0, 255, 0, 200) });
    _ = sc.shapes.segment(.{ 40, 30 }, .{ 60, 3 }, .{ .width = 2, .cap = .square, .color = .rgb(255, 128, 0) });
    const whole = sc.frame(.{ .scale = 1 }, .{ 0, 0, 64, 32 });
    var expect: [sw.Framebuffer.len(64, 32)]u32 = undefined;
    @memcpy(&expect, whole.pixels);
    var fb = sw.Framebuffer.init(&sc.px, 64, 32, .rgba8);
    fb.clear(.black);
    sc.rows[0] = .{ .instances = &sc.shapes, .camera = .{}, .ranges = &.{sc.shapes.since(0)} };
    for (0..3) |b| draw(.{ .fb = &fb, .scissor = sw.tile(&fb, @intCast(b), 3) }, &sc.list, 0, 1, sw.Image.white);
    try testing.expectEqualSlices(u32, &expect, fb.pixels);
    // Something was drawn by each kind.
    try testing.expect(fb.at(32 + 12, 16 + 4).g > 0 or fb.at(44, 19).r > 0);
    try testing.expect(fb.at(14, 12).g > 150);
}
