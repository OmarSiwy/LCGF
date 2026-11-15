//! scroll: what scroll containers need from layout. Tier 0: no allocator, no I/O. Scrolling
//! itself is in the core passes already: `Style.scroll` is subtracted from the children's
//! positions in `place` and `Style.clip` cuts them to the node in `finalize` (prototype/ui.zig).
//! This file adds the numbers around it.
//!
//!   extent     SIMD   content size of every node, from `fit`

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
