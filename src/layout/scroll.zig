//! scroll: what scroll containers need from layout. Tier 0: no allocator, no I/O. Scrolling
//! itself is in the core passes already: `Style.scroll` is subtracted from the children's
//! positions in `place` and `Style.clip` cuts them to the node in `finalize` (prototype/ui.zig).
//! This file adds the numbers around it.
//!
//!   extent     SIMD   content size of every node, from `fit`
//!   clamp      SIMD   scroll offsets kept inside [0, extent - size]
//!   intoView   query  the scroll that brings a descendant into view

const std = @import("std");
const simd = @import("../core/simd.zig");
const Tree = @import("../core/tree.zig").Tree;

const W = simd.lanes;

/// SIMD. Writes the content extent of every node on both axes into `out`: the size its in-flow
/// content needs, padding included, before `min`, `max` or the parent cut it down. This is the
/// `fit` column (prototype `Tree.Columns.fit`: the sum of the children along the main axis, the
/// max across it) plus the gaps and padding, the same sum `fit` clamps into `nat`. A scroll
/// container can move its content by up to `extent - size`. Floating children are not part of
/// it. Run after `fit` on both axes; `out` columns need `simd.padded(t.len)` rows.
pub fn extent(t: *const Tree, out: [2][]f32) void {
    const c = &t.c;
    const n = simd.padded(t.len);
    var i: usize = 0;
    while (i < n) : (i += W) {
        const gaps = simd.loadF(c.gap_total, i);
        inline for (0..2) |a| {
            const content = simd.loadF(c.fit[a], i) + simd.loadF(c.main[a], i) * gaps;
            simd.storeF(out[a], i, content + simd.loadF(c.pad_lo[a], i) + simd.loadF(c.pad_hi[a], i));
        }
    }
}

/// SIMD. Clamps every node's `scroll` to [0, max(extent - size, 0)] on both axes, so content is
/// never scrolled past its start or its end, and a node whose content fits does not scroll. Run
/// after `resolve` on both axes and `extent`, before `place`. The clamped value is what the
/// application keeps for the next frame (a wheel delta is added to it, then clamped again).
pub fn clamp(t: *Tree, ext: [2][]const f32) void {
    const c = &t.c;
    const n = simd.padded(t.len);
    const zero = simd.f(0);
    var i: usize = 0;
    while (i < n) : (i += W) {
        inline for (0..2) |a| {
            const room = @max(simd.loadF(ext[a], i) - simd.loadF(c.size[a], i), zero);
            simd.storeF(c.scroll[a], i, @min(@max(simd.loadF(c.scroll[a], i), zero), room));
        }
    }
}

/// The scroll offset of `container` that brings `target`, one of its descendants, fully into
/// view with the least movement: unchanged if it is already visible, else its near edge is put
/// at the near inner edge (scrolling back) or its far edge at the far inner edge (scrolling on).
/// A target larger than the container shows its start. The result is clamped like `clamp`.
/// A query over the columns after `place`; the caller writes the result into its scroll state
/// for the next frame. Nested scroll containers are one query each, innermost first.
pub fn intoView(t: *const Tree, ext: [2][]const f32, container: u32, target: u32) [2]f32 {
    const c = &t.c;
    var out: [2]f32 = undefined;
    inline for (0..2) |a| {
        const cur = c.scroll[a][container];
        const inner = c.size[a][container] - c.pad_lo[a][container] - c.pad_hi[a][container];
        // Where the target starts in the container's content, independent of the current scroll.
        const start = c.pos[a][target] - c.pos[a][container] - c.pad_lo[a][container] + cur;
        const want = @min(@max(cur, start + c.size[a][target] - inner), start);
        const room = @max(ext[a][container] - c.size[a][container], 0);
        out[a] = @min(@max(want, 0), room);
    }
    return out;
}

const testing = std.testing;
const mem = @import("../core/mem.zig");
const layout = @import("layout.zig");
const Texts = @import("../core/texts.zig").Texts;
const Strings = @import("../core/strings.zig").Strings;
const types = @import("../core/types.zig");

const cap = 64;

/// A tree, a text list and two extent columns in a caller-owned buffer, for the tests.
const Scene = struct {
    raw: [256 * 1024]u8 align(mem.column_align) = undefined,
    t: Tree = undefined,
    tx: Texts = undefined,
    ext: [2][]f32 = undefined,

    fn init(s: *Scene) void {
        var carver: mem.Carver = .{ .buf = &s.raw };
        s.t = Tree.init(&carver, cap);
        s.tx = Texts.init(&carver, 4);
        s.ext = .{ carver.slice(f32, simd.rows(cap)), carver.slice(f32, simd.rows(cap)) };
    }
    /// Every sizing pass of `layout.run`, with the text extents already settled.
    fn size(s: *Scene, viewport: [2]f32) void {
        layout.prepare(&s.t);
        layout.applyText(&s.t, &s.tx, .x);
        layout.fit(&s.t, .x);
        layout.resolve(&s.t, .x, viewport[0]);
        layout.applyText(&s.t, &s.tx, .y);
        layout.fit(&s.t, .y);
        layout.resolve(&s.t, .y, viewport[1]);
    }
};

test "extent: content size with gaps and padding, larger than the node when it overflows" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    var strings: Strings = .{ .buf = undefined };
    var bytes: [64]u8 = undefined;
    strings.buf = &bytes;
    // root { list 100x50, pad 3, gap 2, clips { 4 rows of 30 } , label (text 70x12), floater }
    const root = t.push(0, .none, &.{ .size = .{ .px(300), .px(200) } });
    const list = t.push(root, .none, &.{ .size = .{ .px(100), .px(50) }, .pad = @splat(3), .gap = 2, .clip = true });
    var rows: [4]u32 = undefined;
    for (&rows) |*r| r.* = t.push(list, .none, &.{ .size = .{ .px(80), .px(30) } });
    const floater = t.push(list, .none, &.{ .size = .{ .px(500), .px(500) }, .float = true });
    t.seal(list);
    const label = t.push(root, .none, &.{});
    t.c.text[label] = s.tx.push(label, strings.add("seventy"), &.{});
    t.seal(root);
    s.tx.c.w[0] = 70;
    s.tx.c.h[0] = 12;
    s.size(.{ 300, 200 });
    extent(t, s.ext);

    // 4 x 30 + 3 gaps of 2 + padding 3 + 3, while the list is 50 high; across, the widest row.
    try testing.expectEqual(132, s.ext[1][list]);
    try testing.expectEqual(86, s.ext[0][list]);
    try testing.expectEqual(50, t.c.size[1][list]);
    // The floating child counts for nothing. A fixed-size leaf has no content; a text leaf's
    // content is its run.
    _ = floater;
    try testing.expectEqual(0, s.ext[0][rows[0]]);
    try testing.expectEqual(0, s.ext[1][rows[0]]);
    try testing.expectEqual(70, s.ext[0][label]);
    try testing.expectEqual(12, s.ext[1][label]);
    // The root's content is the list stacked over the label, not its own 300 x 200.
    try testing.expectEqual(100, s.ext[0][root]);
    try testing.expectEqual(62, s.ext[1][root]);
}

test "clamp: scroll stays between the content start and its end" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    // root { list 100x50 pad 3, gap 2 { 4 rows of 30 } (content 132 high), short 100x50 { one row } }
    const root = t.push(0, .none, &.{ .size = .{ .px(300), .px(200) } });
    const list = t.push(root, .none, &.{ .size = .{ .px(100), .px(50) }, .pad = @splat(3), .gap = 2, .clip = true });
    var rows: [4]u32 = undefined;
    for (&rows) |*r| r.* = t.push(list, .none, &.{ .size = .{ .px(80), .px(30) } });
    t.seal(list);
    const short = t.push(root, .none, &.{ .size = .{ .px(100), .px(50) }, .clip = true });
    t.seal(t.push(short, .none, &.{ .size = .{ .px(80), .px(30) } }));
    t.seal(short);
    t.seal(root);

    const Case = struct { asked: [2]f32, list: [2]f32, short: [2]f32 };
    const cases = [_]Case{
        // In range: unchanged.
        .{ .asked = .{ 0, 40 }, .list = .{ 0, 40 }, .short = .{ 0, 0 } },
        // Past the end: 132 - 50 = 82 at most on y; the widest row fits across, so x is 0.
        .{ .asked = .{ 30, 500 }, .list = .{ 0, 82 }, .short = .{ 0, 0 } },
        // Before the start.
        .{ .asked = .{ -10, -10 }, .list = .{ 0, 0 }, .short = .{ 0, 0 } },
    };
    for (cases) |k| {
        inline for (0..2) |a| {
            t.c.scroll[a][list] = k.asked[a];
            t.c.scroll[a][short] = k.asked[a];
        }
        s.size(.{ 300, 200 });
        extent(t, s.ext);
        clamp(t, s.ext);
        inline for (0..2) |a| {
            try testing.expectEqual(k.list[a], t.c.scroll[a][list]);
            try testing.expectEqual(k.short[a], t.c.scroll[a][short]);
        }
    }
    // Scrolled to the end, the last row's bottom meets the list's inner bottom edge.
    t.c.scroll[1][list] = 1000;
    clamp(t, s.ext);
    layout.place(t);
    layout.finalize(t);
    try testing.expectEqual(t.rect(list).y1 - 3, t.rect(rows[3]).y1);
}

test "intoView: least movement that shows a row, clamped to the content" {
    var s: Scene = .{};
    s.init();
    const t = &s.t;
    // list 100x50, pad 3, gap 2 { 10 rows of 80x30 }: row k starts at 32k in the content.
    const list = t.push(0, .none, &.{ .size = .{ .px(100), .px(50) }, .pad = @splat(3), .gap = 2, .clip = true });
    var rows: [10]u32 = undefined;
    for (&rows) |*r| r.* = t.push(list, .none, &.{ .size = .{ .px(80), .px(30) } });
    const big = t.push(list, .none, &.{ .size = .{ .px(80), .px(60) } });
    t.seal(list);
    const Case = struct { scroll: f32, row: u32, want: f32 };
    const cases = [_]Case{
        // Visible already: no movement.
        .{ .scroll = 0, .row = rows[0], .want = 0 },
        .{ .scroll = 64, .row = rows[2], .want = 64 },
        // Below: its bottom (32 * 5 + 30 = 190) meets the 44 px inner bottom.
        .{ .scroll = 0, .row = rows[5], .want = 146 },
        // Partly below: 2 * 32 + 30 - 44 = 50.
        .{ .scroll = 40, .row = rows[2], .want = 50 },
        // Above: its top meets the inner top.
        .{ .scroll = 146, .row = rows[1], .want = 32 },
        // Taller than the inner box: its start is shown.
        .{ .scroll = 0, .row = big, .want = 320 },
    };
    for (cases) |k| {
        t.c.scroll[1][list] = k.scroll;
        s.size(.{ 100, 50 });
        extent(t, s.ext);
        layout.place(t);
        const v = intoView(t, s.ext, list, k.row);
        try testing.expectEqual(0, v[0]);
        try testing.expectEqual(k.want, v[1]);
        // Applying it shows the row's top edge inside the list.
        t.c.scroll[1][list] = v[1];
        layout.place(t);
        try testing.expect(t.c.pos[1][k.row] >= 3);
    }
    // The clamp bites when the target lies past the content's end, here moved by an offset
    // that the extent does not count: 320 + 100 asked, 10 * 30 + 60 + 10 gaps + 6 - 50 = 336.
    t.c.scroll[1][list] = 0;
    t.c.offset[1][big] = 100;
    s.size(.{ 100, 50 });
    extent(t, s.ext);
    layout.place(t);
    try testing.expectEqual(336, intoView(t, s.ext, list, big)[1]);
    try testing.expectEqual(274, intoView(t, s.ext, list, rows[9])[1]);
}
