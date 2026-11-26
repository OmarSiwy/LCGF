//! canvas: many 2D primitives in caller-owned columns, drawn under a camera. Tier 0: no
//! allocator, no OS, no GPU. A schematic, a plot or a map fills `Instances` once (or when it
//! changes); every frame `Frame.canvas` puts one node in the tree with a `Camera` and the
//! `Range`s to draw, so panning and zooming change a few numbers, not the instances.
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
//! Each instance is two rows: `pos` (4 x i32) and `look` (4 x u32), 32 bytes, two vertex
//! buffers of `sint32x4` and `uint32x4` for a GPU back end. Per kind:
//!
//!   kind     pos                 look[0] >> 4         look[1]  look[2]          look[3]
//!   segment  a.x a.y b.x b.y     cap                  colour   width            0
//!   rect     x0 y0 x1 y1         radius << 4          fill     stroke width     stroke colour
//!   arc      cx cy radius width  cap                  colour   start | sweep    0
//!   polygon  bounding box        0                    fill     first vertex     vertex count
//!   glyph    x0 y0 x1 y1         0                    colour   u0 | v0          u1 | v1
//!
//! `look[0]` is `kind | cap << 4 | radius << 8`. Angles are u16 fractions of a turn (start) and
//! of a full turn as 65535 (sweep); uv are unorm16. Strokes and widths are centred on the
//! outline. Polygon vertices are in the side column `verts`, filled by the nonzero rule.

const std = @import("std");
const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Mono = @import("../text/protocol.zig").Mono;
const Color = types.Color;

pub const Kind = enum(u4) { segment, rect, arc, polygon, glyph };
/// How a segment or an arc ends: at its end point, half its width past it, or in a half disc.
pub const Cap = enum(u4) { butt, square, round };

/// Instances `first` to `first + count`, drawn in that order.
pub const Range = extern struct { first: u32, count: u32 };

/// Where the world sits in the node. `origin` is i64 so a host may pan anywhere; instances are
/// measured from its low 32 bits, so content within 2^31 units of the origin is placed exactly.
pub const Camera = struct {
    /// The world point drawn at `offset` from the node's top-left corner.
    origin: [2]i64 = .{ 0, 0 },
    /// Logical pixels per world unit.
    scale: f32 = 1,
    /// Logical pixels from the node's top-left corner to `origin`.
    offset: [2]f32 = .{ 0, 0 },
};

/// World to pixels for one node: `base + f32(w -% origin) * scale`, in logical pixels or, times
/// the framebuffer scale, physical ones.
pub const View = struct {
    origin: [2]i32,
    scale: f32,
    base: [2]f32,

    /// `cam` inside a node whose top-left corner is at `corner`, `px` pixels per logical pixel.
    pub fn of(cam: Camera, corner: [2]f32, px: f32) View {
        return .{
            .origin = .{ @truncate(cam.origin[0]), @truncate(cam.origin[1]) },
            .scale = cam.scale * px,
            .base = .{ (corner[0] + cam.offset[0]) * px, (corner[1] + cam.offset[1]) * px },
        };
    }

    pub inline fn x(v: View, w: i32) f32 {
        return v.base[0] + @as(f32, @floatFromInt(w -% v.origin[0])) * v.scale;
    }
    pub inline fn y(v: View, w: i32) f32 {
        return v.base[1] + @as(f32, @floatFromInt(w -% v.origin[1])) * v.scale;
    }
    /// A length (width, radius) in world units, in pixels.
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
    /// Bumped by every builder and part of the canvas node's damage, so a damage-tracking frame
    /// redraws the node when its instances change. Bump it after writing the columns directly.
    revision: u32 = 0,
    c: Columns,
    /// Polygon vertices, world units.
    verts: [][2]i32,

    pub const Columns = struct {
        pos: [][4]i32,
        look: [][4]u32,
    };

    /// Carves `simd.rows(cap)` instance rows and `verts` polygon vertices from `carver`; a
    /// counting carver sizes the buffer instead (`requiredBytes`).
    pub fn init(carver: *mem.Carver, cap: u32, verts: u32) Instances {
        std.debug.assert(cap > 0);
        return .{ .cap = cap, .vert_cap = verts, .c = carver.columns(Columns, simd.rows(cap)), .verts = carver.slice([2]i32, @max(verts, 1)) };
    }

    pub fn requiredBytes(cap: u32, verts: u32) usize {
        var counter: mem.Carver = .{ .buf = null };
        _ = init(&counter, cap, verts);
        return counter.off;
    }

    pub fn reset(s: *Instances) void {
        s.len = 0;
        s.vert_len = 0;
        s.overflow = false;
        s.revision +%= 1;
    }

    /// The instances added since `len` was `first`.
    pub fn since(s: *const Instances, first: u32) Range {
        return .{ .first = first, .count = s.len - first };
    }

    /// Appends one row and returns its index.
    fn push(s: *Instances, pos: [4]i32, look: [4]u32) u32 {
        const k = @min(s.len, s.cap - 1);
        s.overflow = simd.orB(s.overflow, s.len >= s.cap);
        s.len = k + 1;
        s.revision +%= 1;
        s.c.pos[k] = pos;
        s.c.look[k] = look;
        return k;
    }

    pub const Line = struct { width: u32 = 0, cap: Cap = .butt, color: Color = .black };
    pub const Box = struct { fill: Color = .transparent, stroke: Color = .transparent, width: u32 = 0, radius: u32 = 0 };
    pub const Arc = struct { start: f32 = 0, sweep: f32 = std.math.tau, width: u32 = 0, cap: Cap = .butt, color: Color = .black };
    pub const Fill = struct { fill: Color = .black };
    pub const Text = struct { px: u32, color: Color = .black, font: Mono = .{} };

    /// A line from `a` to `b`, `width` across.
    pub fn segment(s: *Instances, a: [2]i32, b: [2]i32, o: Line) u32 {
        return s.push(.{ a[0], a[1], b[0], b[1] }, .{ head(.segment, o.cap, 0), @bitCast(o.color), o.width, 0 });
    }

    /// The box from `lo` to `hi`, filled, its outline stroked `width` across; corners rounded
    /// by `radius` (capped at half the shorter side; up to 2^24 - 1).
    pub fn rect(s: *Instances, lo: [2]i32, hi: [2]i32, o: Box) u32 {
        return s.push(.{ lo[0], lo[1], hi[0], hi[1] }, .{ head(.rect, .butt, o.radius), @bitCast(o.fill), o.width, @bitCast(o.stroke) });
    }

    /// A disc of radius `r` around `c`: a rect rounded by its half side.
    pub fn circle(s: *Instances, c: [2]i32, r: u32, o: Box) u32 {
        var b = o;
        b.radius = r;
        const ri: i32 = @intCast(r);
        return s.rect(.{ c[0] - ri, c[1] - ri }, .{ c[0] + ri, c[1] + ri }, b);
    }

    /// The circle of radius `r` around `c` from angle `start` through `sweep` (radians, from +x
    /// toward +y; a negative sweep runs the other way), `width` across.
    pub fn arc(s: *Instances, c: [2]i32, r: u32, o: Arc) u32 {
        const sweep = @min(@abs(o.sweep), std.math.tau);
        const start = o.start + @min(o.sweep, 0);
        const turn = @mod(start / std.math.tau, 1);
        const a = @as(u32, @intFromFloat(@round(turn * 65536))) & 0xffff;
        const b: u32 = @intFromFloat(@round(sweep / std.math.tau * 65535));
        return s.push(.{ c[0], c[1], @intCast(r), @intCast(o.width) }, .{ head(.arc, o.cap, 0), @bitCast(o.color), a | (b << 16), 0 });
    }

    /// The polygon through `points`, closed, filled by the nonzero rule. Its vertices go to
    /// `verts`; a polygon that does not fit is dropped and `overflow` set.
    pub fn polygon(s: *Instances, points: []const [2]i32, o: Fill) u32 {
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
        return s.push(.{ lo[0], lo[1], hi[0], hi[1] }, .{ head(.polygon, .butt, 0), @bitCast(o.fill), first, count });
    }

    /// One textured box: atlas `uv` (u0, v0, u1, v1, 0..1) over `lo` to `hi`, tinted `color`;
    /// the atlas is the glyph atlas the renderer was given (`iface.Glyphs.texture`).
    pub fn glyph(s: *Instances, lo: [2]i32, hi: [2]i32, uv: [4]f32, color: Color) u32 {
        return s.push(.{ lo[0], lo[1], hi[0], hi[1] }, .{ head(.glyph, .butt, 0), @bitCast(color), unorm16(uv[0]) | (unorm16(uv[1]) << 16), unorm16(uv[2]) | (unorm16(uv[3]) << 16) });
    }

    /// `bytes` on one line from `origin` (its top-left), `o.px` world units tall, with the
    /// metrics and 16 x 16 byte atlas of `protocol.Mono`. A shaper of your own calls `glyph`.
    pub fn glyphs(s: *Instances, bytes: []const u8, origin: [2]i32, o: Text) Range {
        const first = s.len;
        const adv = @as(f32, @floatFromInt(o.px)) * o.font.advance;
        const h: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(o.px)) * o.font.line));
        for (bytes, 0..) |byte, j| {
            const x0 = origin[0] + @as(i32, @intFromFloat(@round(adv * @as(f32, @floatFromInt(j)))));
            const x1 = origin[0] + @as(i32, @intFromFloat(@round(adv * @as(f32, @floatFromInt(j + 1)))));
            const cx: f32 = @floatFromInt(byte & 15);
            const cy: f32 = @floatFromInt(byte >> 4);
            _ = s.glyph(.{ x0, origin[1] }, .{ x1, origin[1] + h }, .{ cx / 16, cy / 16, (cx + 1) / 16, (cy + 1) / 16 }, o.color);
        }
        return s.since(first);
    }
};

fn head(k: Kind, cap: Cap, radius: u32) u32 {
    return @as(u32, @backingInt(k)) | (@as(u32, @backingInt(cap)) << 4) | (@as(u32, @min(radius, 0xff_ffff)) << 8);
}

fn unorm16(v: f32) u32 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 65535));
}

pub inline fn kindOf(look: [4]u32) Kind {
    return @fromBackingInt(@intCast(@as(u4, @truncate(look[0]))));
}

/// One instance in pixels: what the shaders read, decoded once per instance.
pub const Shape = struct {
    kind: Kind,
    /// Segment: a, b. Rect, glyph: x0, y0, x1, y1. Arc: centre, then 0, 0. Polygon: its box.
    p: [4]f32,
    /// Segment, arc: half the width. Rect: half the stroke width.
    half: f32,
    /// Rect: corner radius. Arc: radius.
    radius: f32,
    /// Square caps: 1. Round caps: 1 in `round`.
    square: f32,
    round: bool,
    /// Arc: the direction of its middle (cos, sin) and its half aperture (sin, cos).
    mid: [2]f32,
    aperture: [2]f32,
    /// Arc: added to how far past its ends a point is; -inf for a full turn, which has none
    /// (its two butt ends would otherwise meet in a half-covered seam).
    seam: f32 = 0,
    /// Pixel box the shape can touch, x0, y0, x1, y1 (one pixel of antialiasing included).
    box: [4]f32,

    pub fn of(v: View, pos: [4]i32, look: [4]u32) Shape {
        const kind = kindOf(look);
        const cap: Cap = @fromBackingInt(@intCast(@as(u4, @truncate(look[0] >> 4))));
        const corner = [4]f32{ v.x(pos[0]), v.y(pos[1]), v.x(pos[2]), v.y(pos[3]) };
        var sh: Shape = .{
            .kind = kind,
            .p = corner,
            .half = v.len(look[2]) * 0.5,
            .radius = v.len(look[0] >> 8),
            .square = simd.b2f(cap == .square),
            .round = cap == .round,
            .mid = .{ 1, 0 },
            .aperture = .{ 0, 1 },
            .box = undefined,
        };
        var grow: f32 = 0;
        switch (kind) {
            .segment => grow = sh.half * std.math.sqrt2,
            .rect => grow = sh.half,
            .arc => {
                const r = v.len(@bitCast(pos[2]));
                const turn: f32 = @floatFromInt(look[2] & 0xffff);
                const sweep = @as(f32, @floatFromInt(look[2] >> 16)) / 65535 * std.math.tau;
                const m = turn / 65536 * std.math.tau + sweep / 2;
                sh.half = v.len(@bitCast(pos[3])) * 0.5;
                sh.radius = r;
                sh.mid = .{ @cos(m), @sin(m) };
                // sin of a half aperture in [0, pi] is never negative; rounding at pi must not
                // make the far side of a full ring "past its end".
                sh.aperture = .{ @max(@sin(sweep / 2), 0), @cos(sweep / 2) };
                sh.seam = simd.selF(look[2] >> 16 == 0xffff, -std.math.inf(f32), 0);
                sh.p = .{ corner[0], corner[1], 0, 0 };
                const e = r + sh.half;
                sh.box = .{ corner[0] - e - 1, corner[1] - e - 1, corner[0] + e + 1, corner[1] + e + 1 };
                return sh;
            },
            .polygon, .glyph => {},
        }
        sh.box = .{
            @min(corner[0], corner[2]) - grow - 1, @min(corner[1], corner[3]) - grow - 1,
            @max(corner[0], corner[2]) + grow + 1, @max(corner[1], corner[3]) + grow + 1,
        };
        return sh;
    }
};

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

/// The segment `sh` (a to b, `half` either side, its caps).
pub inline fn segmentDist(comptime V: type, px: V, py: V, sh: *const Shape) V {
    const dx = sh.p[2] - sh.p[0];
    const dy = sh.p[3] - sh.p[1];
    const l = @sqrt(dx * dx + dy * dy);
    const k = 1 / @max(l, 1e-6);
    const ux = simd.selF(l > 1e-6, dx * k, 1);
    const uy = dy * k;
    const ox = px - splat(V, (sh.p[0] + sh.p[2]) * 0.5);
    const oy = py - splat(V, (sh.p[1] + sh.p[3]) * 0.5);
    const along = @abs(ox * splat(V, ux) + oy * splat(V, uy));
    const across = @abs(oy * splat(V, ux) - ox * splat(V, uy));
    const h = splat(V, l * 0.5);
    const hw = splat(V, sh.half);
    const capsule = length(@max(along - h, splat(V, 0)), across) - hw;
    const box = boxDist(V, along - h - hw * splat(V, sh.square), across - hw);
    return if (sh.round) capsule else box;
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

/// Antialiased coverage of a signed distance in pixels.
pub inline fn coverage(comptime V: type, d: V) V {
    return @min(@max(splat(V, 0.5) - d, splat(V, 0)), splat(V, 1));
}

/// The last instance of `ranges` (drawn last, so on top) within `slop` logical pixels of
/// `point`, in logical pixels from the node's top-left corner; null when none is. Rects and
/// polygons count their inside, glyphs their box. Ranges are the ones the node draws, so a
/// hidden layer cannot be selected.
pub fn hit(s: *const Instances, cam: Camera, ranges: []const Range, point: [2]f32, slop: f32) ?u32 {
    const V1 = @Vector(1, f32);
    const v = View.of(cam, .{ 0, 0 }, 1);
    const px: V1 = @splat(point[0]);
    const py: V1 = @splat(point[1]);
    var found: ?u32 = null;
    for (ranges) |r| {
        const end = @min(r.first +| r.count, s.len);
        for (@min(r.first, end)..end) |i| {
            const sh = Shape.of(v, s.c.pos[i], s.c.look[i]);
            if (point[0] < sh.box[0] - slop or point[0] > sh.box[2] + slop or point[1] < sh.box[1] - slop or point[1] > sh.box[3] + slop) continue;
            const look = s.c.look[i];
            const d: V1 = switch (sh.kind) {
                .segment => segmentDist(V1, px, py, &sh),
                .rect => rectDist(V1, px, py, &sh) - @as(V1, @splat(sh.half)),
                .arc => arcDist(V1, px, py, &sh),
                .polygon => polygonDist(V1, px, py, v, s.verts[look[2]..][0..look[3]]),
                .glyph => @splat(simd.selF(point[0] >= sh.p[0] and point[0] < sh.p[2] and point[1] >= sh.p[1] and point[1] < sh.p[3], -1, std.math.inf(f32))),
            };
            if (d[0] <= slop) found = @intCast(i);
        }
    }
    return found;
}

const testing = std.testing;

fn Fixture(comptime cap: u32, comptime verts: u32) type {
    return struct {
        buf: [Instances.requiredBytes(cap, verts)]u8 align(mem.column_align) = undefined,
        fn instances(f: *@This()) Instances {
            var carver: mem.Carver = .{ .buf = &f.buf };
            return Instances.init(&carver, cap, verts);
        }
    };
}

test "builders: one 32-byte row per primitive, the layout the table documents" {
    var fx: Fixture(16, 8) = .{};
    var s = fx.instances();
    try testing.expectEqual(32, @sizeOf([4]i32) + @sizeOf([4]u32));
    try testing.expectEqual(0, s.segment(.{ 0, 0 }, .{ 25_400, 0 }, .{ .width = 150, .cap = .round, .color = .white }));
    _ = s.rect(.{ -5_000, -2_500 }, .{ 5_000, 2_500 }, .{ .fill = .black, .stroke = .white, .width = 200, .radius = 300 });
    _ = s.arc(.{ 0, 0 }, 1_270, .{ .start = 0, .sweep = std.math.pi, .width = 150 });
    _ = s.polygon(&.{ .{ 0, 0 }, .{ 1_000, 500 }, .{ 0, 1_000 } }, .{});
    const label = s.glyphs("AB", .{ 2_000, 0 }, .{ .px = 1_000 });
    try testing.expectEqual(Range{ .first = 4, .count = 2 }, label);
    try testing.expectEqual(6, s.len);
    try testing.expectEqualSlices(Kind, &.{ .segment, .rect, .arc, .polygon, .glyph, .glyph }, &.{ kindOf(s.c.look[0]), kindOf(s.c.look[1]), kindOf(s.c.look[2]), kindOf(s.c.look[3]), kindOf(s.c.look[4]), kindOf(s.c.look[5]) });
    try testing.expectEqual([4]u32{ 2 << 4, @bitCast(Color.white), 150, 0 }, s.c.look[0]);
    try testing.expectEqual([4]u32{ 1 | (300 << 8), @bitCast(Color.black), 200, @bitCast(Color.white) }, s.c.look[1]);
    // Half a turn from 0: start 0, sweep 65535 / 2.
    try testing.expectEqual(@as(u32, 32768) << 16, s.c.look[2][2]);
    try testing.expectEqual([4]i32{ 0, 0, 1_000, 1_000 }, s.c.pos[3]);
    try testing.expectEqual(3, s.c.look[3][3]);
    // 'A' is 0x41: cell (1, 4) of the 16 x 16 atlas, 600 wide.
    try testing.expectEqual([4]i32{ 2_000, 0, 2_600, 1_250 }, s.c.pos[4]);
    try testing.expectEqual(unorm16(1.0 / 16.0) | (unorm16(4.0 / 16.0) << 16), s.c.look[4][2]);
}

test "builders: overflow overwrites the last row, a polygon that does not fit is dropped" {
    var fx: Fixture(2, 3) = .{};
    var s = fx.instances();
    _ = s.segment(.{ 0, 0 }, .{ 1, 1 }, .{});
    _ = s.polygon(&.{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } }, .{});
    try testing.expect(s.overflow);
    try testing.expectEqual(0, s.vert_len);
    try testing.expectEqual(0, s.c.look[1][3]);
    _ = s.segment(.{ 0, 0 }, .{ 2, 2 }, .{});
    try testing.expectEqual(2, s.len);
    try testing.expectEqual(Kind.segment, kindOf(s.c.look[1]));
    s.reset();
    try testing.expect(!s.overflow and s.len == 0);
}

test "camera: a far origin keeps the distance from it exact" {
    const far: i64 = 2_000_000_000;
    const v = View.of(.{ .origin = .{ far, -far }, .scale = 0.01, .offset = .{ 5, 6 } }, .{ 100, 200 }, 2);
    try testing.expectEqual(@as(f32, 210 + 2 * 0.01 * 100), v.x(@intCast(far + 100)));
    try testing.expectEqual(@as(f32, 412 - 2 * 0.01 * 300), v.y(@intCast(-far - 300)));
    try testing.expectEqual(@as(f32, 2 * 0.01 * 150), v.len(150));
}

test "hit: every kind, inside, outside and within the slop; the topmost wins" {
    var fx: Fixture(16, 8) = .{};
    var s = fx.instances();
    // One world unit is one pixel; the origin is drawn at (10, 10).
    const cam: Camera = .{ .origin = .{ 0, 0 }, .scale = 1, .offset = .{ 10, 10 } };
    const seg = s.segment(.{ 0, 0 }, .{ 100, 0 }, .{ .width = 10, .cap = .butt });
    const box = s.rect(.{ 200, 0 }, .{ 300, 50 }, .{ .fill = .white, .radius = 25 });
    const ring = s.arc(.{ 0, 200 }, 50, .{ .start = 0, .sweep = std.math.pi / 2.0, .width = 10, .cap = .round });
    const tri = s.polygon(&.{ .{ 200, 200 }, .{ 300, 200 }, .{ 200, 300 } }, .{});
    const letter = s.glyph(.{ 400, 0 }, .{ 410, 20 }, .{ 0, 0, 1, 1 }, .white);
    const all: []const Range = &.{s.since(0)};
    try testing.expectEqual(seg, hit(&s, cam, all, .{ 60, 14 }, 0));
    try testing.expectEqual(null, hit(&s, cam, all, .{ 60, 17 }, 0));
    try testing.expectEqual(seg, hit(&s, cam, all, .{ 60, 17 }, 2));
    // Butt caps end at the end point; the rect's rounded corner leaves its corner out.
    try testing.expectEqual(null, hit(&s, cam, all, .{ 112, 10 }, 0));
    try testing.expectEqual(box, hit(&s, cam, all, .{ 250, 35 }, 0));
    try testing.expectEqual(null, hit(&s, cam, all, .{ 212, 12 }, 0));
    // The quarter arc from +x to +y: (50, 0) and (0, 50) from its centre, round caps past them.
    try testing.expectEqual(ring, hit(&s, cam, all, .{ 10 + 35, 210 + 35 }, 0));
    try testing.expectEqual(ring, hit(&s, cam, all, .{ 10 + 50, 210 - 3 }, 0));
    try testing.expectEqual(null, hit(&s, cam, all, .{ 10 - 35, 210 - 35 }, 0));
    try testing.expectEqual(null, hit(&s, cam, all, .{ 10, 210 }, 0));
    try testing.expectEqual(tri, hit(&s, cam, all, .{ 230, 230 }, 0));
    try testing.expectEqual(null, hit(&s, cam, all, .{ 290, 290 }, 0));
    try testing.expectEqual(letter, hit(&s, cam, all, .{ 415, 20 }, 0));
    // Only the given ranges count; of two overlapping instances the later one is on top.
    try testing.expectEqual(null, hit(&s, cam, &.{.{ .first = 1, .count = 4 }}, .{ 60, 10 }, 0));
    const cover = s.rect(.{ 0, -10 }, .{ 100, 10 }, .{ .fill = .white });
    try testing.expectEqual(cover, hit(&s, cam, &.{s.since(0)}, .{ 60, 10 }, 0));
    // Zoom and pan: the same world point under another camera.
    try testing.expectEqual(box, hit(&s, .{ .origin = .{ 250, 25 }, .scale = 4, .offset = .{ 0, 0 } }, all, .{ 0, 0 }, 0));
}

test "distances: square caps reach half the width past the end, butt caps stop at it" {
    const V1 = @Vector(1, f32);
    const v = View.of(.{}, .{ 0, 0 }, 1);
    inline for (.{ .{ Cap.butt, 0 }, .{ Cap.square, -5 }, .{ Cap.round, -5 } }) |c| {
        const sh = Shape.of(v, .{ 0, 0, 100, 0 }, .{ head(.segment, c[0], 0), 0, 10, 0 });
        try testing.expectApproxEqAbs(@as(f32, c[1]), segmentDist(V1, @splat(100), @splat(0), &sh)[0], 1e-4);
    }
    // A full turn has no ends: every angle is on the ring.
    const sh = Shape.of(v, .{ 0, 0, 50, 10 }, .{ head(.arc, .butt, 0), 0, 0xffff << 16, 0 });
    for ([_]f32{ 0, 1, 2, 3, 4, 5, 6 }) |a| {
        try testing.expect(arcDist(V1, @splat(50 * @cos(a)), @splat(50 * @sin(a)), &sh)[0] < -4.9);
    }
}
