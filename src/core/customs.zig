//! Customs: the custom-draw side list. Only nodes the host draws itself get a row here, linked
//! from `Tree.Columns.custom`; paint hands each row back to the host as a `custom` command with
//! the node's rectangle. No callback crosses the boundary. Tier 0: columns are carved from the
//! caller's buffer. Ported from prototype/ui.zig ("Customs").

const std = @import("std");
const simd = @import("simd.zig");
const mem = @import("mem.zig");
const Id = @import("types.zig").Id;

pub const Customs = struct {
    len: u32 = 0,
    cap: u32,
    c: Columns,

    pub const Columns = struct {
        node: []u32,
        id: []u32,
        /// Opaque to the core; handed back in the draw list.
        data: []u64,
    };

    /// Carves every column from `carver`, `simd.rows(cap)` rows each. With a counting carver
    /// this sizes the buffer instead.
    pub fn init(carver: *mem.Carver, cap: u32) Customs {
        std.debug.assert(cap > 0);
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }
    /// Empties the list for the next frame. Stale rows are rewritten before they are read.
    pub fn reset(cu: *Customs) void {
        cu.len = 0;
    }
    /// Appends a custom draw for `node` and returns its row.
    pub fn push(cu: *Customs, node: u32, id: Id, data: u64) u32 {
        std.debug.assert(cu.len < cu.cap);
        const k = cu.len;
        cu.len = k + 1;
        cu.c.node[k] = node;
        cu.c.id[k] = @backingInt(id);
        cu.c.data[k] = data;
        return k;
    }
};

const testing = std.testing;

fn Fixture(comptime cap: u32) type {
    return struct {
        buf: [bytes]u8 align(mem.column_align) = undefined,

        const bytes = blk: {
            var counter: mem.Carver = .{ .buf = null };
            _ = Customs.init(&counter, cap);
            break :blk counter.off;
        };
        fn customs(f: *@This()) Customs {
            var carver: mem.Carver = .{ .buf = &f.buf };
            return Customs.init(&carver, cap);
        }
    };
}

test "push writes node, id and opaque data; reset empties the list" {
    var fx: Fixture(4) = .{};
    var cu = fx.customs();
    try testing.expectEqual(simd.rows(4), cu.c.data.len);
    try testing.expectEqual(0, cu.push(2, Id.from("plot"), 0xdead_beef_0000_0001));
    try testing.expectEqual(1, cu.push(5, Id.from("map"), std.math.maxInt(u64)));
    try testing.expectEqual(2, cu.len);
    try testing.expectEqualSlices(u32, &.{ 2, 5 }, cu.c.node[0..2]);
    try testing.expectEqualSlices(u32, &.{ @backingInt(Id.from("plot")), @backingInt(Id.from("map")) }, cu.c.id[0..2]);
    try testing.expectEqualSlices(u64, &.{ 0xdead_beef_0000_0001, std.math.maxInt(u64) }, cu.c.data[0..2]);
    cu.reset();
    try testing.expectEqual(0, cu.len);
    try testing.expectEqual(0, cu.push(9, .none, 7));
}
