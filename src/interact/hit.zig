//! hit: which node is under a point. One SIMD sweep over the visible rects, no early exit.
//! Tier 0: no allocator, no I/O. Ported from prototype/ui.zig ("hit").

const std = @import("std");
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

/// Like `at`, for a finger: the node nearest to (x, y) within `slop` logical pixels that takes
/// part in `want`, or `none`. A node under the point is at distance 0, so it always beats one
/// that is only near; among equal distances the topmost (latest) row wins, as in `at`. With
/// `slop` 0 the result is `at`'s. Only visible nodes count, and distance is to the clipped rect.
pub fn near(t: *const Tree, x: f32, y: f32, want: Sense, slop: f32) u32 {
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
