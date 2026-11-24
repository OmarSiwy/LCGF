//! Shared paint and input geometry. Tier 0, with no retained state or allocation.
//! Rectangles are x0,y0,x1,y1; matrices map (x,y) to (a*x+c*y+tx,b*x+d*y+ty).
//! Singular or non-finite transforms paint and hit nothing. Bounds are conservative:
//! exact rounded/path clipping remains the coverage rasterizer's responsibility.

const std = @import("std");
const types = @import("../core/types.zig");
const features = @import("features.zig");
const V4 = @Vector(4, f32);

pub const identity: [6]f32 = .{ 1, 0, 0, 1, 0, 0 };
pub const empty: [4]f32 = .{ 0, 0, 0, 0 };
pub const unbounded: [4]f32 = .{ -types.inf, -types.inf, types.inf, types.inf };

/// Parent after local: p(l(point)).
pub fn compose(p: [6]f32, l: [6]f32) [6]f32 {
    return .{
        p[0] * l[0] + p[2] * l[1],        p[1] * l[0] + p[3] * l[1],
        p[0] * l[2] + p[2] * l[3],        p[1] * l[2] + p[3] * l[3],
        p[0] * l[4] + p[2] * l[5] + p[4], p[1] * l[4] + p[3] * l[5] + p[5],
    };
}

pub fn point(m: [6]f32, p: [2]f32) [2]f32 {
    return .{ m[0] * p[0] + m[2] * p[1] + m[4], m[1] * p[0] + m[3] * p[1] + m[5] };
}

/// Normalized origin in a reference rectangle; values outside 0..1 are intentional.
pub fn about(m: [6]f32, rect: [4]f32, origin: [2]f32) [6]f32 {
    const x = rect[0] + (rect[2] - rect[0]) * origin[0];
    const y = rect[1] + (rect[3] - rect[1]) * origin[1];
    return .{ m[0], m[1], m[2], m[3], m[4] + x - m[0] * x - m[2] * y, m[5] + y - m[1] * x - m[3] * y };
}

pub fn inverse(m: [6]f32) ?[6]f32 {
    for (m) |v| if (!std.math.isFinite(v)) return null;
    const det = m[0] * m[3] - m[1] * m[2];
    if (det == 0 or !std.math.isFinite(det)) return null;
    const k = 1 / det;
    const inv: [6]f32 = .{ m[3] * k, -m[1] * k, -m[2] * k, m[0] * k, (m[2] * m[5] - m[3] * m[4]) * k, (m[1] * m[4] - m[0] * m[5]) * k };
    for (inv) |v| if (!std.math.isFinite(v)) return null;
    return inv;
}

pub fn hasArea(rect: [4]f32) bool {
    return (rect[0] < rect[2]) & (rect[1] < rect[3]);
}

pub fn intersect(a: [4]f32, b: [4]f32) [4]f32 {
    return .{ @max(a[0], b[0]), @max(a[1], b[1]), @min(a[2], b[2]), @min(a[3], b[3]) };
}

pub fn expand(rect: [4]f32, amount: [4]f32) [4]f32 {
    return .{ rect[0] - amount[0], rect[1] - amount[1], rect[2] + amount[2], rect[3] + amount[3] };
}

pub fn transformRect(rect: [4]f32, m: [6]f32) [4]f32 {
    if (std.mem.eql(f32, &m, &identity)) return rect;
    if (!hasArea(rect) or inverse(m) == null) return empty;
    const xx: V4 = .{ rect[0], rect[2], rect[2], rect[0] };
    const yy: V4 = .{ rect[1], rect[1], rect[3], rect[3] };
    const x = xx * @as(V4, @splat(m[0])) + yy * @as(V4, @splat(m[2])) + @as(V4, @splat(m[4]));
    const y = xx * @as(V4, @splat(m[1])) + yy * @as(V4, @splat(m[3])) + @as(V4, @splat(m[5]));
    return .{ @reduce(.Min, x), @reduce(.Min, y), @reduce(.Max, x), @reduce(.Max, y) };
}

/// The stock shadow shader expands its local source by three standard deviations.
pub fn localPaintBounds(rect: [4]f32, params: [4]f32) [4]f32 {
    const words: [4]u32 = @bitCast(params);
    const sigma: f32 = @bitCast(words[1]);
    const growth = if (words[0] == @backingInt(features.Kind.shadow) and std.math.isFinite(sigma)) @max(0, sigma) * 3 else 0;
    return expand(rect, @splat(growth));
}

/// Shared by damage, visibility and overlap-sensitive batching. `clip` is in screen space.
pub fn paintBounds(rect: [4]f32, params: [4]f32, xform: [6]f32, clip: [4]f32) [4]f32 {
    return intersect(transformRect(localPaintBounds(rect, params), xform), clip);
}

pub fn quadBounds(q: anytype) [4]f32 {
    return paintBounds(q.rect, q.params, q.xform, q.clip);
}

/// An explicit paint reference reads an earlier border box, never another reference. This
/// makes paint dependencies acyclic and keeps the layout tree independent of decorations.
pub fn paintSource(t: anytype, i: usize) usize {
    const reference = t.x.row[t.c.extra[i]].paint_reference;
    std.debug.assert(reference == types.none or reference < i);
    return if (reference == types.none) i else reference;
}

pub fn nodeRect(t: anytype, i: usize) [4]f32 {
    const source = paintSource(t, i);
    const c = &t.c;
    return expand(.{ c.rect[0][source], c.rect[1][source], c.rect[2][source], c.rect[3][source] }, t.x.row[c.extra[i]].paint_outset);
}

/// Reconstruct world geometry from immutable extras and current rectangle columns. This
/// is the compile-time frontend's no-storage route; ordinary runtime trees use their sweep.
pub fn worldFromColumns(t: anytype, node: usize) [6]f32 {
    var result = identity;
    var i = node;
    while (true) {
        const x = t.x.row[t.c.extra[i]];
        const rect: [4]f32 = .{ t.c.rect[0][i], t.c.rect[1][i], t.c.rect[2][i], t.c.rect[3][i] };
        result = compose(about(x.transform, rect, x.transform_origin), result);
        if (i == 0) break;
        i = t.c.parent[i];
    }
    return result;
}

pub fn worldAt(t: anytype, i: usize) [6]f32 {
    const Tree = @import("../core/tree.zig").Tree;
    if (comptime @TypeOf(t) == *const Tree or @TypeOf(t) == *Tree) return t.x.row[t.c.scope[i]].world;
    return worldFromColumns(t, i);
}

pub fn nodeWorld(t: anytype, i: usize) [6]f32 {
    return worldAt(t, paintSource(t, i));
}

pub fn nodeClip(t: anytype, i: usize) [4]f32 {
    const sign: V4 = .{ 1, 1, -1, -1 };
    return @as(V4, t.c.child_clip[t.c.parent[paintSource(t, i)]]) * sign;
}

pub fn nodeClipRadii(t: anytype, i: usize) [4]f32 {
    return t.x.row[t.c.scope[t.c.parent[paintSource(t, i)]]].clip_radii;
}

pub fn nodeAlpha(t: anytype, i: usize) f32 {
    const source = paintSource(t, i);
    const inherited = t.x.row[t.c.scope[source]].alpha;
    return if (source == i) inherited else inherited * t.x.row[t.c.extra[i]].opacity;
}

/// World-space node bounds after layout and inherit.transform. Includes an optional paint
/// reference/outset, then stock shader expansion, transform and ancestor screen clip.
pub fn nodeBounds(t: anytype, i: usize) [4]f32 {
    return paintBounds(nodeRect(t, i), t.c.look[i].params, nodeWorld(t, i), nodeClip(t, i));
}

pub fn contains(rect: [4]f32, p: [2]f32) bool {
    return (p[0] >= rect[0]) & (p[0] < rect[2]) & (p[1] >= rect[1]) & (p[1] < rect[3]);
}

/// Normalizes overlapping circular corner radii with one common factor.
pub fn normalizeRadii(rect: [4]f32, radii: [4]f32) [4]f32 {
    const r = @max(@as(V4, radii), @as(V4, @splat(0)));
    const w = @max(0, rect[2] - rect[0]);
    const h = @max(0, rect[3] - rect[1]);
    const sums: V4 = .{ r[0] + r[1], r[3] + r[2], r[0] + r[3], r[1] + r[2] };
    const lengths: V4 = .{ w, w, h, h };
    const scale = @min(1, @reduce(.Min, lengths / @max(sums, @as(V4, @splat(std.math.floatMin(f32))))));
    return r * @as(V4, @splat(scale));
}

pub fn roundedContains(rect: [4]f32, radii: [4]f32, p: [2]f32) bool {
    if (!contains(rect, p)) return false;
    const r = normalizeRadii(rect, radii);
    const right = p[0] >= (rect[0] + rect[2]) * 0.5;
    const bottom = p[1] >= (rect[1] + rect[3]) * 0.5;
    const corner: usize = if (bottom) (if (right) @as(usize, 2) else 3) else (if (right) @as(usize, 1) else 0);
    const radius = r[corner];
    const cx = if (right) rect[2] - radius else rect[0] + radius;
    const cy = if (bottom) rect[3] - radius else rect[1] + radius;
    const dx = @max(0, if (right) p[0] - cx else cx - p[0]);
    const dy = @max(0, if (bottom) p[1] - cy else cy - p[1]);
    return dx * dx + dy * dy <= radius * radius;
}

/// Exact transformed box and every ancestor's rounded clip. Its traversal is dependent:
/// do this for candidate hits, after the SIMD screen-box broad phase.
pub fn hitNode(t: anytype, node: u32, screen: [2]f32) bool {
    const c = &t.c;
    const own_inv = inverse(worldAt(t, node)) orelse return false;
    const local = point(own_inv, screen);
    if (!contains(.{ c.rect[0][node], c.rect[1][node], c.rect[2][node], c.rect[3][node] }, local)) return false;
    var i = node;
    while (i != 0) {
        i = c.parent[i];
        if (c.clips[i] == 0) continue;
        const inv = inverse(worldAt(t, i)) orelse return false;
        const extra = t.x.row[c.extra[i]];
        const box = expand(.{ c.rect[0][i], c.rect[1][i], c.rect[2][i], c.rect[3][i] }, @splat(-extra.border));
        const radii: [4]f32 = @max(@as(V4, extra.radii) - @as(V4, @splat(extra.border)), @as(V4, @splat(0)));
        if (!roundedContains(box, radii, point(inv, screen))) return false;
    }
    return true;
}

/// One coarse decision keeps rectangular trees on their existing SIMD hit path.
pub fn needsExactHit(t: anytype) bool {
    for (1..t.xlen) |r| {
        const extra = t.x.row[r];
        if (!std.mem.eql(f32, &extra.transform, &identity)) return true;
        if (t.c.clips[t.x.node[r]] != 0 and @reduce(.Or, @as(V4, extra.radii) > @as(V4, @splat(0)))) return true;
    }
    return false;
}

/// Maps a logical edge to a physical pixel boundary without changing layout measurements.
pub fn snap(value: f32, device_scale: f32) f32 {
    std.debug.assert(device_scale > 0 and std.math.isFinite(device_scale));
    return @round(value * device_scale) / device_scale;
}

test "paint bounds follow translated shadows and reject singular transforms" {
    const rect: [4]f32 = .{ 10, 20, 30, 40 };
    const m: [6]f32 = .{ 1, 0, 0, 1, 100, 0 };
    try std.testing.expectEqual([4]f32{ 104, 14, 136, 46 }, paintBounds(rect, features.shadow(2), m, unbounded));
    try std.testing.expectEqual(empty, transformRect(rect, .{ 0, 0, 0, 0, 7, 9 }));
    const rotation: [6]f32 = .{ 0, 1, -1, 0, 0, 0 };
    try std.testing.expectEqual([4]f32{ -40, 10, -20, 30 }, transformRect(rect, rotation));
    try std.testing.expectEqual([2]f32{ 12, 24 }, point(inverse(m).?, point(m, .{ 12, 24 })));
}

test "radii normalize together and snapped physical edges preserve scale" {
    try std.testing.expectEqual([4]f32{ 5, 5, 5, 5 }, normalizeRadii(.{ 0, 0, 10, 20 }, @splat(20)));
    try std.testing.expect(!roundedContains(.{ 0, 0, 20, 20 }, @splat(10), .{ 0, 0 }));
    try std.testing.expect(roundedContains(.{ 0, 0, 20, 20 }, @splat(10), .{ 10, 0 }));
    try std.testing.expectEqual(@as(f32, 1.5), snap(1.3, 2));
}
