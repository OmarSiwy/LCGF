//! Reuse: signals-driven skipping of unchanged subtrees in the runtime front end (tier 1). A
//! memo remembers where a subtree was built last frame and the stamp of the signals it read;
//! while neither changed, `Frame.reuse` copies its rows from last frame's tree instead of
//! letting the caller build it again. Ported from prototype/ui.zig ("Memos", "Frame.reuse").

const std = @import("std");
const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");
const none = @import("../core/types.zig").none;

/// One row per memoized subtree. See `Frame.reuse`.
pub const Memos = struct {
    len: u32 = 0,
    cap: u32,
    c: Columns,

    pub const Columns = struct {
        id: []u32,
        /// Root row of the subtree in the tree of frame `frame`.
        node: []u32,
        frame: []u32,
        /// `Signals.stamp` of the dependencies the subtree was built from.
        stamp: []u64,
    };

    /// Carves every column from `carver`, `simd.rows(cap)` rows each, so `simd.find` can scan
    /// the id column in whole vectors.
    pub fn init(carver: *mem.Carver, cap: u32) Memos {
        std.debug.assert(cap > 0);
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }
};

const testing = std.testing;

test "Memos.init: padded columns carved from the caller's buffer, empty" {
    var raw: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    const m = Memos.init(&carver, 5);
    try testing.expectEqual(@as(u32, 0), m.len);
    try testing.expectEqual(@as(u32, 5), m.cap);
    inline for (.{ m.c.id, m.c.node, m.c.frame }) |col| try testing.expectEqual(simd.rows(5), col.len);
    try testing.expectEqual(simd.rows(5), m.c.stamp.len);
    try testing.expectEqual(none, simd.find(m.c.id, m.len, 0));

    // A counting carver sizes the same columns.
    var counter: mem.Carver = .{ .buf = null };
    _ = Memos.init(&counter, 5);
    try testing.expectEqual(carver.off, counter.off);
}
