//! Checks for rewritten layout passes: random trees, and the prototype's passes kept verbatim as
//! the reference a faster pass must agree with. Tier 0: the random source is caller-supplied.

const std = @import("std");
const types = @import("../core/types.zig");
const simd = @import("../core/simd.zig");
const Tree = @import("../core/tree.zig").Tree;
const layout = @import("layout.zig");
const Axis = types.Axis;
const Size = types.Size;
const b01 = simd.b2f;

/// Pushes `n` nodes (n <= t.cap) of random structure and style: every sizing mode, padding,
/// gaps, floating, shrinking, min/max, alignment, offsets and scroll. Sealed and ready for
/// `layout.prepare`.
pub fn randomTree(t: *Tree, r: std.Random, n: u32) void {
    std.debug.assert(n > 0 and n <= t.cap);
    t.reset();
    var open: [64]u32 = undefined;
    var depth: usize = 1;
    open[0] = t.push(0, .none, &randomStyle(r));
    while (t.len < n) {
        // Close the innermost open node now and then, but keep the root open.
        if (depth > 1 and (depth == open.len or r.uintLessThan(u32, 4) == 0)) {
            depth -= 1;
            t.seal(open[depth]);
            continue;
        }
        open[depth] = t.push(open[depth - 1], .none, &randomStyle(r));
        depth += 1;
    }
    while (depth > 0) {
        depth -= 1;
        t.seal(open[depth]);
    }
}

/// `randomTree` with runs of siblings: now and then the innermost open node gets up to 40
/// leaves in a row, so a pass that works run by run (runs.zig) meets runs of every length
/// around a whole vector. Sizes are fractions, so a sum taken in another order would round
/// differently, and a few nodes clip or have a border or an opacity (an extras row).
pub fn randomRuns(t: *Tree, r: std.Random, n: u32) void {
    std.debug.assert(n > 0);
    std.debug.assert(n <= t.cap);
    t.reset();
    var open: [64]u32 = undefined;
    var depth: usize = 1;
    open[0] = t.push(0, .none, &randomStyle(r));
    while (t.len < n) {
        if (depth > 1 and (depth == open.len or r.uintLessThan(u32, 4) == 0)) {
            depth -= 1;
            t.seal(open[depth]);
            continue;
        }
        if (r.uintLessThan(u32, 3) == 0) {
            var leaves = 1 + r.uintLessThan(u32, 40);
            while (leaves > 0 and t.len < n) : (leaves -= 1) {
                var s = randomStyle(r);
                s.size[0] = .px(@as(f32, @floatFromInt(1 + r.uintLessThan(u32, 4000))) / 97);
                s.clip = r.uintLessThan(u32, 16) == 0;
                if (r.uintLessThan(u32, 24) == 0) s.border = 1.5;
                if (r.uintLessThan(u32, 24) == 0) s.opacity = 0.5;
                t.seal(t.push(open[depth - 1], .none, &s));
            }
            continue;
        }
        var s = randomStyle(r);
        s.clip = r.uintLessThan(u32, 8) == 0;
        open[depth] = t.push(open[depth - 1], .none, &s);
        depth += 1;
    }
    while (depth > 0) {
        depth -= 1;
        t.seal(open[depth]);
    }
}

/// `layout.fit`'s fold as it was row by row, kept as the reference for `runs.fit`: rows after
/// `first` up to `last`, last row first, each into its parent's `fit` and `grow_sum` on axis
/// `a`.
pub fn fitRef(t: *Tree, a: usize, first: u32, last: u32) void {
    std.debug.assert(first < last);
    std.debug.assert(last <= t.len);
    const c = &t.c;
    var i: u32 = last;
    while (i > first + 1) {
        i -= 1;
        const content = c.fit[a][i] + c.main[a][i] * c.gap_total[i];
        var nat = content + c.pad_lo[a][i] + c.pad_hi[a][i];
        nat = simd.minF(simd.maxF(nat, c.min[a][i]), c.max[a][i]);
        c.nat[a][i] = nat;
        const p = c.parent[i];
        const contrib = nat * c.flow[i];
        const fp = c.fit[a][p];
        const sum = fp + contrib;
        const mx = simd.selF(fp < contrib, contrib, fp);
        c.fit[a][p] = simd.selF(c.main[a][p] != 0, sum, mx);
        c.grow_sum[a][p] += c.grow[a][i] * c.flow[i];
    }
}

fn randomStyle(r: std.Random) types.Style {
    var s: types.Style = .{};
    s.dir = if (r.boolean()) .x else .y;
    for (&s.size) |*sz| sz.* = switch (r.uintLessThan(u32, 4)) {
        0 => .fit,
        1 => .px(@floatFromInt(r.uintLessThan(u32, 200))),
        2 => .grow(@floatFromInt(1 + r.uintLessThan(u32, 3))),
        else => .pct(@as(f32, @floatFromInt(r.uintLessThan(u32, 100))) / 100),
    };
    for (0..2) |a| {
        if (r.uintLessThan(u32, 8) == 0) s.min[a] = @floatFromInt(r.uintLessThan(u32, 50));
        if (r.uintLessThan(u32, 8) == 0) s.max[a] = @floatFromInt(50 + r.uintLessThan(u32, 150));
        s.offset[a] = @floatFromInt(r.uintLessThan(u32, 3));
        s.scroll[a] = @floatFromInt(r.uintLessThan(u32, 3));
    }
    for (&s.pad) |*p| p.* = @floatFromInt(r.uintLessThan(u32, 6));
    s.gap = @floatFromInt(r.uintLessThan(u32, 6));
    s.main = @fromBackingInt(@intCast(r.uintLessThan(u8, 3)));
    s.cross = @fromBackingInt(@intCast(r.uintLessThan(u8, 3)));
    s.shrink = r.uintLessThan(u32, 4) == 0;
    s.float = r.uintLessThan(u32, 8) == 0;
    return s;
}

/// prototype/ui.zig `layout.resolve`, verbatim: the reference for the K-coefficient form.
pub fn resolveRef(t: *Tree, axis: Axis, viewport: f32) void {
    const a = @backingInt(axis);
    if (t.len == 0) return;
    const c = &t.c;
    const size = c.size[a];
    size[0] = viewport;
    for (1..t.len) |i| {
        const p = c.parent[i];
        const nat = c.nat[a][i];
        const inner = @max(size[p] - c.pad_lo[a][p] - c.pad_hi[a][p], 0);
        const main = c.main[a][p];
        const taken = c.fit[a][p] + c.gap_total[p];
        const free = @max(inner - taken, 0);
        const share = free * c.grow[a][i] * c.grow_inv[a][p];
        const stretched = nat + b01(c.grow[a][i] > 0) * (inner - nat);
        const flowed = stretched + main * (nat + share - stretched);
        const has_pct = b01(c.pct[a][i] >= 0);
        const of_parent = c.pct[a][i] * inner;
        const in_flow = flowed + has_pct * (of_parent - flowed);
        const floating = nat + has_pct * (of_parent - nat);
        const fl = c.flow[i];
        var s = floating + fl * (in_flow - floating);
        const room = @max(inner - main * (taken - nat), 0);
        s -= c.shrink[i] * fl * @max(s - room, 0);
        s = @min(@max(s, c.min[a][i]), c.max[a][i]);
        size[i] = s;
        c.used[a][p] += s * fl;
    }
}

/// How far a regrouped pass may drift from the reference, in pixels. The prototype rounds
/// differences such as `nat + (inner - nat)` that the K form takes as exactly `inner`, so the two
/// disagree by the rounding of intermediates up to a few thousand pixels (ulp(4096) = 0.0005),
/// far below the half pixel that `finalize` snaps to.
pub const tolerance: f32 = 4e-3;

/// Largest absolute difference between two columns over the first `n` rows. Equal infinities
/// count as equal; a NaN on either side counts as infinitely far.
pub fn maxDiff(want: []const f32, got: []const f32, n: u32) f32 {
    var worst: f32 = 0;
    for (want[0..n], got[0..n]) |w, g| {
        const d = if (w == g) 0 else @abs(w - g);
        worst = if (d <= worst) worst else if (d > worst) d else std.math.inf(f32);
    }
    return worst;
}

const testing = std.testing;
const mem = @import("../core/mem.zig");

test "resolve: the K-coefficient form gives the prototype's sizes on random trees" {
    var raw: [512 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 1000);
    var prng: std.Random.DefaultPrng = .init(0x1a70);
    for (0..200) |_| {
        randomTree(&t, prng.random(), 1 + prng.random().uintLessThan(u32, t.cap));
        layout.prepare(&t);
        for ([2]Axis{ .x, .y }, [2]f32{ 1280, 800 }) |axis, vp| {
            const a = @backingInt(axis);
            layout.fit(&t, axis);
            resolveRef(&t, axis, vp);
            var want: [1000]f32 = undefined;
            var want_used: [1000]f32 = undefined;
            @memcpy(want[0..t.len], t.c.size[a][0..t.len]);
            @memcpy(want_used[0..t.len], t.c.used[a][0..t.len]);
            @memset(t.c.used[a], 0);
            layout.resolve(&t, axis, vp);
            try testing.expect(maxDiff(want[0..t.len], t.c.size[a], t.len) <= tolerance);
            try testing.expect(maxDiff(want_used[0..t.len], t.c.used[a], t.len) <= tolerance);
        }
    }
}
