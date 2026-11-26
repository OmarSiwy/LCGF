//! hit: which node is under a point. One SIMD sweep over the visible rects, no early exit.
//! Tier 0: no allocator, no I/O. Ported from prototype/ui.zig ("hit").

const std = @import("std");
const geometry = @import("../draw/geometry.zig");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Sense = types.Sense;
const none = types.none;

const W = simd.lanes;

/// Topmost node under (x, y) that takes part in any interaction in `want`, or `none`. Tests
/// `lanes` nodes per step and never exits early; later rows are drawn later, so the highest
/// matching row wins. Reads `vis` and `sense` as `layout.finalize` left them (padding rows have
/// sense 0, so they never match).
pub fn at(t: *const Tree, x: f32, y: f32, want: Sense) u32 {
    if (geometry.needsExactHit(t)) return atExact(t, &.{}, x, y, want);
    const c = &t.c;
    const px = simd.f(x);
    const py = simd.f(y);
    const wantv: simd.Bytes = @splat(@as(u8, @bitCast(want)));
    const zero: simd.Bytes = @splat(0);
    var found: u32 = none;
    const n = simd.padded(t.len);
    var i: usize = 0;
    while (i < n) : (i += W) {
        const inside = (px >= simd.loadF(c.vis[0], i)) & (px < simd.loadF(c.vis[2], i)) &
            (py >= simd.loadF(c.vis[1], i)) & (py < simd.loadF(c.vis[3], i));
        const senses: simd.Bytes = c.sense[i..][0..W].*;
        const m = simd.bits(inside & ((senses & wantv) != zero));
        // Highest set lane. Wraps when m == 0, and is then discarded.
        const top = @as(u32, W - 1) -% @as(u32, @clz(m));
        found = simd.selU(m != 0, @as(u32, @intCast(i)) +% top, found);
    }
    return found;
}

/// Like `at`, but honouring paint layers: the node under (x, y) with the highest (layer, row),
/// which is the last match in `overlay.order`'s paint order. `layer` is `overlay.Layers.c.layer`
/// as `overlay.order` wrote it, padded like every column; with every layer 0 the result is
/// `at`'s. A menu row that is earlier than the body it covers is hit, not the body under it.
pub fn atLayered(t: *const Tree, layer: []const u8, x: f32, y: f32, want: Sense) u32 {
    if (geometry.needsExactHit(t)) return atExact(t, layer, x, y, want);
    const c = &t.c;
    const px = simd.f(x);
    const py = simd.f(y);
    const wantv: simd.Bytes = @splat(@as(u8, @bitCast(want)));
    const zero8: simd.Bytes = @splat(0);
    var best_l = simd.u(0);
    var best_i = simd.u(none);
    const n = simd.padded(t.len);
    var i: usize = 0;
    while (i < n) : (i += W) {
        const inside = (px >= simd.loadF(c.vis[0], i)) & (px < simd.loadF(c.vis[2], i)) &
            (py >= simd.loadF(c.vis[1], i)) & (py < simd.loadF(c.vis[3], i));
        const senses: simd.Bytes = c.sense[i..][0..W].*;
        const lb: simd.Bytes = layer[i..][0..W].*;
        const l: simd.U = lb;
        // Rows rise within a lane, so an equal layer means a later row: it wins.
        const take = inside & ((senses & wantv) != zero8) & (l >= best_l);
        best_l = @select(u32, take, l, best_l);
        best_i = @select(u32, take, simd.iota + simd.u(@intCast(i)), best_i);
    }
    // Across lanes: the highest layer, then the highest row, by the shifted max of `near`.
    // Lanes that never matched hold layer 0 and `none`, which shifts to 0 and loses.
    const l_max = @reduce(.Max, best_l);
    const shifted = @select(u32, best_l == simd.u(l_max), best_i +% simd.u(1), simd.u(0));
    return @reduce(.Max, shifted) -% 1;
}

/// Like `at`, for a finger: the node nearest to (x, y) within `slop` logical pixels that takes
/// part in `want`, or `none`. A node under the point is at distance 0, so it always beats one
/// that is only near; among equal distances the topmost (latest) row wins, as in `at`. With
/// `slop` 0 the result is `at`'s. Only visible nodes count, and distance is to the clipped rect.
pub fn near(t: *const Tree, x: f32, y: f32, want: Sense, slop: f32) u32 {
    if (geometry.needsExactHit(t)) return nearExact(t, x, y, want, slop);
    const c = &t.c;
    const px = simd.f(x);
    const py = simd.f(y);
    const zero = simd.f(0);
    // Outside points are at least this far, so slop 0 keeps `at`'s half-open edges.
    const tiny = simd.f(std.math.floatTrueMin(f32));
    const limit = simd.f(slop * slop);
    const wantv: simd.Bytes = @splat(@as(u8, @bitCast(want)));
    const zero8: simd.Bytes = @splat(0);
    var best_d = simd.f(types.inf);
    var best_i = simd.u(none);
    const n = simd.padded(t.len);
    var i: usize = 0;
    while (i < n) : (i += W) {
        const x0 = simd.loadF(c.vis[0], i);
        const y0 = simd.loadF(c.vis[1], i);
        const x1 = simd.loadF(c.vis[2], i);
        const y1 = simd.loadF(c.vis[3], i);
        const inside = (px >= x0) & (px < x1) & (py >= y0) & (py < y1);
        const dx = @max(@max(x0 - px, px - x1), zero);
        const dy = @max(@max(y0 - py, py - y1), zero);
        const d = @select(f32, inside, zero, @max(dx * dx + dy * dy, tiny));
        const senses: simd.Bytes = c.sense[i..][0..W].*;
        const shown: simd.Bytes = c.visible[i..][0..W].*;
        const take = ((senses & wantv) != zero8) & (shown != zero8) & (d <= limit) & (d <= best_d);
        best_d = @select(f32, take, d, best_d);
        best_i = @select(u32, take, simd.iota + simd.u(@intCast(i)), best_i);
    }
    // Per lane, `best_i` is the latest row at that lane's least distance; across lanes, the
    // least distance wins and then the highest row. Lanes that never matched hold `none`.
    // Rows are shifted by one so a lane holding `none` contributes 0 (`none +% 1 == 0`); with
    // no match the max is 0 and `-% 1` gives `none`. No final select, which Zig 0.18's LLVM
    // turned into a branch.
    const d_min = @reduce(.Min, best_d);
    const at_min = best_d == simd.f(d_min);
    const shifted = @select(u32, at_min, best_i +% simd.u(1), simd.u(0));
    return @reduce(.Max, shifted) -% 1;
}

/// Exact refinement is opt-in by geometry, after the screen-space broad phase. Ancestor
/// traversal is dependent; the common rectangular tree retains the SIMD implementation.
fn atExact(t: *const Tree, layer: []const u8, x: f32, y: f32, want: Sense) u32 {
    var found: u32 = none;
    var top: u8 = 0;
    for (0..t.len) |i| {
        const c = &t.c;
        const level = if (layer.len != 0) layer[i] else 0;
        if ((c.sense[i] & @as(u8, @bitCast(want))) == 0 or c.visible[i] == 0 or level < top) continue;
        const box: [4]f32 = .{ c.vis[0][i], c.vis[1][i], c.vis[2][i], c.vis[3][i] };
        if (geometry.contains(box, .{ x, y }) and geometry.hitNode(t, @intCast(i), .{ x, y })) {
            found = @intCast(i);
            top = level;
        }
    }
    return found;
}

fn nearExact(t: *const Tree, x: f32, y: f32, want: Sense, slop: f32) u32 {
    const under = atExact(t, &.{}, x, y, want);
    if (under != none or slop <= 0) return under;
    var found: u32 = none;
    var best = slop * slop;
    const c = &t.c;
    for (0..t.len) |i| {
        if ((c.sense[i] & @as(u8, @bitCast(want))) == 0 or c.visible[i] == 0) continue;
        // Project to each transformed box edge in screen space. A clipped projection is
        // rejected; clipping must never enlarge a target through a rounded corner.
        const m = t.x.row[c.scope[i]].world;
        const corners = [_][2]f32{
            geometry.point(m, .{ c.rect[0][i], c.rect[1][i] }),
            geometry.point(m, .{ c.rect[2][i], c.rect[1][i] }),
            geometry.point(m, .{ c.rect[2][i], c.rect[3][i] }),
            geometry.point(m, .{ c.rect[0][i], c.rect[3][i] }),
        };
        const centre = geometry.point(m, .{ (c.rect[0][i] + c.rect[2][i]) * 0.5, (c.rect[1][i] + c.rect[3][i]) * 0.5 });
        for (corners, 0..) |a, k| {
            const b = corners[(k + 1) % 4];
            const dx = b[0] - a[0];
            const dy = b[1] - a[1];
            const length = dx * dx + dy * dy;
            const u = std.math.clamp(((x - a[0]) * dx + (y - a[1]) * dy) / @max(length, 1e-20), 0, 1);
            const p: [2]f32 = .{ a[0] + u * dx, a[1] + u * dy };
            const d = (p[0] - x) * (p[0] - x) + (p[1] - y) * (p[1] - y);
            const interior: [2]f32 = .{ p[0] + (centre[0] - p[0]) * 1e-5, p[1] + (centre[1] - p[1]) * 1e-5 };
            if (d <= best and geometry.hitNode(t, @intCast(i), interior)) {
                best = d;
                found = @intCast(i);
            }
        }
    }
    return found;
}

test "transformed pointer and rounded ancestor clip agree with paint geometry" {
    const layout = @import("../layout/layout.zig");
    const Texts = @import("../core/texts.zig").Texts;
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 8);
    var tx = Texts.init(&carver, 1);
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(100) } });
    const clip = t.push(root, .none, &.{ .size = .{ .px(40), .px(40) }, .clip = true, .radius = 20, .transform = .{ 1, 0, 0, 1, 80, 0 } });
    const child = t.push(clip, .none, &.{ .size = .{ .fill, .fill } });
    t.c.sense[child] = @bitCast(Sense.button);
    t.seal(clip);
    t.seal(root);
    layout.run(&t, &tx, .{ 200, 100 });
    try testing.expectEqual(child, at(&t, 100, 20, .any));
    try testing.expectEqual(none, at(&t, 20, 20, .any));
    try testing.expectEqual(none, at(&t, 80, 0, .any));
    try testing.expectEqual(none, near(&t, 80, 0, .any, 0));
}

const testing = std.testing;
const mem = @import("../core/mem.zig");

/// root 200 x 100 with two 40 x 40 buttons side by side, 10 px apart: a at x 0..40, b at 50..90.
fn twoButtons(raw: []align(mem.column_align) u8) Tree {
    const layout = @import("../layout/layout.zig");
    const Texts = @import("../core/texts.zig").Texts;
    var carver: mem.Carver = .{ .buf = raw };
    var t = Tree.init(&carver, 16);
    var tx = Texts.init(&carver, 1);
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(200), .px(100) }, .gap = 10 });
    const a = t.push(root, types.Id.from("a"), &.{ .size = .{ .px(40), .px(40) } });
    const b = t.push(root, types.Id.from("b"), &.{ .size = .{ .px(40), .px(40) } });
    t.seal(root);
    t.c.sense[a] = @bitCast(Sense.button);
    t.c.sense[b] = @bitCast(Sense.button);
    layout.run(&t, &tx, .{ 200, 100 });
    return t;
}

test "near: the closest node within slop wins, a node under the point always wins" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    const t = twoButtons(&raw);
    // Under a: distance 0.
    try testing.expectEqual(@as(u32, 1), near(&t, 20, 20, .any, 8));
    // In the gap, 2 px from a and 8 from b.
    try testing.expectEqual(@as(u32, 1), near(&t, 42, 20, .any, 8));
    // 1 px from b, 9 from a.
    try testing.expectEqual(@as(u32, 2), near(&t, 49, 20, .any, 8));
    // Below a, 5 px down: within 8, not within 4.
    try testing.expectEqual(@as(u32, 1), near(&t, 20, 45, .any, 8));
    try testing.expectEqual(none, near(&t, 20, 45, .any, 4));
    // Nothing that senses a drag.
    try testing.expectEqual(none, near(&t, 20, 20, .{ .drag = true }, 8));
    // Slop 0 is `at`, half-open edges included.
    const probes = [_][2]f32{ .{ 0, 0 }, .{ 40, 20 }, .{ 39, 39 }, .{ 45, 20 }, .{ 50, 40 }, .{ 89, 0 } };
    for (probes) |p| try testing.expectEqual(at(&t, p[0], p[1], .any), near(&t, p[0], p[1], .any, 0));
}

/// Scalar references, written the obvious way, for the SIMD sweeps to match.
fn atScalar(t: *const Tree, x: f32, y: f32, want: Sense) u32 {
    const c = &t.c;
    var found: u32 = none;
    for (0..t.len) |i| {
        const r: types.Rect = .{ .x0 = c.vis[0][i], .y0 = c.vis[1][i], .x1 = c.vis[2][i], .y1 = c.vis[3][i] };
        if (r.contains(x, y) and (c.sense[i] & @as(u8, @bitCast(want))) != 0) found = @intCast(i);
    }
    return found;
}
fn nearScalar(t: *const Tree, x: f32, y: f32, want: Sense, slop: f32) u32 {
    const c = &t.c;
    var found: u32 = none;
    var best: f32 = types.inf;
    for (0..t.len) |i| {
        if (c.visible[i] == 0 or (c.sense[i] & @as(u8, @bitCast(want))) == 0) continue;
        const dx = @max(c.vis[0][i] - x, x - c.vis[2][i], 0);
        const dy = @max(c.vis[1][i] - y, y - c.vis[3][i], 0);
        const inside = x >= c.vis[0][i] and x < c.vis[2][i] and y >= c.vis[1][i] and y < c.vis[3][i];
        const d = if (inside) 0 else @max(dx * dx + dy * dy, std.math.floatTrueMin(f32));
        if (d <= slop * slop and d <= best) {
            best = d;
            found = @intCast(i);
        }
    }
    return found;
}

/// 40 floating 30 x 30 boxes scattered over a clipping 200 x 200 root, overlapping each other
/// and spilling past the clip, with senses that vary by row. Rows run past several vectors at
/// every lane count, so ties across lanes and across steps are both exercised.
fn scattered(raw: []align(mem.column_align) u8) Tree {
    const layout = @import("../layout/layout.zig");
    const Texts = @import("../core/texts.zig").Texts;
    var carver: mem.Carver = .{ .buf = raw };
    var t = Tree.init(&carver, 64);
    var tx = Texts.init(&carver, 1);
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(200) }, .clip = true });
    var seed: u32 = 12345;
    for (0..40) |k| {
        seed = seed *% 1103515245 +% 12345;
        const ox: f32 = @floatFromInt((seed >> 8) % 220);
        const oy: f32 = @floatFromInt((seed >> 20) % 220);
        const i = t.push(root, .none, &.{ .float = true, .offset = .{ ox - 10, oy - 10 }, .size = .{ .px(30), .px(30) } });
        t.c.sense[i] = @intCast(k % 5); // 0 (inert), hover, click, both, drag
    }
    t.seal(root);
    layout.run(&t, &tx, .{ 200, 200 });
    return t;
}

test "at and near match the scalar references on a scattered, clipped, overlapping tree" {
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    const t = scattered(&raw);
    const wants = [_]Sense{ .any, .{ .hover = true }, .{ .click = true }, .{ .drag = true } };
    var hits: u32 = 0;
    var y: f32 = -12;
    while (y < 215) : (y += 3.5) {
        var x: f32 = -12;
        while (x < 215) : (x += 3.5) {
            for (wants) |w| {
                const got = at(&t, x, y, w);
                try testing.expectEqual(atScalar(&t, x, y, w), got);
                hits += @intFromBool(got != none);
                for ([_]f32{ 0, 2, 9 }) |slop|
                    try testing.expectEqual(nearScalar(&t, x, y, w, slop), near(&t, x, y, w, slop));
            }
        }
    }
    // The grid did find things; an always-`none` sweep would pass the comparisons otherwise.
    try testing.expect(hits > 100);
}

fn atLayeredScalar(t: *const Tree, layer: []const u8, x: f32, y: f32, want: Sense) u32 {
    const c = &t.c;
    var found: u32 = none;
    var best: u8 = 0;
    for (0..t.len) |i| {
        const r: types.Rect = .{ .x0 = c.vis[0][i], .y0 = c.vis[1][i], .x1 = c.vis[2][i], .y1 = c.vis[3][i] };
        if (r.contains(x, y) and (c.sense[i] & @as(u8, @bitCast(want))) != 0 and layer[i] >= best) {
            found = @intCast(i);
            best = layer[i];
        }
    }
    return found;
}

test "atLayered matches the scalar reference, and is `at` when every layer is 0" {
    const overlay = @import("../layout/overlay.zig");
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    const t = scattered(&raw);
    var lraw: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &lraw };
    var ly = overlay.Layers.init(&carver, t.cap);
    ly.reset();
    overlay.order(&t, &ly);
    const wants = [_]Sense{ .any, .{ .hover = true }, .{ .click = true }, .{ .drag = true } };
    var y: f32 = -12;
    while (y < 215) : (y += 7) {
        var x: f32 = -12;
        while (x < 215) : (x += 7) {
            for (wants) |w| try testing.expectEqual(at(&t, x, y, w), atLayered(&t, ly.c.layer, x, y, w));
        }
    }
    // Raise a scattering of rows (3 layers, some above earlier rows, some below later ones).
    for (1..t.len) |i| ly.c.own[i] = @intCast((i * 7) % 4);
    overlay.order(&t, &ly);
    var differs: u32 = 0;
    y = -12;
    while (y < 215) : (y += 3.5) {
        var x: f32 = -12;
        while (x < 215) : (x += 3.5) {
            for (wants) |w| {
                const got = atLayered(&t, ly.c.layer, x, y, w);
                try testing.expectEqual(atLayeredScalar(&t, ly.c.layer, x, y, w), got);
                differs += @intFromBool(got != at(&t, x, y, w));
            }
        }
    }
    // Layers did change some answers; otherwise the comparison proves nothing new.
    try testing.expect(differs > 20);
}

test "atLayered: an open menu covers the later body row under it" {
    const overlay = @import("../layout/overlay.zig");
    const layout = @import("../layout/layout.zig");
    const Texts = @import("../core/texts.zig").Texts;
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 16);
    var tx = Texts.init(&carver, 1);
    var ly = overlay.Layers.init(&carver, 16);
    // root { button { menu (floating, 80 x 60 over the body) { item } } body }
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(200) } });
    const button = t.push(root, .none, &.{ .size = .{ .px(40), .px(20) } });
    const menu = t.push(button, .none, &.{ .size = .{ .px(80), .px(60) }, .float = true, .offset = .{ 0, 20 } });
    const item = t.push(menu, .none, &.{ .size = .{ .fill, .px(20) } });
    t.seal(menu);
    t.seal(button);
    const body = t.push(root, .none, &.{ .size = .{ .fill, .fill } });
    t.seal(root);
    for ([_]u32{ button, menu, item, body }) |k| t.c.sense[k] = @bitCast(Sense.button);
    layout.run(&t, &tx, .{ 200, 200 });
    ly.reset();
    ly.c.own[menu] = 1;
    overlay.order(&t, &ly);
    // Row order alone puts the body on top of the menu.
    try testing.expectEqual(body, at(&t, 10, 50, .any));
    try testing.expectEqual(menu, atLayered(&t, ly.c.layer, 10, 50, .any));
    try testing.expectEqual(item, atLayered(&t, ly.c.layer, 10, 30, .any));
    // Outside the menu the body is hit as before; above it, the button.
    try testing.expectEqual(body, atLayered(&t, ly.c.layer, 150, 150, .any));
    try testing.expectEqual(button, atLayered(&t, ly.c.layer, 10, 10, .any));
    try testing.expectEqual(none, atLayered(&t, ly.c.layer, 300, 10, .any));
}

test "at: nothing is hit outside the clip, in an inert node, or in the padding rows" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    var t = twoButtons(&raw);
    // Outside the root, and inside the root but on no sensing node.
    try testing.expectEqual(none, at(&t, 300, 20, .any));
    try testing.expectEqual(none, at(&t, 150, 80, .any));
    // A stale row past `len` with a big rect: finalize zeroed its sense, so it is never hit.
    const pad = t.len;
    t.c.vis[0][pad] = -1000;
    t.c.vis[1][pad] = -1000;
    t.c.vis[2][pad] = 1000;
    t.c.vis[3][pad] = 1000;
    try testing.expectEqual(none, at(&t, 150, 80, .any));
    try testing.expectEqual(none, near(&t, 150, 80, .any, 20)); // 60 px from b
    // An empty tree hits nothing.
    t.len = 0;
    try testing.expectEqual(none, at(&t, 20, 20, .any));
    try testing.expectEqual(none, near(&t, 20, 20, .any, 8));
}
