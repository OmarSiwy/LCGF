//! Texts: the text-run side list. Only nodes that carry text get a row here, and the node links
//! to it through `Tree.Columns.text`, so passes over text loop over runs that exist instead of
//! branching on "has text?" per node (existence-based processing). Tier 0: columns are carved
//! from the caller's buffer. Ported from prototype/ui.zig ("Texts").

const std = @import("std");
const simd = @import("simd.zig");
const mem = @import("mem.zig");
const types = @import("types.zig");
const Span = @import("strings.zig").Span;
const TextStyle = types.TextStyle;
const b01 = simd.b2f;

pub const Texts = struct {
    len: u32 = 0,
    cap: u32,
    c: Columns,

    pub const Columns = struct {
        node: []u32,
        /// Byte range in the frame's `Strings`.
        start: []u32,
        bytes: []u32,
        px: []f32,
        color: []u32,
        font: []u16,
        /// 1.0 when the run may wrap.
        wrap: []f32,
        /// Written by whoever measures text: extent in pixels.
        w: []f32,
        h: []f32,
        /// Written by `layout.textAvail`: the width layout gave this run.
        avail: []f32,
    };

    /// Carves every column from `carver`, `simd.rows(cap)` rows each. With a counting carver
    /// this sizes the buffer instead.
    pub fn init(carver: *mem.Carver, cap: u32) Texts {
        std.debug.assert(cap > 0);
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }
    /// Empties the list for the next frame. Stale rows are rewritten before they are read.
    pub fn reset(tx: *Texts) void {
        tx.len = 0;
    }
    /// Appends a run of `span` for `node` and returns its row. Measured extents and the
    /// available width start at 0 for the measure and layout passes to fill.
    pub fn push(tx: *Texts, node: u32, span: Span, ts: *const TextStyle) u32 {
        std.debug.assert(tx.len < tx.cap);
        const k = tx.len;
        tx.len = k + 1;
        tx.c.node[k] = node;
        tx.c.start[k] = span.start;
        tx.c.bytes[k] = span.bytes;
        tx.c.px[k] = ts.px;
        tx.c.color[k] = ts.color.bitsOf();
        tx.c.font[k] = @backingInt(ts.font);
        tx.c.wrap[k] = b01(ts.wrap);
        tx.c.w[k] = 0;
        tx.c.h[k] = 0;
        tx.c.avail[k] = 0;
        return k;
    }
};

const testing = std.testing;

fn Fixture(comptime cap: u32) type {
    return struct {
        buf: [bytes]u8 align(mem.column_align) = undefined,

        const bytes = blk: {
            var counter: mem.Carver = .{ .buf = null };
            _ = Texts.init(&counter, cap);
            break :blk counter.off;
        };
        fn texts(f: *@This()) Texts {
            var carver: mem.Carver = .{ .buf = &f.buf };
            return Texts.init(&carver, cap);
        }
    };
}

test "push writes one row per run with its node, span and style" {
    var fx: Fixture(4) = .{};
    var tx = fx.texts();
    try testing.expectEqual(simd.rows(4), tx.c.node.len);
    try testing.expectEqual(0, tx.push(3, .{ .start = 0, .bytes = 5 }, &.{}));
    try testing.expectEqual(1, tx.push(7, .{ .start = 5, .bytes = 2 }, &.{ .px = 20, .color = .rgb(1, 2, 3), .font = @fromBackingInt(2), .wrap = true }));
    try testing.expectEqual(2, tx.len);
    const c = tx.c;
    try testing.expectEqualSlices(u32, &.{ 3, 7 }, c.node[0..2]);
    try testing.expectEqualSlices(u32, &.{ 0, 5 }, c.start[0..2]);
    try testing.expectEqualSlices(u32, &.{ 5, 2 }, c.bytes[0..2]);
    try testing.expectEqualSlices(f32, &.{ 14, 20 }, c.px[0..2]);
    try testing.expectEqualSlices(u32, &.{ types.Color.white.bitsOf(), types.Color.rgb(1, 2, 3).bitsOf() }, c.color[0..2]);
    try testing.expectEqualSlices(u16, &.{ 0, 2 }, c.font[0..2]);
    try testing.expectEqualSlices(f32, &.{ 0, 1 }, c.wrap[0..2]);
    c.w[1] = 9;
    c.avail[1] = 9;
    tx.reset();
    try testing.expectEqual(0, tx.len);
    // A reused row starts with no measurement.
    _ = tx.push(0, .{}, &.{});
    _ = tx.push(0, .{}, &.{});
    try testing.expectEqual(0, c.w[1]);
    try testing.expectEqual(0, c.avail[1]);
}
