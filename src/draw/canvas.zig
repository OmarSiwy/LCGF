//! canvas: many 2D primitives in caller-owned columns, drawn under a camera with a palette.
//! Tier 0: no allocator, no OS, no GPU. A schematic, a plot or a map fills `Instances` once
//! (or when it changes); every frame `Frame.canvas` puts one node in the tree with a `Camera`,
//! a `Palette` and the `Range`s to draw, so panning, zooming and recolouring change a few
//! numbers, not the instances. A GPU back end uploads only `Instances.dirty`.
//!
//! Coordinates are i32 world units (milli-units for Schemify). The camera maps a world point w
//! to logical pixels inside the node as
//!
//!     node top-left + offset + f32(w -% origin) * scale
//!
//! with the subtraction in wrapping i32 arithmetic first, so f32 only ever holds the distance
//! from the origin: exact to 2^24 units, and a pan far from 0 loses no precision. The `sw`
//! back end (src/render/sw/canvas.zig) shades with the distance functions below; `hit` tests
//! the pointer with the same ones, so what is selected is what is drawn.
//!
//! ## Instance layout (the GPU contract)
//!
//! Each instance is two rows, `pos` (4 x i32, `sint32x4`) and `look` (4 x u32, `uint32x4`), 32
//! bytes, two instance-step vertex buffers. `look[0]` holds the style bits:
//!
//!   bits  0-3  kind          (segment 0, rect 1, arc 2, polygon 3, glyph 4)
//!   bits  4-5  cap           (butt 0, square 1, round 2)
//!   bit   6    filled        (rect, polygon: fill inside, in the layer's fill colour)
//!   bit   7    stroked       (rect, polygon: stroke the outline; segments and arcs always are)
//!   bit   8    world width   (the width is look[3] world units, not the palette's)
//!   bit   9    dead          (drawn and hit as nothing)
//!   bits 10-13 dash n        (0: solid; else 2n logical px on, 2n off, from the chain start)
//!   bits 14-15 weight - 1    (weight 1..4)
//!   bits 16-17 quarter turns (glyph rotation, clockwise on screen)
//!   bits 24-31 layer         (row of the palette)
//!
//!   kind     pos                      look[1]              look[2]          look[3]
//!   segment  a.x a.y b.x b.y          chain distance at a  0                world width
//!   rect     x0 y0 x1 y1              corner radius        0                world width
//!   arc      cx cy radius 0           0                    start | sweep    world width
//!   polygon  bounding box             first vertex         vertex count     world width
//!   glyph    anchor.x anchor.y w h    u0 | v0              u1 | v1          0
//!
//! Distances, radii and widths are world units. Angles are radians from +x toward +y: `start`
//! a u16 fraction of a turn, `sweep` a u16 where 65535 is a full turn. uv are unorm16. A glyph
//! is the box `w` x `h` from its anchor, turned about it. Polygon vertices are the side column
//! `verts` (CSR by first and count), any shape, filled by the nonzero rule.
//!
//! ## Width and colour
//!
//! An instance's screen width in logical pixels is `weight * layer.width * z`, z being
//! `clamp(camera.zoom, 0.5, 4)` when `Palette.zoom_scale` and 1 otherwise; with the world-width
//! bit it is `look[3] * camera.scale` instead. Strokes are centred on the outline. Segments,
//! arcs, strokes and glyphs take the layer's stroke colour, fills its fill colour; an override
//! whose range holds the instance replaces both (`Frame.canvas`, the last match wins). A layer
//! that is not visible, or past the palette, draws nothing.

const std = @import("std");
const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Mono = @import("../text/protocol.zig").Mono;
const Color = types.Color;

pub const Kind = enum(u4) { segment, rect, arc, polygon, glyph };
/// How a segment or an arc ends: at its end point, half its width past it, or in a half disc.
pub const Cap = enum(u2) { butt, square, round };

/// The `look[0]` bits, as the module doc lays them out.
pub const bit = struct {
    pub const filled: u32 = 1 << 6;
    pub const stroked: u32 = 1 << 7;
    pub const world_width: u32 = 1 << 8;
    pub const dead: u32 = 1 << 9;
};

/// Instances `first` to `first + count`, drawn in that order.
pub const Range = extern struct { first: u32, count: u32 };

/// Instances of `range` drawn in `color` instead of their layer's (a selection, a diff tint).
pub const Override = extern struct { range: Range, color: u32 };

/// One palette row; 16 bytes, so a palette is one GPU uniform array of `vec4u`.
pub const Layer = extern struct {
    stroke: u32,
    fill: u32,
    /// Stroke width at weight 1, logical pixels.
    width: f32,
    /// bit 0: fills drawn; bit 1: visible.
    flags: u32,

    pub fn of(o: struct { stroke: Color = .black, fill: Color = .transparent, width: f32 = 1, fill_on: bool = true, visible: bool = true }) Layer {
        return .{ .stroke = @bitCast(o.stroke), .fill = @bitCast(o.fill), .width = o.width, .flags = @as(u32, @intFromBool(o.fill_on)) | (@as(u32, @intFromBool(o.visible)) << 1) };
    }
};

/// Caller-owned colours and widths per layer (at most 256).
pub const Palette = struct {
    layers: []const Layer,
    /// Widths grow with `Camera.zoom`, clamped to [0.5, 4].
    zoom_scale: bool = false,
};

/// Where the world sits in the node. `origin` is i64 so a host may pan anywhere; instances are
/// measured from its low 32 bits, so content within 2^31 units of the origin is placed exactly.
pub const Camera = struct {
    /// The world point drawn at `offset` from the node's top-left corner.
    origin: [2]i64 = .{ 0, 0 },
    /// Logical pixels per world unit.
    scale: f32 = 1,
    /// Logical pixels from the node's top-left corner to `origin`.
    offset: [2]f32 = .{ 0, 0 },
    /// The host's zoom level (1 = 100 %), which widths follow under `Palette.zoom_scale`.
    zoom: f32 = 1,
};

/// World to pixels for one node, as a GPU uniform: `base + f32(w -% origin) * scale`, in
/// physical pixels; `line` turns a palette width (logical pixels) into physical ones.
pub const View = extern struct {
    origin: [2]i32,
    base: [2]f32,
    scale: f32,
    line: f32,
    /// Physical pixels per logical pixel (dash lengths).
    px: f32,
    zoom_scale: u32,

    /// `cam` inside a node whose top-left corner is at `corner`, `px` pixels per logical pixel.
    pub fn of(cam: Camera, pal: *const Palette, corner: [2]f32, px: f32) View {
        const z = if (pal.zoom_scale) std.math.clamp(cam.zoom, 0.5, 4) else 1;
        return .{
            .origin = .{ @truncate(cam.origin[0]), @truncate(cam.origin[1]) },
            .base = .{ (corner[0] + cam.offset[0]) * px, (corner[1] + cam.offset[1]) * px },
            .scale = cam.scale * px,
            .line = z * px,
            .px = px,
            .zoom_scale = @intFromBool(pal.zoom_scale),
        };
    }

    pub inline fn x(v: View, w: i32) f32 {
        return v.base[0] + @as(f32, @floatFromInt(w -% v.origin[0])) * v.scale;
    }
    pub inline fn y(v: View, w: i32) f32 {
        return v.base[1] + @as(f32, @floatFromInt(w -% v.origin[1])) * v.scale;
    }
    /// A length (radius, distance) in world units, in pixels.
    pub inline fn len(v: View, w: u32) f32 {
        return @as(f32, @floatFromInt(w)) * v.scale;
    }
};

pub const Instances = struct {
    len: u32 = 0,
    cap: u32,
    vert_len: u32 = 0,
    vert_cap: u32,
    /// A builder ran out of rows or vertices: the last row was overwritten, nothing was written
    /// out of bounds.
    overflow: bool = false,
    /// Bumped by every write and part of the canvas node's damage, so a damage-tracking frame
    /// redraws the node when its instances change. Bump it after writing the columns directly.
    revision: u32 = 0,
    /// Rows written since `clearDirty`, coalesced, for a GPU back end to upload only those;
    /// `dirty_all` when they no longer fit `dirty`.
    dirty: []Range,
    dirty_len: u32 = 0,
    dirty_all: bool = true,
    c: Columns,
    /// Polygon vertices, world units.
    verts: [][2]i32,

    pub const Columns = struct {
        pos: [][4]i32,
        look: [][4]u32,
    };

    /// Carves `simd.rows(cap)` instance rows, `verts` polygon vertices and `dirty` dirty
    /// ranges from `carver`; a counting carver sizes the buffer instead (`requiredBytes`).
    pub fn init(carver: *mem.Carver, cap: u32, verts: u32, dirty: u32) Instances {
        std.debug.assert(cap > 0);
        return .{
            .cap = cap,
            .vert_cap = verts,
            .c = carver.columns(Columns, simd.rows(cap)),
            .verts = carver.slice([2]i32, @max(verts, 1)),
            .dirty = carver.slice(Range, @max(dirty, 1)),
        };
    }

    pub fn requiredBytes(cap: u32, verts: u32, dirty: u32) usize {
        var counter: mem.Carver = .{ .buf = null };
        _ = init(&counter, cap, verts, dirty);
        return counter.off;
    }

    /// Empties the batch; everything is dirty.
    pub fn reset(s: *Instances) void {
        s.len = 0;
        s.vert_len = 0;
        s.overflow = false;
        s.revision +%= 1;
        s.dirty_len = 0;
        s.dirty_all = true;
    }

    /// The instances added since `len` was `first`.
    pub fn since(s: *const Instances, first: u32) Range {
        return .{ .first = first, .count = s.len - first };
    }

    /// Records `r` as written: merged into the last dirty range when they touch (builders
    /// append in order, so a batch is one range), else appended; past capacity, everything.
    /// ponytail: merges with the last range only; scattered edits fill the list and fall back.
    pub fn markDirty(s: *Instances, r: Range) void {
        s.revision +%= 1;
        if (s.dirty_all or r.count == 0) return;
        if (s.dirty_len > 0) {
            const last = &s.dirty[s.dirty_len - 1];
            const lo = @min(last.first, r.first);
            const hi = @max(last.first + last.count, r.first + r.count);
            if (r.first <= last.first + last.count and last.first <= r.first + r.count) {
                last.* = .{ .first = lo, .count = hi - lo };
                return;
            }
        }
        if (s.dirty_len == s.dirty.len) {
            s.dirty_all = true;
            return;
        }
        s.dirty[s.dirty_len] = r;
        s.dirty_len += 1;
    }

    /// After the upload: nothing is dirty.
    pub fn clearDirty(s: *Instances) void {
        s.dirty_len = 0;
        s.dirty_all = false;
    }

    /// Instance `i` draws and hits as nothing from now on.
    pub fn kill(s: *Instances, i: u32) void {
        s.c.look[i][0] |= bit.dead;
        s.markDirty(.{ .first = i, .count = 1 });
    }

    /// Appends one row and returns its index.
    fn push(s: *Instances, pos: [4]i32, look: [4]u32) u32 {
        const k = @min(s.len, s.cap - 1);
        s.overflow = simd.orB(s.overflow, s.len >= s.cap);
        s.len = k + 1;
        s.c.pos[k] = pos;
        s.c.look[k] = look;
        s.markDirty(.{ .first = k, .count = 1 });
        return k;
    }

    /// What every stroked builder takes. `width`, when set, is in world units and replaces the
    /// palette's width.
    pub const Line = struct { layer: u8 = 0, weight: u8 = 1, cap: Cap = .butt, dash: u4 = 0, width: ?u32 = null };
    pub const Box = struct { layer: u8 = 0, weight: u8 = 1, fill: bool = true, stroke: bool = true, radius: u32 = 0, width: ?u32 = null };
    pub const Arc = struct { layer: u8 = 0, weight: u8 = 1, start: f32 = 0, sweep: f32 = std.math.tau, cap: Cap = .butt, width: ?u32 = null };
    pub const Area = struct { layer: u8 = 0, weight: u8 = 1, fill: bool = true, stroke: bool = false, width: ?u32 = null };
    pub const Glyph = struct { layer: u8 = 0, turns: u2 = 0 };
    pub const Text = struct { px: u32, layer: u8 = 0, turns: u2 = 0, font: Mono = .{} };

    /// A line from `a` to `b`.
    pub fn segment(s: *Instances, a: [2]i32, b: [2]i32, o: Line) u32 {
        return s.segmentAt(a, b, o, 0);
    }

    fn segmentAt(s: *Instances, a: [2]i32, b: [2]i32, o: Line, chain: u32) u32 {
        return s.push(.{ a[0], a[1], b[0], b[1] }, .{ head(.segment, o.layer, o.weight, o.cap, o.width != null, 0) | (@as(u32, o.dash) << 10), chain, 0, o.width orelse 0 });
    }

    /// One segment per edge of the open chain through `points`, each with the chain's caps and
    /// its distance from the chain's start, so a dash runs on across the joints.
    pub fn polyline(s: *Instances, points: []const [2]i32, o: Line) Range {
        const first = s.len;
        var chain: f64 = 0;
        for (points[0..points.len -| 1], points[@min(points.len, 1)..]) |a, b| {
            _ = s.segmentAt(a, b, o, @intFromFloat(@min(@round(chain), std.math.maxInt(u32))));
            const dx: f64 = @floatFromInt(@as(i64, b[0]) - a[0]);
            const dy: f64 = @floatFromInt(@as(i64, b[1]) - a[1]);
            chain += @sqrt(dx * dx + dy * dy);
        }
        return s.since(first);
    }

    /// The box from `lo` to `hi`, filled and its outline stroked as `o` says; corners rounded
    /// by `radius` (capped at half the shorter side).
    pub fn rect(s: *Instances, lo: [2]i32, hi: [2]i32, o: Box) u32 {
        const flags = (bit.filled * @intFromBool(o.fill)) | (bit.stroked * @intFromBool(o.stroke));
        return s.push(.{ lo[0], lo[1], hi[0], hi[1] }, .{ head(.rect, o.layer, o.weight, .butt, o.width != null, 0) | flags, o.radius, 0, o.width orelse 0 });
    }

    /// A disc of radius `r` around `c`: a rect rounded by its half side.
    pub fn circle(s: *Instances, c: [2]i32, r: u32, o: Box) u32 {
        var b = o;
        b.radius = r;
        const ri: i32 = @intCast(r);
        return s.rect(.{ c[0] - ri, c[1] - ri }, .{ c[0] + ri, c[1] + ri }, b);
    }

    /// The circle of radius `r` around `c` from angle `start` through `sweep` (a negative sweep
    /// runs the other way). ponytail: no dash on arcs.
    pub fn arc(s: *Instances, c: [2]i32, r: u32, o: Arc) u32 {
        const sweep = @min(@abs(o.sweep), std.math.tau);
        const start = o.start + @min(o.sweep, 0);
        const frac = @mod(start / std.math.tau, 1);
        const a = @as(u32, @intFromFloat(@round(frac * 65536))) & 0xffff;
        const b: u32 = @intFromFloat(@round(sweep / std.math.tau * 65535));
        return s.push(.{ c[0], c[1], @intCast(r), 0 }, .{ head(.arc, o.layer, o.weight, o.cap, o.width != null, 0), 0, a | (b << 16), o.width orelse 0 });
    }

    /// The closed polygon through `points`, any shape, filled by the nonzero rule, its outline
    /// stroked over the fill when `o.stroke`. Its vertices go to `verts`; a polygon that does
    /// not fit is dropped and `overflow` set.
    pub fn polygon(s: *Instances, points: []const [2]i32, o: Area) u32 {
        const n: u32 = @intCast(points.len);
        const fits = n <= s.vert_cap - @min(s.vert_len, s.vert_cap);
        s.overflow = simd.orB(s.overflow, !fits);
        const count = n * @intFromBool(fits);
        const first = s.vert_len;
        @memcpy(s.verts[first..][0..count], points[0..count]);
        s.vert_len += count;
        var lo: @Vector(2, i32) = @splat(std.math.maxInt(i32));
        var hi: @Vector(2, i32) = @splat(std.math.minInt(i32));
        for (points[0..count]) |p| {
            lo = @min(lo, @as(@Vector(2, i32), p));
            hi = @max(hi, @as(@Vector(2, i32), p));
        }
        hi = @max(lo, hi);
        const flags = (bit.filled * @intFromBool(o.fill)) | (bit.stroked * @intFromBool(o.stroke));
        return s.push(.{ lo[0], lo[1], hi[0], hi[1] }, .{ head(.polygon, o.layer, o.weight, .butt, o.width != null, 0) | flags, first, count, o.width orelse 0 });
    }

    /// Atlas `uv` (u0, v0, u1, v1, 0..1) on the box `size` world units from `anchor`, turned
    /// about it by `o.turns` quarter turns; the atlas is the glyph atlas the renderer was given
    /// (`iface.Glyphs.texture`), tinted by the layer's stroke colour.
    pub fn glyph(s: *Instances, anchor: [2]i32, size: [2]u32, uv: [4]f32, o: Glyph) u32 {
        return s.push(.{ anchor[0], anchor[1], @intCast(size[0]), @intCast(size[1]) }, .{ head(.glyph, o.layer, 1, .butt, false, o.turns), unorm16(uv[0]) | (unorm16(uv[1]) << 16), unorm16(uv[2]) | (unorm16(uv[3]) << 16), 0 });
    }

    /// `bytes` on one line from `origin` (the first glyph's anchor), `o.px` world units tall
    /// and turned with it, with the metrics and 16 x 16 byte atlas of `protocol.Mono`. A
    /// shaper of your own calls `glyph`.
    pub fn glyphs(s: *Instances, bytes: []const u8, origin: [2]i32, o: Text) Range {
        const first = s.len;
        const px: f32 = @floatFromInt(o.px);
        const adv = px * o.font.advance;
        const c, const sn = turn(o.turns);
        for (bytes, 0..) |byte, j| {
            const x0: i32 = @intFromFloat(@round(adv * @as(f32, @floatFromInt(j))));
            const x1: i32 = @intFromFloat(@round(adv * @as(f32, @floatFromInt(j + 1))));
            const at = [2]i32{ origin[0] + @as(i32, @intFromFloat(c)) * x0, origin[1] + @as(i32, @intFromFloat(sn)) * x0 };
            const cx: f32 = @floatFromInt(byte & 15);
            const cy: f32 = @floatFromInt(byte >> 4);
            _ = s.glyph(at, .{ @intCast(x1 - x0), @intFromFloat(@round(px * o.font.line)) }, .{ cx / 16, cy / 16, (cx + 1) / 16, (cy + 1) / 16 }, .{ .layer = o.layer, .turns = o.turns });
        }
        return s.since(first);
    }
};

fn head(k: Kind, layer: u8, weight: u8, cap: Cap, world: bool, turns: u2) u32 {
    const w: u32 = std.math.clamp(weight, 1, 4) - 1;
    return @as(u32, @backingInt(k)) | (@as(u32, @backingInt(cap)) << 4) | (bit.world_width * @intFromBool(world)) |
        (w << 14) | (@as(u32, turns) << 16) | (@as(u32, layer) << 24);
}

fn unorm16(v: f32) u32 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 65535));
}

/// cos and sin of `q` quarter turns: the turn that takes a glyph's own x axis to the screen's.
pub fn turn(q: u2) [2]f32 {
    const c = [4]f32{ 1, 0, -1, 0 };
    return .{ c[q], c[q -% 1] };
}

pub inline fn kindOf(look: [4]u32) Kind {
    return @fromBackingInt(@intCast(@as(u4, @truncate(look[0]))));
}

pub inline fn layerOf(look: [4]u32) u8 {
    return @truncate(look[0] >> 24);
}

/// The box instance `pos`, `look` can touch, in world units from `origin` (wrapping), widened
/// by its world width but not by a palette width: integers only, so a renderer can cull most
/// rows of a big batch before decoding them (`Shape.of`). Wrapping arithmetic: a row within
/// 2^30 units of the origin is placed exactly, which is what is drawn anyway.
pub inline fn reach(pos: [4]i32, look: [4]u32, origin: [2]i32) [4]i32 {
    // Arcs and glyphs are their first point grown by `e` (an arc's pos[3] is 0); the others
    // span their two points. Masks, not branches: this runs for every row of every band.
    const kind = look[0] & 15;
    const centred = -%@as(i32, @intFromBool(kind == @backingInt(Kind.arc) or kind == @backingInt(Kind.glyph)));
    const e = @max(pos[2], pos[3]) & centred;
    const pad: i32 = @bitCast(look[3] & -%((look[0] >> 8) & 1));
    const a: @Vector(2, i32) = .{ pos[0] -% origin[0], pos[1] -% origin[1] };
    const far: @Vector(2, i32) = .{ pos[2] -% origin[0], pos[3] -% origin[1] };
    const b = far ^ ((far ^ a) & @as(@Vector(2, i32), @splat(centred)));
    const grow: @Vector(2, i32) = @splat(e +% pad);
    const lo = @min(a, b) -% grow;
    const hi = @max(a, b) +% grow;
    return .{ lo[0], lo[1], hi[0], hi[1] };
}

/// One instance in pixels: what the shaders read, decoded once per instance.
pub const Shape = struct {
    kind: Kind,
    /// Segment: a, b. Rect: x0, y0, x1, y1. Arc: centre, then 0, 0. Polygon: its box. Glyph:
    /// anchor, width, height.
    p: [4]f32,
    /// Half the stroke width.
    half: f32,
    /// Rect: corner radius. Arc: radius.
    radius: f32,
    /// Square caps: 1.
    square: f32,
    round: bool,
    filled: bool,
    stroked: bool,
    /// Segment: the chain distance at a, and the dash's on length and period (0: solid).
    chain: f32 = 0,
    dash: f32 = 0,
    period: f32 = 0,
    /// Arc: the direction of its middle (cos, sin) and its half aperture (sin, cos). Glyph:
    /// `mid` is its turn (cos, sin).
    mid: [2]f32 = .{ 1, 0 },
    aperture: [2]f32 = .{ 0, 1 },
    /// Arc: added to how far past its ends a point is; -inf for a full turn, which has none
    /// (its two butt ends would otherwise meet in a half-covered seam).
    seam: f32 = 0,
    /// Pixel box the shape can touch, x0, y0, x1, y1: coverage `0.5 - d` is 0 past half a
    /// pixel from the outline, so that much antialiasing is included.
    box: [4]f32 = undefined,

    /// `layer` is the instance's palette row.
    pub fn of(v: View, pos: [4]i32, look: [4]u32, layer: Layer) Shape {
        const kind = kindOf(look);
        const h = look[0];
        const cap: Cap = @fromBackingInt(@intCast(@as(u2, @truncate(h >> 4))));
        const weight: f32 = @floatFromInt(((h >> 14) & 3) + 1);
        const width = if (h & bit.world_width != 0) v.len(look[3]) else weight * layer.width * v.line;
        const corner = [4]f32{ v.x(pos[0]), v.y(pos[1]), v.x(pos[2]), v.y(pos[3]) };
        const dash: f32 = @floatFromInt((h >> 10) & 15);
        var sh: Shape = .{
            .kind = kind,
            .p = corner,
            .half = width * 0.5,
            .radius = v.len(look[1]),
            .square = simd.b2f(cap == .square),
            .round = cap == .round,
            .filled = h & bit.filled != 0,
            .stroked = h & bit.stroked != 0 or kind == .segment or kind == .arc,
        };
        var grow: f32 = sh.half * @intFromBool(sh.stroked);
        switch (kind) {
            .segment => {
                // Only a square cap's corners reach past half the width on an axis.
                grow = sh.half * (1 + (std.math.sqrt2 - 1) * sh.square);
                sh.chain = v.len(look[1]);
                sh.dash = 2 * dash * v.px;
                sh.period = 2 * sh.dash;
            },
            .rect, .polygon => {},
            .arc => {
                const r = v.len(@bitCast(pos[2]));
                const start: f32 = @floatFromInt(look[2] & 0xffff);
                const sweep = @as(f32, @floatFromInt(look[2] >> 16)) / 65535 * std.math.tau;
                const m = start / 65536 * std.math.tau + sweep / 2;
                sh.radius = r;
                sh.mid = .{ @cos(m), @sin(m) };
                // sin of a half aperture in [0, pi] is never negative; rounding at pi must not
                // make the far side of a full ring "past its end".
                sh.aperture = .{ @max(@sin(sweep / 2), 0), @cos(sweep / 2) };
                sh.seam = simd.selF(look[2] >> 16 == 0xffff, -std.math.inf(f32), 0);
                sh.p = .{ corner[0], corner[1], 0, 0 };
                const e = r + sh.half + 0.5;
                sh.box = .{ corner[0] - e, corner[1] - e, corner[0] + e, corner[1] + e };
                return sh;
            },
            .glyph => {
                const w = v.len(@bitCast(pos[2]));
                const gh = v.len(@bitCast(pos[3]));
                sh.mid = turn(@truncate(h >> 16));
                sh.p = .{ corner[0], corner[1], w, gh };
                const e = @max(w, gh);
                sh.box = .{ corner[0] - e - 1, corner[1] - e - 1, corner[0] + e + 1, corner[1] + e + 1 };
                return sh;
            },
        }
        sh.box = .{
            @min(corner[0], corner[2]) - grow - 0.5, @min(corner[1], corner[3]) - grow - 0.5,
            @max(corner[0], corner[2]) + grow + 0.5, @max(corner[1], corner[3]) + grow + 0.5,
        };
        return sh;
    }
};

/// Palette row `layer`, or an invisible one past the palette.
pub fn layerRow(pal: *const Palette, layer: u8) Layer {
    if (layer >= pal.layers.len) return .{ .stroke = 0, .fill = 0, .width = 0, .flags = 0 };
    return pal.layers[layer];
}

/// Whether instance `look` on `layer` draws at all: alive and on a visible layer.
pub inline fn shown(look: [4]u32, layer: Layer) bool {
    return look[0] & bit.dead == 0 and layer.flags & 2 != 0;
}

/// The colour override for instance `i`, if any: the last of `overrides` whose range holds it.
pub fn overrideOf(overrides: []const Override, i: u32) ?u32 {
    var found: ?u32 = null;
    for (overrides) |o| {
        if (i -% o.range.first < o.range.count) found = o.color;
    }
    return found;
}

// ---- distance functions: signed, in pixels, negative inside. Generic over the vector type: the
// sw back end runs them over a row of pixels, `hit` over one point. canvas.wgsl repeats them.

inline fn sel(comptime V: type, c: @Vector(@typeInfo(V).vector.len, bool), a: V, b: V) V {
    return @select(f32, c, a, b);
}

inline fn splat(comptime V: type, x: f32) V {
    return @splat(x);
}

inline fn length(x: anytype, y: @TypeOf(x)) @TypeOf(x) {
    return @sqrt(x * x + y * y);
}

/// A box of half size (qx, qy) measured from its centre: `|p| - half` per axis in, distance out.
inline fn boxDist(comptime V: type, qx: V, qy: V) V {
    const z = splat(V, 0);
    return length(@max(qx, z), @max(qy, z)) + @min(@max(qx, qy), z);
}

/// The segment `sh` (a to b, `half` either side, its caps). Also returns how far along the
/// chain p is (pixels from the chain's start), for the dash.
pub inline fn segmentDist(comptime V: type, px: V, py: V, sh: *const Shape) [2]V {
    const dx = sh.p[2] - sh.p[0];
    const dy = sh.p[3] - sh.p[1];
    const l = @sqrt(dx * dx + dy * dy);
    const k = 1 / @max(l, 1e-6);
    const ux = simd.selF(l > 1e-6, dx * k, 1);
    const uy = dy * k;
    const ox = px - splat(V, sh.p[0]);
    const oy = py - splat(V, sh.p[1]);
    const t = ox * splat(V, ux) + oy * splat(V, uy);
    const h = splat(V, l * 0.5);
    const along = @abs(t - h);
    const across = @abs(oy * splat(V, ux) - ox * splat(V, uy));
    const hw = splat(V, sh.half);
    const capsule = length(@max(along - h, splat(V, 0)), across) - hw;
    const box = boxDist(V, along - h - hw * splat(V, sh.square), across - hw);
    return .{ if (sh.round) capsule else box, t + splat(V, sh.chain) };
}

/// How much of a dash is on at chain distance `at` (pixels): 1 for a solid line.
pub inline fn dashCover(comptime V: type, at: V, sh: *const Shape) V {
    if (sh.period == 0) return splat(V, 1);
    const p = splat(V, sh.period);
    const m = at - @floor(at / p) * p;
    return @min(@max(@min(m, splat(V, sh.dash) - m) + splat(V, 0.5), splat(V, 0)), splat(V, 1));
}

/// The rounded box `sh` (the shader's `rounded_box` with one radius), outline at distance 0.
pub inline fn rectDist(comptime V: type, px: V, py: V, sh: *const Shape) V {
    const hx = @abs(sh.p[2] - sh.p[0]) * 0.5;
    const hy = @abs(sh.p[3] - sh.p[1]) * 0.5;
    const r = splat(V, @min(sh.radius, @min(hx, hy)));
    const qx = @abs(px - splat(V, (sh.p[0] + sh.p[2]) * 0.5)) - splat(V, hx) + r;
    const qy = @abs(py - splat(V, (sh.p[1] + sh.p[3]) * 0.5)) - splat(V, hy) + r;
    return boxDist(V, qx, qy) - r;
}

/// The arc `sh`: a ring sector around its centre, `half` either side of `radius`, with caps.
pub inline fn arcDist(comptime V: type, px: V, py: V, sh: *const Shape) V {
    const lx = px - splat(V, sh.p[0]);
    const ly = py - splat(V, sh.p[1]);
    // Into the frame where the arc's middle points along +y and it is mirrored about y.
    const y = lx * splat(V, sh.mid[0]) + ly * splat(V, sh.mid[1]);
    const x = @abs(ly * splat(V, sh.mid[0]) - lx * splat(V, sh.mid[1]));
    const sa, const ca = sh.aperture;
    const ring = @abs(length(x, y) - splat(V, sh.radius)) - splat(V, sh.half);
    // How far past the end's radial line: positive outside the sector.
    const past = x * splat(V, ca) - y * splat(V, sa) + splat(V, sh.seam);
    const disc = length(x - splat(V, sa * sh.radius), y - splat(V, ca * sh.radius)) - splat(V, sh.half);
    const flat = @max(ring, past - splat(V, sh.half * sh.square));
    return if (sh.round) sel(V, past > splat(V, 0), disc, ring) else flat;
}

/// The polygon of `verts` under `v`, nonzero rule: distance to its nearest edge, negative inside.
/// Loops over the edges; the lanes are pixels (or one point).
pub inline fn polygonDist(comptime V: type, px: V, py: V, v: View, verts: []const [2]i32) V {
    const n = @typeInfo(V).vector.len;
    const I = @Vector(n, i32);
    const z = splat(V, 0);
    var best = splat(V, std.math.inf(f32));
    var winding: I = @splat(0);
    if (verts.len == 0) return best;
    var ax = v.x(verts[verts.len - 1][0]);
    var ay = v.y(verts[verts.len - 1][1]);
    for (verts) |p| {
        const bx = v.x(p[0]);
        const by = v.y(p[1]);
        const ex = bx - ax;
        const ey = by - ay;
        const wx = px - splat(V, ax);
        const wy = py - splat(V, ay);
        const t = @min(@max((wx * splat(V, ex) + wy * splat(V, ey)) * splat(V, 1 / @max(ex * ex + ey * ey, 1e-12)), z), splat(V, 1));
        const dx = wx - splat(V, ex) * t;
        const dy = wy - splat(V, ey) * t;
        best = @min(best, dx * dx + dy * dy);
        // Crossings of the ray to +x: up across it counts +1 when p is left of the edge, down -1.
        const left = splat(V, ex) * wy - splat(V, ey) * wx;
        const up = (splat(V, ay) <= py) & (splat(V, by) > py) & (left > z);
        const down = (splat(V, ay) > py) & (splat(V, by) <= py) & (left < z);
        winding += @as(I, @intFromBool(up)) - @as(I, @intFromBool(down));
        ax = bx;
        ay = by;
    }
    const d = @sqrt(best);
    return sel(V, winding != @as(I, @splat(0)), -d, d);
}

/// A point in a glyph's own frame: pixels from its anchor along its turned x and y axes.
pub inline fn glyphLocal(comptime V: type, px: V, py: V, sh: *const Shape) [2]V {
    const dx = px - splat(V, sh.p[0]);
    const dy = py - splat(V, sh.p[1]);
    const c = splat(V, sh.mid[0]);
    const s = splat(V, sh.mid[1]);
    return .{ c * dx + s * dy, c * dy - s * dx };
}

/// Antialiased coverage of a signed distance in pixels.
pub inline fn coverage(comptime V: type, d: V) V {
    return @min(@max(splat(V, 0.5) - d, splat(V, 0)), splat(V, 1));
}

/// The last instance of `ranges` (drawn last, so on top) within `slop` logical pixels of
/// `point`, in logical pixels from the node's top-left corner; null when none is. Filled rects
/// and polygons count their inside, glyphs their box; dead instances and hidden layers count
/// nothing, and only the ranges the node draws are searched.
pub fn hit(s: *const Instances, pal: *const Palette, cam: Camera, ranges: []const Range, point: [2]f32, slop: f32) ?u32 {
    const V1 = @Vector(1, f32);
    const v = View.of(cam, pal, .{ 0, 0 }, 1);
    const px: V1 = @splat(point[0]);
    const py: V1 = @splat(point[1]);
    var found: ?u32 = null;
    for (ranges) |r| {
        const end = @min(r.first +| r.count, s.len);
        for (@min(r.first, end)..end) |i| {
            const look = s.c.look[i];
            const layer = layerRow(pal, layerOf(look));
            if (!shown(look, layer)) continue;
            const sh = Shape.of(v, s.c.pos[i], look, layer);
            if (point[0] < sh.box[0] - slop or point[0] > sh.box[2] + slop or point[1] < sh.box[1] - slop or point[1] > sh.box[3] + slop) continue;
            const hw: V1 = @splat(sh.half * @intFromBool(sh.stroked));
            const d: V1 = switch (sh.kind) {
                .segment => segmentDist(V1, px, py, &sh)[0],
                .arc => arcDist(V1, px, py, &sh),
                .rect => rectDist(V1, px, py, &sh) - hw,
                .polygon => polygonDist(V1, px, py, v, s.verts[look[1]..][0..look[2]]) - hw,
                .glyph => g: {
                    const l = glyphLocal(V1, px, py, &sh);
                    break :g @splat(simd.selF(l[0][0] >= 0 and l[0][0] < sh.p[2] and l[1][0] >= 0 and l[1][0] < sh.p[3], -1, std.math.inf(f32)));
                },
            };
            if (d[0] <= slop) found = @intCast(i);
        }
    }
    return found;
}

const testing = std.testing;

fn Fixture(comptime cap: u32, comptime verts: u32) type {
    return struct {
        buf: [Instances.requiredBytes(cap, verts, 4)]u8 align(mem.column_align) = undefined,
        fn instances(f: *@This()) Instances {
            var carver: mem.Carver = .{ .buf = &f.buf };
            return Instances.init(&carver, cap, verts, 4);
        }
    };
}

test "builders: one 32-byte row per primitive, the layout the table documents" {
    var fx: Fixture(16, 8) = .{};
    var s = fx.instances();
    try testing.expectEqual(16, @sizeOf(Layer));
    try testing.expectEqual(32, @sizeOf(View));
    try testing.expectEqual(0, s.segment(.{ 0, 0 }, .{ 25_400, 0 }, .{ .layer = 3, .weight = 2, .cap = .round, .dash = 5 }));
    _ = s.rect(.{ -5_000, -2_500 }, .{ 5_000, 2_500 }, .{ .layer = 1, .radius = 300, .width = 200 });
    _ = s.arc(.{ 0, 0 }, 1_270, .{ .start = 0, .sweep = std.math.pi });
    _ = s.polygon(&.{ .{ 0, 0 }, .{ 1_000, 500 }, .{ 0, 1_000 } }, .{ .stroke = true });
    const label = s.glyphs("AB", .{ 2_000, 0 }, .{ .px = 1_000, .layer = 7, .turns = 1 });
    try testing.expectEqual(Range{ .first = 4, .count = 2 }, label);
    try testing.expectEqual(6, s.len);
    try testing.expectEqualSlices(Kind, &.{ .segment, .rect, .arc, .polygon, .glyph, .glyph }, &.{ kindOf(s.c.look[0]), kindOf(s.c.look[1]), kindOf(s.c.look[2]), kindOf(s.c.look[3]), kindOf(s.c.look[4]), kindOf(s.c.look[5]) });
    try testing.expectEqual([4]u32{ (2 << 4) | (5 << 10) | (1 << 14) | (3 << 24), 0, 0, 0 }, s.c.look[0]);
    try testing.expectEqual([4]u32{ 1 | bit.filled | bit.stroked | bit.world_width | (1 << 24), 300, 0, 200 }, s.c.look[1]);
    // Half a turn from 0: start 0, sweep 65535 / 2.
    try testing.expectEqual(@as(u32, 32768) << 16, s.c.look[2][2]);
    try testing.expectEqual([4]i32{ 0, 0, 1_000, 1_000 }, s.c.pos[3]);
    try testing.expectEqual([4]u32{ 3 | bit.filled | bit.stroked, 0, 3, 0 }, s.c.look[3]);
    // 'A' is 0x41: cell (1, 4) of the 16 x 16 atlas, 600 wide; 'B' a quarter turn on, so its
    // anchor is 600 down the screen.
    try testing.expectEqual([4]i32{ 2_000, 0, 600, 1_250 }, s.c.pos[4]);
    try testing.expectEqual([4]i32{ 2_000, 600, 600, 1_250 }, s.c.pos[5]);
    try testing.expectEqual(unorm16(1.0 / 16.0) | (unorm16(4.0 / 16.0) << 16), s.c.look[4][1]);
    try testing.expectEqual(4 | (1 << 16) | (7 << 24), s.c.look[4][0]);
}

test "reach: every kind's box holds its geometry, the world width included" {
    var fx: Fixture(8, 4) = .{};
    var s = fx.instances();
    _ = s.segment(.{ 10, 50 }, .{ -20, 30 }, .{ .width = 6 });
    _ = s.arc(.{ 100, 100 }, 40, .{});
    _ = s.glyph(.{ 0, 0 }, .{ 8, 20 }, .{ 0, 0, 1, 1 }, .{ .turns = 2 });
    _ = s.polygon(&.{ .{ 0, 0 }, .{ 9, 3 }, .{ 2, 7 } }, .{});
    const o = [2]i32{ 5, -5 };
    try testing.expectEqual([4]i32{ -31, 29, 11, 61 }, reach(s.c.pos[0], s.c.look[0], o));
    try testing.expectEqual([4]i32{ 55, 65, 135, 145 }, reach(s.c.pos[1], s.c.look[1], o));
    try testing.expectEqual([4]i32{ -25, -15, 15, 25 }, reach(s.c.pos[2], s.c.look[2], o));
    try testing.expectEqual([4]i32{ -5, 5, 4, 12 }, reach(s.c.pos[3], s.c.look[3], o));
}

test "polyline: one segment per edge, each with its distance along the chain" {
    var fx: Fixture(8, 0) = .{};
    var s = fx.instances();
    const r = s.polyline(&.{ .{ 0, 0 }, .{ 300, 400 }, .{ 300, 1_400 }, .{ 0, 1_400 } }, .{ .dash = 2 });
    try testing.expectEqual(Range{ .first = 0, .count = 3 }, r);
    try testing.expectEqualSlices(u32, &.{ 0, 500, 1_500 }, &.{ s.c.look[0][1], s.c.look[1][1], s.c.look[2][1] });
    try testing.expectEqual([4]i32{ 300, 400, 300, 1_400 }, s.c.pos[1]);
    try testing.expectEqual(Range{ .first = 3, .count = 0 }, s.polyline(&.{.{ 5, 5 }}, .{}));
}

test "dirty: builders mark what they write, coalesced; capacity falls back to everything" {
    var fx: Fixture(16, 0) = .{};
    var s = fx.instances();
    try testing.expect(s.dirty_all);
    s.clearDirty();
    for (0..5) |_| _ = s.segment(.{ 0, 0 }, .{ 1, 1 }, .{});
    try testing.expectEqualSlices(Range, &.{.{ .first = 0, .count = 5 }}, s.dirty[0..s.dirty_len]);
    s.clearDirty();
    const rev = s.revision;
    s.kill(3);
    s.kill(1);
    s.kill(4);
    try testing.expect(s.revision != rev);
    try testing.expect(s.c.look[3][0] & bit.dead != 0);
    try testing.expectEqualSlices(Range, &.{ .{ .first = 3, .count = 1 }, .{ .first = 1, .count = 1 } }, s.dirty[0..2]);
    try testing.expectEqual(Range{ .first = 1, .count = 1 }, s.dirty[1]);
    s.markDirty(.{ .first = 9, .count = 1 });
    s.markDirty(.{ .first = 12, .count = 1 });
    try testing.expectEqual(4, s.dirty_len);
    s.markDirty(.{ .first = 14, .count = 1 });
    try testing.expect(s.dirty_all);
}

test "builders: overflow overwrites the last row, a polygon that does not fit is dropped" {
    var fx: Fixture(2, 3) = .{};
    var s = fx.instances();
    _ = s.segment(.{ 0, 0 }, .{ 1, 1 }, .{});
    _ = s.polygon(&.{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }, .{});
    try testing.expect(s.overflow);
    try testing.expectEqual(0, s.vert_len);
    try testing.expectEqual(0, s.c.look[1][2]);
    _ = s.segment(.{ 0, 0 }, .{ 2, 2 }, .{});
    try testing.expectEqual(2, s.len);
    try testing.expectEqual(Kind.segment, kindOf(s.c.look[1]));
    s.reset();
    try testing.expect(!s.overflow and s.len == 0);
}

test "camera: a far origin keeps the distance from it exact; widths follow the zoom" {
    const far: i64 = 2_000_000_000;
    const pal: Palette = .{ .layers = &.{.of(.{ .width = 1.5 })}, .zoom_scale = true };
    const v = View.of(.{ .origin = .{ far, -far }, .scale = 0.01, .offset = .{ 5, 6 }, .zoom = 8 }, &pal, .{ 100, 200 }, 2);
    try testing.expectEqual(@as(f32, 210 + 2 * 0.01 * 100), v.x(@intCast(far + 100)));
    try testing.expectEqual(@as(f32, 412 - 2 * 0.01 * 300), v.y(@intCast(-far - 300)));
    // Weight 3 at width 1.5, zoom clamped to 4, 2 physical pixels per logical: 36 wide.
    var fx: Fixture(2, 0) = .{};
    var s = fx.instances();
    _ = s.segment(.{ 0, 0 }, .{ 1, 0 }, .{ .weight = 3 });
    _ = s.segment(.{ 0, 0 }, .{ 1, 0 }, .{ .weight = 3, .width = 150 });
    try testing.expectEqual(@as(f32, 18), Shape.of(v, s.c.pos[0], s.c.look[0], pal.layers[0]).half);
    try testing.expectEqual(@as(f32, 1.5), Shape.of(v, s.c.pos[1], s.c.look[1], pal.layers[0]).half);
}

test "hit: every kind, inside, outside and within the slop; the topmost wins" {
    var fx: Fixture(16, 8) = .{};
    var s = fx.instances();
    // One world unit is one pixel; the origin is drawn at (10, 10). Layer 0 is 10 px wide.
    const pal: Palette = .{ .layers = &.{ .of(.{ .width = 10 }), .of(.{ .visible = false }) } };
    const cam: Camera = .{ .origin = .{ 0, 0 }, .scale = 1, .offset = .{ 10, 10 } };
    const seg = s.segment(.{ 0, 0 }, .{ 100, 0 }, .{ .cap = .butt });
    const box = s.rect(.{ 200, 0 }, .{ 300, 50 }, .{ .radius = 25, .stroke = false });
    const ring = s.arc(.{ 0, 200 }, 50, .{ .start = 0, .sweep = std.math.pi / 2.0, .cap = .round });
    const tri = s.polygon(&.{ .{ 200, 200 }, .{ 300, 200 }, .{ 200, 300 } }, .{});
    const letter = s.glyph(.{ 400, 0 }, .{ 10, 20 }, .{ 0, 0, 1, 1 }, .{});
    const hidden = s.rect(.{ 500, 0 }, .{ 600, 100 }, .{ .layer = 1 });
    const all: []const Range = &.{s.since(0)};
    try testing.expectEqual(seg, hit(&s, &pal, cam, all, .{ 60, 14 }, 0));
    try testing.expectEqual(null, hit(&s, &pal, cam, all, .{ 60, 17 }, 0));
    try testing.expectEqual(seg, hit(&s, &pal, cam, all, .{ 60, 17 }, 2));
    try testing.expectEqual(null, hit(&s, &pal, cam, all, .{ 112, 10 }, 0));
    try testing.expectEqual(box, hit(&s, &pal, cam, all, .{ 250, 35 }, 0));
    try testing.expectEqual(null, hit(&s, &pal, cam, all, .{ 212, 12 }, 0));
    try testing.expectEqual(ring, hit(&s, &pal, cam, all, .{ 10 + 35, 210 + 35 }, 0));
    try testing.expectEqual(ring, hit(&s, &pal, cam, all, .{ 10 + 50, 210 - 3 }, 0));
    try testing.expectEqual(null, hit(&s, &pal, cam, all, .{ 10 - 35, 210 - 35 }, 0));
    try testing.expectEqual(tri, hit(&s, &pal, cam, all, .{ 230, 230 }, 0));
    try testing.expectEqual(null, hit(&s, &pal, cam, all, .{ 290, 290 }, 0));
    try testing.expectEqual(letter, hit(&s, &pal, cam, all, .{ 415, 20 }, 0));
    try testing.expectEqual(null, hit(&s, &pal, cam, all, .{ 550, 50 }, 0));
    _ = hidden;
    try testing.expectEqual(null, hit(&s, &pal, cam, &.{.{ .first = 1, .count = 4 }}, .{ 60, 10 }, 0));
    const cover = s.rect(.{ 0, -10 }, .{ 100, 10 }, .{});
    try testing.expectEqual(cover, hit(&s, &pal, cam, &.{s.since(0)}, .{ 60, 10 }, 0));
    s.kill(cover);
    try testing.expectEqual(seg, hit(&s, &pal, cam, &.{s.since(0)}, .{ 60, 10 }, 0));
    try testing.expectEqual(box, hit(&s, &pal, .{ .origin = .{ 250, 25 }, .scale = 4 }, all, .{ 0, 0 }, 0));
}

test "distances: caps, a full turn with no seam, dashes and overrides" {
    const V1 = @Vector(1, f32);
    const pal: Palette = .{ .layers = &.{.of(.{ .width = 10 })} };
    const v = View.of(.{}, &pal, .{ 0, 0 }, 1);
    inline for (.{ .{ Cap.butt, 0 }, .{ Cap.square, -5 }, .{ Cap.round, -5 } }) |c| {
        const sh = Shape.of(v, .{ 0, 0, 100, 0 }, .{ head(.segment, 0, 1, c[0], false, 0), 0, 0, 0 }, pal.layers[0]);
        try testing.expectApproxEqAbs(@as(f32, c[1]), segmentDist(V1, @splat(100), @splat(0), &sh)[0][0], 1e-4);
    }
    const sh = Shape.of(v, .{ 0, 0, 50, 0 }, .{ head(.arc, 0, 1, .butt, false, 0), 0, 0xffff << 16, 0 }, pal.layers[0]);
    for ([_]f32{ 0, 1, 2, 3, 4, 5, 6 }) |a| {
        try testing.expect(arcDist(V1, @splat(50 * @cos(a)), @splat(50 * @sin(a)), &sh)[0] < -4.9);
    }
    // Dash 2: 4 px on, 4 off, from the chain start (here 6 px before a).
    const dashed = Shape.of(v, .{ 0, 0, 100, 0 }, .{ head(.segment, 0, 1, .butt, false, 0) | (2 << 10), 6, 0, 0 }, pal.layers[0]);
    try testing.expectEqual(@as(f32, 1), dashCover(V1, segmentDist(V1, @splat(3.5), @splat(0), &dashed)[1], &dashed)[0]);
    try testing.expectEqual(@as(f32, 0), dashCover(V1, segmentDist(V1, @splat(0), @splat(0), &dashed)[1], &dashed)[0]);
    const marks = [_]Override{ .{ .range = .{ .first = 0, .count = 10 }, .color = 1 }, .{ .range = .{ .first = 4, .count = 2 }, .color = 2 } };
    try testing.expectEqual(@as(?u32, 2), overrideOf(&marks, 5));
    try testing.expectEqual(@as(?u32, 1), overrideOf(&marks, 6));
    try testing.expectEqual(@as(?u32, null), overrideOf(&marks, 10));
}
