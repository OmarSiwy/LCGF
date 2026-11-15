//! Context: the runtime front end's state that outlives a frame (tier 1). It owns two
//! generations of the tier-0 columns, all carved from one caller-owned buffer, and hands out a
//! `Frame` per frame. Ported from prototype/ui.zig ("Context and Frame").

const std = @import("std");
const mem = @import("../core/mem.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;
const Strings = @import("../core/strings.zig").Strings;
const DrawList = @import("../draw/draw_list.zig").DrawList;

/// Capacities. Every one is fixed at `init`; running out is reported, never fatal.
pub const Limits = struct {
    nodes: u32 = 4096,
    texts: u32 = 1024,
    customs: u32 = 64,
    /// Bytes of text per frame.
    strings: u32 = 64 * 1024,
    /// Deepest nesting of open nodes.
    depth: u32 = 64,
};

/// Everything that outlives a frame. Holds no pointers the caller did not hand it: all storage
/// is carved from the buffer passed to `init`.
pub const Context = struct {
    limits: Limits,
    // Two generations. `cur` is being built; the other is last frame's result, which hit
    // testing reads.
    trees: [2]Tree,
    texts: [2]Texts,
    customs: [2]Customs,
    strings: [2]Strings,
    cur: u1 = 0,
    draw: DrawList,
    /// Rows of the currently open nodes.
    stack: []u32,
    depth: u32 = 0,

    /// Carves every column in a fixed order. With a counting carver it only sizes them, so
    /// `requiredBytes` and `init` run the same code and cannot disagree.
    fn build(carver: *mem.Carver, limits: Limits) Context {
        return .{
            .limits = limits,
            .trees = .{ Tree.init(carver, limits.nodes), Tree.init(carver, limits.nodes) },
            .texts = .{ Texts.init(carver, limits.texts), Texts.init(carver, limits.texts) },
            .customs = .{ Customs.init(carver, limits.customs), Customs.init(carver, limits.customs) },
            .strings = .{ .{ .buf = carver.slice(u8, limits.strings) }, .{ .buf = carver.slice(u8, limits.strings) } },
            .draw = DrawList.init(carver, limits.nodes, limits.texts, limits.customs),
            .stack = carver.slice(u32, limits.depth),
        };
    }

    /// Bytes `init` needs. Callable at comptime, so a static buffer can be declared as
    /// `[Context.requiredBytes(limits)]u8`.
    pub fn requiredBytes(limits: Limits) usize {
        @setEvalBranchQuota(20_000);
        var counter: mem.Carver = .{ .buf = null };
        _ = build(&counter, limits);
        return counter.off;
    }

    /// The buffer is the only memory the library will ever use.
    pub fn init(buffer: []align(mem.column_align) u8, limits: Limits) error{BufferTooSmall}!Context {
        if (buffer.len < requiredBytes(limits)) return error.BufferTooSmall;
        var carver: mem.Carver = .{ .buf = buffer };
        return build(&carver, limits);
    }
};

const testing = std.testing;

/// The limits the prototype's example uses.
const example_limits: Limits = .{ .nodes = 1024, .texts = 256 };

test "requiredBytes: callable at comptime to size a static buffer" {
    const n = comptime Context.requiredBytes(example_limits);
    const buf: [n]u8 align(mem.column_align) = undefined;
    try testing.expectEqual(n, buf.len);
    // Whole cache lines, as every column is.
    try testing.expectEqual(0, n % mem.column_align);
}

test "requiredBytes: the sum of every column, so it grows with each limit" {
    const base = comptime Context.requiredBytes(example_limits);
    var more = example_limits;
    more.nodes += 64;
    try testing.expect(Context.requiredBytes(more) > base);
    more = example_limits;
    more.strings += 64;
    // Two generations of strings: 64 more bytes each, one cache line each.
    try testing.expectEqual(base + 2 * 64, Context.requiredBytes(more));
    more = example_limits;
    more.depth += 16;
    try testing.expectEqual(base + 64, Context.requiredBytes(more));
}

test "init: carves every table from the caller's buffer, or refuses a short one" {
    const n = comptime Context.requiredBytes(example_limits);
    const S = struct {
        var buffer: [n]u8 align(mem.column_align) = undefined;
    };
    const ctx = try Context.init(&S.buffer, example_limits);
    const lo = @intFromPtr(&S.buffer);
    const hi = lo + n;
    // Both generations, sized by the limits, inside the buffer.
    for (ctx.trees) |t| {
        try testing.expectEqual(example_limits.nodes, t.cap);
        try testing.expect(@intFromPtr(t.c.id.ptr) >= lo and @intFromPtr(t.c.id.ptr) < hi);
    }
    for (ctx.texts) |tx| try testing.expectEqual(example_limits.texts, tx.cap);
    for (ctx.customs) |cu| try testing.expectEqual(example_limits.customs, cu.cap);
    for (ctx.strings) |s| try testing.expectEqual(example_limits.strings, s.buf.len);
    try testing.expectEqual(example_limits.depth, ctx.stack.len);
    // The last column carved ends inside the buffer.
    try testing.expect(@intFromPtr(ctx.stack.ptr + ctx.stack.len) <= hi);

    try testing.expectError(error.BufferTooSmall, Context.init(S.buffer[0 .. n - mem.column_align], example_limits));
}
