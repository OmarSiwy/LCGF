//! incremental: lay out again only what a change can reach. The caller changes a node's inputs
//! in place (a size, padding, gap, alignment...), marks it dirty on the axes it touched, and
//! calls `update` instead of `layout.run`; the columns come out as a full run would leave them.
//! Structure (push, flow) must not change between frames; a new tree needs `layout.run`.
//! Tier 0: the table is carved from the caller's buffer like `Tree`.

const std = @import("std");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const layout = @import("layout.zig");
const Axis = types.Axis;

pub const Dirty = struct {
    cap: u32,
    c: Columns,

    pub const Columns = struct {
        /// 1 when the node's own inputs on that axis changed since the last update.
        mark: [2][]u8,
    };

    pub fn init(carver: *mem.Carver, cap: u32) Dirty {
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }

    /// Records that node `i`'s inputs on `axis` changed. Inputs that are not per-axis (gap,
    /// alignment, direction, shrink) touch both axes.
    pub fn mark(d: *Dirty, i: u32, axis: Axis) void {
        d.c.mark[@backingInt(axis)][i] = 1;
    }
};

/// Lays out what the marks reach and clears them. With no marks the columns are left as they
/// are: an idle frame does no layout work.
pub fn update(t: *Tree, tx: *Texts, d: *Dirty, viewport: [2]f32) void {
    std.debug.assert(t.len <= d.cap);
    const n = simd.padded(t.len);
    var any: simd.Bytes = @splat(0);
    var i: usize = 0;
    while (i < n) : (i += simd.lanes) {
        inline for (0..2) |a| any |= d.c.mark[a][i..][0..simd.lanes].*;
    }
    if (@reduce(.Or, any) == 0) return;
    layout.run(t, tx, viewport);
    inline for (0..2) |a| @memset(d.c.mark[a][0..n], 0);
}

const testing = std.testing;
const check = @import("check.zig");
const inf = types.inf;

/// One random change to a node's inputs, applied the same way to two identical trees.
const Change = struct {
    node: u32,
    axis: u1,
    kind: u4,
    v: f32,

    fn random(r: std.Random, len: u32) Change {
        return .{
            .node = r.uintLessThan(u32, len),
            .axis = r.int(u1),
            .kind = r.uintLessThan(u4, 10),
            .v = @floatFromInt(r.uintLessThan(u32, 120)),
        };
    }

    /// Writes the change into `t` and marks what it touched, if `d` is given.
    fn apply(ch: Change, t: *Tree, d: ?*Dirty) void {
        const c = &t.c;
        const i = ch.node;
        const a = ch.axis;
        var both = false;
        switch (ch.kind) {
            0 => { // px
                c.min[a][i] = ch.v;
                c.max[a][i] = ch.v;
                c.grow[a][i] = 0;
                c.pct[a][i] = 0;
            },
            1 => { // fit
                c.min[a][i] = 0;
                c.max[a][i] = inf;
                c.grow[a][i] = 0;
                c.pct[a][i] = 0;
            },
            2 => { // grow
                c.min[a][i] = 0;
                c.max[a][i] = inf;
                c.grow[a][i] = 1 + @mod(ch.v, 3);
                c.pct[a][i] = 0;
            },
            3 => c.pct[a][i] = ch.v / 120,
            4 => c.pad_lo[a][i] = @mod(ch.v, 8),
            5 => c.offset[a][i] = ch.v,
            6 => c.scroll[a][i] = @mod(ch.v, 5),
            7 => {
                c.gap[i] = @mod(ch.v, 7);
                both = true;
            },
            8 => {
                c.align_main[i] = @mod(ch.v, 3) / 2;
                c.align_cross[i] = @mod(ch.v + 1, 3) / 2;
                c.shrink[i] = 1 - c.shrink[i];
                both = true;
            },
            else => {
                std.mem.swap(f32, &c.main[0][i], &c.main[1][i]);
                both = true;
            },
        }
        const dd = d orelse return;
        dd.mark(i, @fromBackingInt(@intCast(a)));
        if (both) dd.mark(i, @fromBackingInt(@intCast(1 - a)));
    }
};

/// Every layout output and scratch column a later pass or the host reads, rows [0, len).
fn expectSameLayout(want: *const Tree, got: *const Tree) !void {
    const n = want.len;
    try testing.expectEqual(n, got.len);
    const w = &want.c;
    const g = &got.c;
    inline for (0..2) |a| {
        try testing.expectEqualSlices(f32, w.size[a][0..n], g.size[a][0..n]);
        try testing.expectEqualSlices(f32, w.pos[a][0..n], g.pos[a][0..n]);
        try testing.expectEqualSlices(f32, w.nat[a][0..n], g.nat[a][0..n]);
        try testing.expectEqualSlices(f32, w.fit[a][0..n], g.fit[a][0..n]);
        try testing.expectEqualSlices(f32, w.used[a][0..n], g.used[a][0..n]);
        try testing.expectEqualSlices(f32, w.grow_inv[a][0..n], g.grow_inv[a][0..n]);
    }
    inline for (0..4) |k| {
        try testing.expectEqualSlices(f32, w.rect[k][0..n], g.rect[k][0..n]);
        try testing.expectEqualSlices(f32, w.vis[k][0..n], g.vis[k][0..n]);
    }
    try testing.expectEqualSlices(f32, w.gap_total[0..n], g.gap_total[0..n]);
    try testing.expectEqualSlices(f32, w.cursor[0..n], g.cursor[0..n]);
    try testing.expectEqualSlices([4]f32, w.child_clip[0..n], g.child_clip[0..n]);
    try testing.expectEqualSlices(u8, w.visible[0..n], g.visible[0..n]);
}

/// Two identical random trees, laid out in full. Frame after frame the same random changes go
/// into both; `full` is laid out from scratch, `inc` through `update`. They must agree bit for bit.
fn randomFrames(seed: u64, trees: u32, frames: u32, changes: u32) !void {
    var raw: [2][1024 * 1024]u8 align(mem.column_align) = undefined;
    var c0: mem.Carver = .{ .buf = &raw[0] };
    var c1: mem.Carver = .{ .buf = &raw[1] };
    var full = Tree.init(&c0, 600);
    var inc = Tree.init(&c1, 600);
    var full_tx = Texts.init(&c0, 1);
    var inc_tx = Texts.init(&c1, 1);
    var d = Dirty.init(&c1, 600);
    const vp: [2]f32 = .{ 1280, 800 };
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    for (0..trees) |_| {
        const tree_seed = r.int(u64);
        const n = 1 + r.uintLessThan(u32, full.cap);
        var a: std.Random.DefaultPrng = .init(tree_seed);
        var b: std.Random.DefaultPrng = .init(tree_seed);
        check.randomTree(&full, a.random(), n);
        check.randomTree(&inc, b.random(), n);
        layout.run(&full, &full_tx, vp);
        layout.run(&inc, &inc_tx, vp);
        for (0..frames) |_| {
            for (0..r.uintAtMost(u32, changes)) |_| {
                const ch = Change.random(r, n);
                ch.apply(&full, null);
                ch.apply(&inc, &d);
            }
            layout.run(&full, &full_tx, vp);
            update(&inc, &inc_tx, &d, vp);
            try expectSameLayout(&full, &inc);
        }
    }
}

test "update: equals a full layout after random changes to random trees" {
    try randomFrames(0x111, 40, 8, 3);
}

test "update: no marks, no work" {
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 8);
    var tx = Texts.init(&carver, 1);
    var d = Dirty.init(&carver, 8);
    _ = t.push(0, .none, &.{ .size = .{ .px(100), .px(50) } });
    t.seal(0);
    layout.run(&t, &tx, .{ 100, 50 });
    t.c.rect[2][0] = -1; // a stale output stays stale: nothing ran
    update(&t, &tx, &d, .{ 100, 50 });
    try testing.expectEqual(-1, t.c.rect[2][0]);
    d.mark(0, .x);
    update(&t, &tx, &d, .{ 100, 50 });
    try testing.expectEqual(100, t.c.rect[2][0]);
    try testing.expectEqual(0, d.c.mark[0][0]);
}
