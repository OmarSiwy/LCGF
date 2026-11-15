//! layout: a fixed sequence of linear passes over the tree columns. No solver, no re-measure loop,
//! so the cost is the same every frame and proportional to the node count. Tier 0: no allocator,
//! no I/O. Ported from prototype/ui.zig ("layout").
//!
//!   prepare            SIMD     clear scratch, gap totals

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;

const W = simd.lanes;

/// SIMD. Clears per-frame scratch and derives `gap_total`.
pub fn prepare(t: *Tree) void {
    const c = &t.c;
    const n = simd.padded(t.len);
    const zero = simd.f(0);
    var i: usize = 0;
    while (i < n) : (i += W) {
        inline for (0..2) |a| {
            simd.storeF(c.fit[a], i, zero);
            simd.storeF(c.grow_sum[a], i, zero);
            simd.storeF(c.used[a], i, zero);
        }
        simd.storeF(c.cursor, i, zero);
        const gaps = @max(simd.loadF(c.nkids, i) - simd.f(1), zero);
        simd.storeF(c.gap_total, i, simd.loadF(c.gap, i) * gaps);
    }
}

const testing = std.testing;
const mem = @import("../core/mem.zig");
const Texts = @import("../core/texts.zig").Texts;
const Strings = @import("../core/strings.zig").Strings;
const Id = types.Id;

/// The tree of the prototype's "tier 0 alone" test (prototype/example.zig), so every pass is
/// checked against the column values the prototype computes for it.
///
///   root  px(400) x px(300), pad 10, gap 5, clips
///   ├ bar   along x, fill x px(40), gap 4
///   │ ├ a   px(100) x fill
///   │ └ b   fill x fill
///   ├ col   px(100) x fit
///   │ └ para  shrinks; one text run of 24 bytes at 10 px that wraps
///   └ body  fill x fill
const Scene = struct {
    t: Tree,
    tx: Texts,

    const root = 0;
    const bar = 1;
    const a = 2;
    const b = 3;
    const col = 4;
    const para = 5;
    const body = 6;

    fn init(raw: []align(mem.column_align) u8) Scene {
        var carver: mem.Carver = .{ .buf = raw };
        var t = Tree.init(&carver, 64);
        var tx = Texts.init(&carver, 8);
        var strings: Strings = .{ .buf = carver.slice(u8, 256) };

        std.debug.assert(root == t.push(0, Id.from("ui.root"), &.{ .size = .{ .px(400), .px(300) }, .pad = @splat(10), .gap = 5, .clip = true }));
        std.debug.assert(bar == t.push(root, .none, &.{ .dir = .x, .size = .{ .fill, .px(40) }, .gap = 4 }));
        std.debug.assert(a == t.push(bar, Id.from("a"), &.{ .size = .{ .px(100), .fill } }));
        std.debug.assert(b == t.push(bar, Id.from("b"), &.{ .size = .{ .fill, .fill } }));
        t.seal(bar);
        std.debug.assert(col == t.push(root, .none, &.{ .size = .{ .px(100), .fit } }));
        std.debug.assert(para == t.push(col, .none, &.{ .shrink = true }));
        t.c.text[para] = tx.push(para, strings.add("twenty-four characters!!"), &.{ .px = 10, .wrap = true });
        t.seal(col);
        std.debug.assert(body == t.push(root, Id.from("body"), &.{ .size = .{ .fill, .fill } }));
        t.seal(root);
        // What fonts.Mono{ .advance = 0.5, .line = 1.2 }.measure writes: 24 bytes * 5 px, one
        // 12 px line. The font lane owns the measuring; layout only reads the extents.
        tx.c.w[0] = 120;
        tx.c.h[0] = 12;
        return .{ .t = t, .tx = tx };
    }
};

fn expectCol(want: []const f32, col: []const f32) !void {
    try testing.expectEqualSlices(f32, want, col[0..want.len]);
}

test "prepare: zeroes the scratch columns and sets gap_total = gap * (in-flow children - 1)" {
    var raw: [256 * 1024]u8 align(mem.column_align) = undefined;
    var s = Scene.init(&raw);
    const c = &s.t.c;
    // Stale values from a previous frame, padding rows included.
    inline for (0..2) |ax| {
        @memset(c.fit[ax], 7);
        @memset(c.grow_sum[ax], 7);
        @memset(c.used[ax], 7);
    }
    @memset(c.cursor, 7);
    prepare(&s.t);
    const n = simd.padded(s.t.len);
    const zeros: [64]f32 = @splat(0);
    inline for (0..2) |ax| {
        try expectCol(zeros[0..n], c.fit[ax]);
        try expectCol(zeros[0..n], c.grow_sum[ax]);
        try expectCol(zeros[0..n], c.used[ax]);
    }
    try expectCol(zeros[0..n], c.cursor);
    // root: 3 children, gap 5; bar: 2 children, gap 4; col: one child; leaves: none.
    try expectCol(&.{ 10, 4, 0, 0, 0, 0, 0 }, c.gap_total);
}
