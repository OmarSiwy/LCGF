//! The canvas batch in software: `DrawList.canvases[k]` drawn inside custom draw k, with the
//! distance functions of src/draw/canvas.zig, `simd.lanes` pixels of a row at a time as the
//! quad shader loop does (sw.zig `shadeRows`). The GPU back ends' src/render/shaders/canvas.wgsl
//! repeats this file; the canvas golden holds them to the same pixels.
//!
//! Per instance: one decode (`canvas.Shape.of`), one test of its pixel box against the
//! target's scissor and the node, and one branch on its kind, which picks the loop compiled
//! for it. Per pixel there is no branch. The node clips like a quad's clip, by pixel centre
//! (its rect half open, its clip closed); rounded clip corners and a transformed node are not
//! applied, here or in canvas.wgsl (ponytail: add both together when a canvas sits in a
//! transformed or rounded parent).
//! Output is premultiplied "over", in 8 bits per channel through `sw.overColor`.

const std = @import("std");
const simd = @import("../../core/simd.zig");
const canvas = @import("../../draw/canvas.zig");
const DrawList = @import("../../draw/draw_list.zig").DrawList;
const sw = @import("sw.zig");
const draw_list = @import("../../draw/draw_list.zig");
const mem = @import("../../core/mem.zig");

const W = simd.lanes;
const F = simd.F;
const U = simd.U;
const B = simd.B;

/// What every band of canvas command `k` shares: the node's pixels inside `scissor`, the
/// view, and that area in world units from the origin, widened by the widest stroke the
/// palette can give and a pixel of antialiasing (`slop`, in pixels). A node under a
/// transformed parent or a rounded clip shades through `space` (`general`).
const Prep = struct {
    c: draw_list.CanvasDraw,
    opacity: f32,
    area: [4]u32,
    v: canvas.View,
    world: [4]i32,
    slop: f32,
    red: u5 = 0,
    general: bool,
    transformed: bool,
    space: Space,
};

/// A pixel in the node, as the quad shader maps one: `m` takes the pixel's centre (physical)
/// to the node's own physical space, where `rect` is the node; `fwd` maps back. The clip and
/// its corner radii are in logical screen units, tested as quads test theirs.
const Space = struct {
    m: [6]f32,
    fwd: [6]f32,
    rect: [4]f32,
    clip_centre: [2]f32,
    clip_half: [2]f32,
    radii: [4]f32,
    rounded: bool,
    inv_scale: f32,
    scale: f32,

    /// `box` (physical, the node's space) on screen: its four corners' bounds.
    fn screen(sp: *const Space, box: [4]f32) [4]f32 {
        const f = sp.fwd;
        var lo: @Vector(2, f32) = @splat(std.math.inf(f32));
        var hi: @Vector(2, f32) = @splat(-std.math.inf(f32));
        for ([_][2]f32{ .{ box[0], box[1] }, .{ box[2], box[1] }, .{ box[0], box[3] }, .{ box[2], box[3] } }) |c| {
            const p: @Vector(2, f32) = .{ f[0] * c[0] + f[2] * c[1] + f[4], f[1] * c[0] + f[3] * c[1] + f[5] };
            lo = @min(lo, p);
            hi = @max(hi, p);
        }
        return .{ lo[0], lo[1], hi[0], hi[1] };
    }
};

fn prep(list: *const DrawList, k: u32, scale: f32, scissor: [4]u32) ?Prep {
    if (!std.math.isFinite(scale) or scale <= 0) return null;
    const node = list.customs[k];
    const c = list.canvases[k];
    const xf: [6]f32 = node.xform;
    const transformed = !std.mem.eql(f32, &xf, &.{ 1, 0, 0, 1, 0, 0 });
    const radii: [4]f32 = node.clip_radii;
    const rounded = @reduce(.Or, @as(@Vector(4, f32), radii) > @as(@Vector(4, f32), @splat(0)));
    const a, const b, const cc, const d, const tx, const ty = xf;
    const det = a * d - b * cc;
    if (transformed and (!std.math.isFinite(det) or det == 0)) return null;
    const s4: @Vector(4, f32) = @splat(scale);
    const rect: @Vector(4, f32) = @as(@Vector(4, f32), node.rect) * s4;
    const clip: @Vector(4, f32) = @as(@Vector(4, f32), node.clip) * s4;
    const space: Space = .{
        .m = .{ d / det, -b / det, -cc / det, a / det, -(d * tx - cc * ty) * scale / det, -(a * ty - b * tx) * scale / det },
        .fwd = .{ a, b, cc, d, tx * scale, ty * scale },
        .rect = rect,
        .clip_centre = .{ (node.clip[0] + node.clip[2]) * 0.5, (node.clip[1] + node.clip[3]) * 0.5 },
        .clip_half = .{ (node.clip[2] - node.clip[0]) * 0.5, (node.clip[3] - node.clip[1]) * 0.5 },
        .radii = radii,
        .rounded = rounded,
        .inv_scale = 1 / scale,
        .scale = scale,
    };
    const half: @Vector(4, f32) = @splat(0.5);
    // Pixel x is drawn when its centre x + 0.5 is in [rect0, rect2) and in [clip0, clip2]. A
    // transformed node is tested per pixel; its area is the bounds of its corners on screen.
    const node_lo: @Vector(4, f32) = if (transformed) @floor(@as(@Vector(4, f32), space.screen(rect))) else @ceil(rect - half);
    const node_hi: @Vector(4, f32) = if (transformed) @ceil(@as(@Vector(4, f32), space.screen(rect))) else @ceil(rect - half);
    const lo = @max(node_lo, @ceil(clip - half));
    const hi = @min(node_hi, @floor(clip - half) + @as(@Vector(4, f32), @splat(1)));
    const area = clampBox(pixels(.{ lo[0], lo[1], hi[2], hi[3] }), scissor);
    if (area[0] >= area[2] or area[1] >= area[3]) return null;
    const v = canvas.View.of(c.camera, c.palette, .{ node.rect[0], node.rect[1] }, scale);
    var widest: f32 = 0;
    for (c.palette.layers) |l| widest = @max(widest, l.width);
    const slop = widest * 4 * v.line + 2;
    const limit: f32 = 2e9;
    // The culled area in the node's own space: the area itself, or under a transform the
    // node's rect (every band then culls against the whole node).
    const box: [4]f32 = if (transformed) rect else .{ @floatFromInt(area[0]), @floatFromInt(area[1]), @floatFromInt(area[2]), @floatFromInt(area[3]) };
    return .{
        .c = c,
        .opacity = node.opacity,
        .area = area,
        .v = v,
        .slop = slop,
        .general = transformed or rounded,
        .transformed = transformed,
        .space = space,
        .world = .{
            @intFromFloat(std.math.clamp(@floor((box[0] - v.base[0] - slop) / v.scale), -limit, limit)),
            @intFromFloat(std.math.clamp(@floor((box[1] - v.base[1] - slop) / v.scale), -limit, limit)),
            @intFromFloat(std.math.clamp(@ceil((box[2] - v.base[0] + slop) / v.scale), -limit, limit)),
            @intFromFloat(std.math.clamp(@ceil((box[3] - v.base[1] + slop) / v.scale), -limit, limit)),
        },
    };
}

/// Draws canvas command `k` of `list` into `t`, `scale` physical pixels per logical one;
/// glyph instances sample `atlas`. Walks every row of the batch: `drawBinned` with a `Bin`
/// built for this frame's bands walks only the band's own.
pub fn draw(t: sw.Target, list: *const DrawList, k: u32, scale: f32, atlas: sw.Image) void {
    drawBinned(t, list, k, scale, atlas, null);
}

/// `draw`, with the rows `bin` holds for `t`'s band when it was built for this command and
/// band; otherwise every row. The pixels are the same either way.
pub fn drawBinned(t: sw.Target, list: *const DrawList, k: u32, scale: f32, atlas: sw.Image, bin: ?*const Bin) void {
    var p = prep(list, k, scale, t.scissor) orelse return;
    p.red = @as(u5, @intFromBool(t.fb.format == .bgra8)) * 16;
    const s = p.c.instances;
    if (bin) |b| if (b.band(list, k, t.scissor)) |rows| {
        for (rows) |i| instance(t, &p, atlas, i);
        return;
    };
    const pos = s.c.pos;
    const looks = s.c.look;
    const world = p.world;
    for (p.c.ranges) |r| {
        const end = @min(r.first +| r.count, s.len);
        var base: usize = @min(r.first, end);
        while (base < end) : (base += 64) {
            // A tight pass over 64 rows marks the ones that reach the area; only those are
            // decoded and shaded, so a band pays a few instructions for each row it skips.
            const n = @min(64, end - base);
            var hits: u64 = 0;
            for (0..n) |j| {
                const b = canvas.reach(pos[base + j], looks[base + j], p.v.origin);
                const in = (b[2] >= world[0]) & (b[0] <= world[2]) & (b[3] >= world[1]) & (b[1] <= world[3]);
                hits |= @as(u64, @intFromBool(in)) << @intCast(j);
            }
            while (hits != 0) : (hits &= hits - 1) {
                const i = base + @ctz(hits);
                instance(t, &p, atlas, i);
            }
        }
    }
}

/// One frame's rows of one canvas command sorted into bands, so each band (thread) walks its
/// own rows instead of the whole batch. Build it once per frame and box, before the bands draw
/// (`sw.Setup.draw` does, with `Setup.bins`). Caller-owned columns, carved like the core's:
///
///   cull   each row's `canvas.reach` box from world 0 (x0, y0, x1, y1), SoA, rebuilt when
///          the instances' revision changes, so a pan or zoom reads them without decoding
///   span   each row's first and last band this frame (`b0 | b1 << 8`; b0 > b1 for none)
///   rows   the bands' lists one after the other, in draw order; a row on a band edge is in
///          both. When they do not fit, the bin is unused and every band walks the batch.
pub const Bin = struct {
    cull: [4][]i32,
    span: []u32,
    rows: []u32,
    starts: []u32,
    /// The rows `build` filled `rows` with, or null when unused.
    list: ?*const DrawList = null,
    k: u32 = 0,
    box: [4]u32 = .{ 0, 0, 0, 0 },
    bands: u32 = 0,
    /// The batch and revision `cull` holds.
    shapes: ?*const canvas.Instances = null,
    revision: u32 = 0,

    pub const max_bands = 64;

    /// For batches of up to `instances` rows (`Instances.cap`) and `rows` list entries (about
    /// the visible rows plus those on band edges; twice `instances` is always enough for
    /// rows no taller than a band).
    pub fn init(carver: *mem.Carver, instances: u32, rows: u32) Bin {
        const n = simd.rows(instances);
        return .{
            .cull = .{ carver.slice(i32, n), carver.slice(i32, n), carver.slice(i32, n), carver.slice(i32, n) },
            .span = carver.slice(u32, n),
            .rows = carver.slice(u32, rows),
            .starts = carver.slice(u32, max_bands + 1),
        };
    }

    pub fn requiredBytes(instances: u32, rows: u32) usize {
        var counter: mem.Carver = .{ .buf = null };
        _ = init(&counter, instances, rows);
        return counter.off;
    }

    /// Sorts canvas command `k`'s visible rows into the `n` bands `box` is drawn in, as
    /// `sw.tile` and `Setup.draw` split it: band j is rows `box[1] + h * j / n` up to
    /// `box[1] + h * (j + 1) / n`.
    pub fn build(b: *Bin, list: *const DrawList, k: u32, scale: f32, box: [4]u32, n_bands: u32) void {
        b.list = null;
        const n = std.math.clamp(n_bands, 1, max_bands);
        const p = prep(list, k, scale, box) orelse return;
        // ponytail: bands of a transformed node are not screen rows of its space; its
        // bands walk the batch.
        if (p.transformed) return;
        const s = p.c.instances;
        std.debug.assert(simd.padded(s.len) <= b.span.len);
        if (b.shapes != s or b.revision != s.revision) b.refresh(s);

        // Each row's bands, W rows a step: its box from the origin, cut by the area, then its
        // pixel rows, one more either way, since bands split on whole rows.
        const o = p.v.origin;
        const I = @Vector(W, i32);
        const h: f32 = @floatFromInt(box[3] - box[1]);
        const per = @as(f32, @floatFromInt(n)) / @max(h, 1);
        const top: f32 = @floatFromInt(box[1]);
        const last: F = @splat(@floatFromInt(n - 1));
        var i: usize = 0;
        while (i < simd.padded(s.len)) : (i += W) {
            const x0 = @as(I, b.cull[0][i..][0..W].*) -% @as(I, @splat(o[0]));
            const y0 = @as(I, b.cull[1][i..][0..W].*) -% @as(I, @splat(o[1]));
            const x1 = @as(I, b.cull[2][i..][0..W].*) -% @as(I, @splat(o[0]));
            const y1 = @as(I, b.cull[3][i..][0..W].*) -% @as(I, @splat(o[1]));
            const w = p.world;
            const in = (x1 >= @as(I, @splat(w[0]))) & (x0 <= @as(I, @splat(w[2]))) & (y1 >= @as(I, @splat(w[1]))) & (y0 <= @as(I, @splat(w[3])));
            const py0 = simd.f(p.v.base[1] - p.slop - 1 - top) + @as(F, @floatFromInt(y0)) * simd.f(p.v.scale);
            const py1 = simd.f(p.v.base[1] + p.slop + 1 - top) + @as(F, @floatFromInt(y1)) * simd.f(p.v.scale);
            const b0: U = @intFromFloat(@min(@max(@floor(py0 * simd.f(per)), simd.f(0)), last));
            const b1: U = @intFromFloat(@min(@max(@floor(py1 * simd.f(per)), simd.f(0)), last));
            b.span[i..][0..W].* = @select(u32, in, b0 | (b1 << @splat(8)), simd.u(1));
        }

        // Count, then place, walking the ranges in draw order.
        const starts = b.starts[0 .. n + 1];
        @memset(starts, 0);
        for (p.c.ranges) |r| {
            const end = @min(r.first +| r.count, s.len);
            for (b.span[@min(r.first, end)..end]) |sp| {
                for ((sp & 255)..(sp >> 8) + 1) |j| starts[j + 1] += 1;
            }
        }
        for (1..n + 1) |j| starts[j] += starts[j - 1];
        if (starts[n] > b.rows.len) return;
        var at: [max_bands]u32 = undefined;
        @memcpy(at[0..n], starts[0..n]);
        for (p.c.ranges) |r| {
            const end = @min(r.first +| r.count, s.len);
            for (@min(r.first, end)..end) |row| {
                const sp = b.span[row];
                for ((sp & 255)..(sp >> 8) + 1) |j| {
                    b.rows[at[j]] = @intCast(row);
                    at[j] += 1;
                }
            }
        }
        b.list = list;
        b.k = k;
        b.box = box;
        b.bands = n;
    }

    /// Every row's `canvas.reach` box from world 0, and empty boxes in the padding.
    fn refresh(b: *Bin, s: *const canvas.Instances) void {
        for (0..s.len) |i| {
            const r = canvas.reach(s.c.pos[i], s.c.look[i], .{ 0, 0 });
            inline for (0..4) |j| b.cull[j][i] = r[j];
        }
        for (s.len..simd.padded(s.len)) |i| {
            b.cull[0][i] = std.math.maxInt(i32);
            b.cull[1][i] = std.math.maxInt(i32);
            b.cull[2][i] = std.math.minInt(i32);
            b.cull[3][i] = std.math.minInt(i32);
        }
        b.shapes = s;
        b.revision = s.revision;
    }

    /// The rows of the band whose rows are `scissor`'s, when this bin was built for command
    /// `k` of `list` and `scissor` is one of its bands.
    pub fn band(b: *const Bin, list: *const DrawList, k: u32, scissor: [4]u32) ?[]const u32 {
        if (b.list != list or b.k != k or scissor[0] != b.box[0] or scissor[2] != b.box[2]) return null;
        const h = b.box[3] - b.box[1];
        for (0..b.bands) |j| {
            const y0 = b.box[1] + h * @as(u32, @intCast(j)) / b.bands;
            const y1 = b.box[1] + h * @as(u32, @intCast(j + 1)) / b.bands;
            if (scissor[1] == y0 and scissor[3] == y1) return b.rows[b.starts[j]..b.starts[j + 1]];
        }
        return null;
    }
};

/// Decodes and shades row `i`.
fn instance(t: sw.Target, p: *const Prep, atlas: sw.Image, i: usize) void {
    const s = p.c.instances;
    const look = s.c.look[i];
    const layer = canvas.layerRow(p.c.palette, canvas.layerOf(look));
    if (!canvas.shown(look, layer)) return;
    const sh = canvas.Shape.of(p.v, s.c.pos[i], look, layer);
    const on_screen = if (p.transformed) p.space.screen(sh.box) else sh.box;
    const box = clampBox(pixels(.{ @floor(on_screen[0]), @floor(on_screen[1]), @ceil(on_screen[2]), @ceil(on_screen[3]) }), p.area);
    if (box[0] >= box[2] or box[1] >= box[3]) return;
    const over = canvas.overrideOf(p.c.overrides, @intCast(i));
    const ink: Ink = .{
        .fill = rgba(over orelse layer.fill),
        .stroke = rgba(over orelse layer.stroke),
        .filled = sh.filled and layer.flags & 1 != 0,
        .stroked = sh.stroked,
        .opacity = p.opacity,
    };
    // One branch per instance on the node's space: the plain loop for nearly every canvas.
    if (p.general) kinds(true, t, p, box, &sh, ink, atlas, look) else kinds(false, t, p, box, &sh, ink, atlas, look);
}

fn kinds(comptime general: bool, t: sw.Target, p: *const Prep, box: [4]u32, sh: *const canvas.Shape, ink: Ink, atlas: sw.Image, look: [4]u32) void {
    const s = p.c.instances;
    const fb = t.fb;
    switch (sh.kind) {
        .polygon => {
            const first = @min(look[1], s.vert_len);
            shade(.polygon, general, fb, p, box, sh, ink, .{ .view = p.v, .verts = s.verts[first..][0..@min(look[2], s.vert_len - first)] });
        },
        .glyph => if (atlas.alpha8.len != 0)
            shade(.glyph, general, fb, p, box, sh, ink, .{ .atlas = atlas, .uv = look, .alpha8 = true })
        else
            shade(.glyph, general, fb, p, box, sh, ink, .{ .atlas = atlas, .uv = look, .alpha8 = false }),
        inline else => |kind| shade(kind, general, fb, p, box, sh, ink, .{}),
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

inline fn shade(comptime kind: canvas.Kind, comptime general: bool, fb: *sw.Framebuffer, p: *const Prep, box: [4]u32, sh: *const canvas.Shape, ink: Ink, x: Extra) void {
    const red = p.red;
    const sp = &p.space;
    const stroke: [4]F = .{ simd.f(ink.stroke[0]), simd.f(ink.stroke[1]), simd.f(ink.stroke[2]), simd.f(ink.stroke[3]) };
    // Inside an outline: the fill, or the stroke's colour at alpha 0 when unfilled, so the
    // stroke's inner edge fades out instead of darkening.
    const base: [4]F = if (ink.filled)
        .{ simd.f(ink.fill[0]), simd.f(ink.fill[1]), simd.f(ink.fill[2]), simd.f(ink.fill[3]) }
    else
        .{ stroke[0], stroke[1], stroke[2], simd.f(0) };
    const stroked = simd.f(simd.b2f(ink.stroked));
    const hw = simd.f(sh.half * simd.b2f(ink.stroked));
    // One colour over the whole instance (segments, arcs, alpha-atlas glyphs, unstroked
    // fills): its 8-bit channels are rounded once here, as `overColor` rounds them per pixel.
    const solid = switch (kind) {
        .segment, .arc => true,
        .glyph => x.alpha8,
        .rect, .polygon => !ink.stroked,
    };
    const one: [4]f32 = if (kind == .rect or kind == .polygon) (if (ink.filled) ink.fill else .{ ink.stroke[0], ink.stroke[1], ink.stroke[2], 0 }) else ink.stroke;
    var c8: [3]U = undefined;
    inline for (0..3) |i| c8[i] = simd.u(@intFromFloat(@round(std.math.clamp(one[i], 0, 1) * 255)));
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
        const sy = simd.f(@as(f32, @floatFromInt(y)) + 0.5);
        var at = std.mem.alignBackward(u32, box[0], W);
        while (at < box[2]) : (at += W) {
            const sx = @as(F, @floatFromInt(simd.iota + simd.u(at))) + simd.f(0.5);
            // The pixel in the node's own space, and how much of it the node and the clip's
            // rounded corners keep (quad.wgsl's clip coverage).
            const m = sp.m;
            const px = if (general) simd.f(m[0]) * sx + simd.f(m[2]) * sy + simd.f(m[4]) else sx;
            const py = if (general) simd.f(m[1]) * sx + simd.f(m[3]) * sy + simd.f(m[5]) else sy;
            const keep: F = if (general) k: {
                const r = sp.rect;
                const in = (px >= simd.f(r[0])) & (px < simd.f(r[2])) & (py >= simd.f(r[1])) & (py < simd.f(r[3]));
                const lx = sx * simd.f(sp.inv_scale) - simd.f(sp.clip_centre[0]);
                const ly = sy * simd.f(sp.inv_scale) - simd.f(sp.clip_centre[1]);
                const hx, const hy = sp.clip_half;
                const corner = sw.roundedBox(lx, ly, hx, hy, sw.cornerRadius(lx, ly, hx, hy, sp.radii)) * simd.f(sp.scale);
                const cov = @select(f32, @as(B, @splat(sp.rounded)), @min(@max(simd.f(0.5) - corner, simd.f(0)), simd.f(1)), simd.f(1));
                break :k @select(f32, in, cov, simd.f(0));
            } else simd.f(1);
            var color = stroke;
            const alpha: F = switch (kind) {
                .segment => a: {
                    const d = canvas.segmentDist(F, px, py, sh);
                    break :a canvas.coverage(F, d[0]) * canvas.dashCover(F, d[1], sh);
                },
                .arc => canvas.coverage(F, canvas.arcDist(F, px, py, sh)) * canvas.dashCover(F, canvas.arcAlong(F, px, py, sh), sh),
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
                        var texels: U = undefined;
                        inline for (0..W) |lane| texels[lane] = x.atlas.pixels[idx[lane]];
                        inline for (0..4) |c| texel[c] = @as(F, @floatFromInt((texels >> @splat(8 * c)) & simd.u(255))) * simd.f(1.0 / 255.0);
                    }
                    inline for (0..4) |c| color[c] = stroke[c] * texel[c];
                    break :a @select(f32, inside, simd.f(1), simd.f(0));
                },
            };
            const a = alpha * keep * simd.f(ink.opacity);
            // A vector the shape misses (a corner of its box, a dash's gap) is left as it is:
            // at alpha 0 "over" gives back every pixel unchanged anyway.
            if (!@reduce(.Or, a > simd.f(0))) continue;
            const old: U = row[at..][0..W].*;
            const mask = sw.spanMask(at, box[0], box[2]);
            // The source alpha exactly as `overColor` makes it, from the colour's alpha.
            const out = if (solid) sw.overSa(c8, @intFromFloat(@round(@min(@max(color[3] * a, simd.f(0)), simd.f(1)) * simd.f(255))), old, red) else sw.overColor(color, a, old, red);
            row[at..][0..W].* = @select(u32, mask, out, old);
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

test "sw canvas: a dashed arc runs its dash along its centre line from its start" {
    var sc: Scene(2) = .{};
    sc.init(.{ 0, 0, 64, 32 }, .{ 0, 0, 64, 32 });
    // Radius 12 around (32, 16), 4 px wide, dash 2: 4 px on, 4 off, from angle 0.
    _ = sc.shapes.arc(.{ 32, 16 }, 12, .{ .dash = 2 });
    const fb = sc.frame(.{}, .{ 0, 0, 64, 32 }, sw.Image.white);
    const at = struct {
        fn px(f: *const sw.Framebuffer, along: f32) Color {
            const a = along / 12;
            return f.at(@intFromFloat(@floor(32 + 12 * @cos(a))), @intFromFloat(@floor(16 + 12 * @sin(a))));
        }
    }.px;
    try testing.expectEqual(Color.rgb(255, 0, 0), at(&fb, 2));
    try testing.expectEqual(Color.black, at(&fb, 6));
    try testing.expectEqual(Color.rgb(255, 0, 0), at(&fb, 10));
    try testing.expectEqual(Color.black, at(&fb, 14));
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

    // Binned: each band walks its own rows (some on two or three bands), in draw order, with
    // the same pixels; a band the bin was not built for walks them all.
    var bin_buf: [Bin.requiredBytes(8, 24)]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &bin_buf };
    var bin: Bin = .init(&carver, 8, 24);
    for (0..2) |pass| {
        bin.build(&sc.list, 0, 1, fb.all(), 3);
        try testing.expect(bin.band(&sc.list, 0, sw.tile(&fb, 1, 3)) != null);
        try testing.expectEqual(null, bin.band(&sc.list, 0, sw.tile(&fb, 1, 4)));
        fb.clear(.black);
        for (0..3) |b| drawBinned(.{ .fb = &fb, .scissor = sw.tile(&fb, @intCast(b), 3) }, &sc.list, 0, 1, sw.Image.white, &bin);
        try testing.expectEqualSlices(u32, &expect, fb.pixels);
        // The second pass pans away: nothing is drawn, from a bin whose cull columns are kept.
        if (pass == 0) {
            sc.rows[0].camera.origin = .{ 1_000, 0 };
            fb.clear(.black);
            @memcpy(&expect, fb.pixels);
        }
    }
    // A list too short for the rows leaves the bin unused, and the bands walk everything.
    var small_buf: [Bin.requiredBytes(8, 1)]u8 align(mem.column_align) = undefined;
    var small_carver: mem.Carver = .{ .buf = &small_buf };
    var small: Bin = .init(&small_carver, 8, 1);
    sc.rows[0].camera.origin = .{ 0, 0 };
    small.build(&sc.list, 0, 1, fb.all(), 3);
    try testing.expectEqual(null, small.band(&sc.list, 0, sw.tile(&fb, 0, 3)));
}

/// Every channel of `a` within `tol` of `b`'s.
fn expectClose(a: []const u32, b: []const u32, tol: u8) !void {
    for (a, b) |x, y| {
        const u: @Vector(4, u8) = @bitCast(x);
        const v: @Vector(4, u8) = @bitCast(y);
        const d = @max(u, v) - @min(u, v);
        if (@reduce(.Max, d) > tol) return error.TestExpectedEqual;
    }
}

test "sw canvas: a turned node and a rounded clip shade as a quad with them does" {
    const rot: [6]f32 = .{ @cos(0.3), @sin(0.3), -@sin(0.3), @cos(0.3), 14, -3 };
    inline for (.{ .{ rot, [4]f32{ 0, 0, 0, 0 } }, .{ [6]f32{ 1, 0, 0, 1, 0, 0 }, [4]f32{ 10, 0, 6, 3 } }, .{ rot, [4]f32{ 8, 8, 8, 8 } } }) |case| {
        var sc: Scene(4) = .{};
        sc.init(.{ 8, 4, 40, 28 }, .{ 6, 2, 50, 30 });
        sc.list.customs[0].xform = case[0];
        sc.list.customs[0].clip_radii = case[1];
        // A white box filling the node, in world units from its corner.
        _ = sc.shapes.rect(.{ 0, 0 }, .{ 32, 24 }, .{ .layer = 1, .stroke = false });
        var got: [sw.Framebuffer.len(64, 32)]u32 = undefined;
        @memcpy(&got, sc.frame(.{}, .{ 0, 0, 64, 32 }, sw.Image.white).pixels);
        var fb = sw.Framebuffer.init(&sc.px, 64, 32, .rgba8);
        fb.clear(.black);
        const q: @import("../../draw/draw_list.zig").Quad = .{ .rect = .{ 8, 4, 40, 28 }, .clip = .{ 6, 2, 50, 30 }, .params = @splat(0), .uv = .{ 0, 0, 1, 1 }, .radii = @splat(0), .fill = @bitCast(Color.white), .border_color = 0, .border = 0, .opacity = 1, .xform = case[0], .clip_radii = case[1] };
        sw.shade(.solid, .{ .fb = &fb, .scissor = fb.all() }, &q, sw.Image.white, 1);
        try expectClose(&got, fb.pixels, 1);
        // Something was drawn, and something cut.
        try testing.expect(std.mem.indexOfScalar(u32, &got, @bitCast(Color.white)) != null);
    }
}
