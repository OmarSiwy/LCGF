//! Checks shared by the widget tests: that rows take no input, and what assistive technology
//! reads of a row. Test support for src/widgets/; it uses `std.testing`.

const std = @import("std");
const testing = std.testing;
const types = @import("../core/types.zig");
const mem = @import("../core/mem.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const hit = @import("../interact/hit.zig");
const focus = @import("../interact/focus.zig");
const a11y = @import("../a11y/tree.zig");

/// Checks that rows `inert` take no input in laid-out tree `t`: they sense nothing, a hit test
/// at each one's centre finds something else (or nothing), and walking the tab order from
/// nothing (`focus.seek`, what Tab does) never stops on one.
pub fn expectInert(t: *const Tree, inert: []const u32) !void {
    const any: u8 = @bitCast(types.Sense.any);
    const focusable: u8 = @bitCast(types.Sense{ .focus = true });
    for (inert) |r| {
        try testing.expectEqual(@as(u8, 0), t.c.sense[r] & any);
        const b = t.rect(r);
        const at = hit.at(t, (b.x0 + b.x1) * 0.5, (b.y0 + b.y1) * 0.5, .any);
        try testing.expect(at != r);
    }
    var cur: u32 = types.none;
    for (0..t.len) |_| {
        cur = focus.seek(t, t.c.sense, focusable, 0, t.len, cur, false);
        if (cur == types.none) break;
        try testing.expect(std.mem.indexOfScalar(u32, inert, cur) == null);
    }
}

/// Semantic columns for a test tree of up to 32 rows.
pub const SemBuf = struct {
    buf: [bytes]u8 align(mem.column_align) = undefined,
    const bytes = blk: {
        var counter: mem.Carver = .{ .buf = null };
        _ = a11y.Semantics.init(&counter, 32);
        break :blk counter.off;
    };
    pub fn init(b: *SemBuf) a11y.Semantics {
        var carver: mem.Carver = .{ .buf = &b.buf };
        var sem = a11y.Semantics.init(&carver, 32);
        sem.clear();
        return sem;
    }
};

/// The accessible name of row `row` as the bridge reads it: the bytes of its name run.
pub fn nameOf(sem: *const a11y.Semantics, tx: *const Texts, strings: []const u8, row: u32) []const u8 {
    const run = sem.c.name[row];
    if (run == types.none) return "";
    return strings[tx.c.start[run]..][0..tx.c.bytes[run]];
}
