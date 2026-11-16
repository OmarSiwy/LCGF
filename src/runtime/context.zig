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
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Input = @import("../core/input.zig").Input;
const Interaction = @import("../interact/interaction.zig").Interaction;
const Frame = @import("frame.zig").Frame;

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

/// Capacity problems this frame. Nothing is written out of bounds when a limit is hit; the frame
/// is simply incomplete and says so here.
pub const Status = bitpack struct(u8) {
    nodes: bool = false,
    texts: bool = false,
    customs: bool = false,
    strings: bool = false,
    depth: bool = false,
    _: u3 = 0,

    pub fn ok(s: Status) bool {
        return @as(u8, @bitCast(s)) == 0;
    }
};

pub const Cursor = enum(u8) { arrow, pointer, text, grab, resize_h, resize_v };

/// Effects the host should apply, returned as data instead of called back.
pub const Platform = struct {
    cursor: Cursor = .arrow,
    /// Show the on-screen keyboard / enable IME, anchored at `ime_rect`.
    wants_text: bool = false,
    ime_rect: types.Rect = .{},
    /// Non-empty when the UI asks to set the clipboard. Valid until the next `begin`.
    clipboard: []const u8 = "",
};

/// What a frame produced. Every field is data the host reads; nothing calls back.
pub const Output = struct {
    draw: *const DrawList,
    /// Final geometry and semantics (`role`, `value`) for accessibility bridges and tests.
    tree: *const Tree,
    texts: *const Texts,
    platform: Platform,
    status: Status,
    /// Seconds until another frame is needed without new input: 0 = now, inf = sleep until
    /// the next event.
    wake: f32,
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
    inter: Interaction = .{},
    platform: Platform = .{},
    status: Status = .{},
    frame: u32 = 0,
    /// Frames still owed after the last input change.
    settle: u32 = 0,
    last_stamp: u64 = 0,

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

    /// Starts a frame: swaps generations, empties the new one, steps interaction against last
    /// frame's geometry and opens the root, sized to the viewport.
    pub fn begin(ctx: *Context, in: *const Input) Frame {
        // One extra frame after any input change, so state that this frame's events modify is
        // visible without waiting for the next event.
        const stamp = in.stamp();
        ctx.settle = simd.selU(stamp != ctx.last_stamp, 1, ctx.settle -| 1);
        ctx.last_stamp = stamp;

        ctx.cur ^= 1;
        const t = &ctx.trees[ctx.cur];
        t.reset();
        ctx.texts[ctx.cur].reset();
        ctx.customs[ctx.cur].reset();
        ctx.strings[ctx.cur].reset();
        ctx.platform = .{};
        ctx.status = .{};
        ctx.frame +%= 1;

        ctx.inter.step(&ctx.trees[ctx.cur ^ 1], in);
        // ponytail: springs are stepped here once the anim lane's table exists (C0716-C0719).

        const root = t.push(0, root_id, &.{ .size = .{ .px(in.viewport[0]), .px(in.viewport[1]) }, .clip = true, .role = .group });
        ctx.stack[0] = root;
        ctx.depth = 1;
        return .{ .ctx = ctx, .in = in };
    }
};

pub const root_id = types.Id.from("ui.root");

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

test "begin: swaps generations, empties the new one and opens the root at the viewport" {
    const n = comptime Context.requiredBytes(example_limits);
    const S = struct {
        var buffer: [n]u8 align(mem.column_align) = undefined;
    };
    var ctx = try Context.init(&S.buffer, example_limits);
    const in: Input = .{ .viewport = .{ 320, 200 } };

    var f = ctx.begin(&in);
    try testing.expectEqual(@as(u1, 1), ctx.cur);
    try testing.expectEqual(@as(u32, 1), ctx.frame);
    try testing.expectEqual(&ctx.trees[1], f.tree());
    try testing.expectEqual(&ctx.trees[0], f.prevTree());
    try testing.expectEqual(@as(u32, 1), f.tree().len);
    try testing.expectEqual(root_id, @as(types.Id, @fromBackingInt(@intCast(f.tree().c.id[0]))));
    try testing.expectEqual(@as(f32, 320), f.tree().c.min[0][0]);
    try testing.expectEqual(@as(f32, 200), f.tree().c.max[1][0]);
    try testing.expectEqual(@as(u32, 1), ctx.depth);
    // First input differs from the zero stamp: one settle frame is owed.
    try testing.expectEqual(@as(u32, 1), ctx.settle);

    // Leftovers in the new generation are dropped by the next begin.
    _ = f.tree().push(0, .none, &.{});
    _ = f.texts();
    f = ctx.begin(&in);
    try testing.expectEqual(@as(u1, 0), ctx.cur);
    try testing.expectEqual(@as(u32, 2), f.prevTree().len);
    try testing.expectEqual(@as(u32, 1), f.tree().len);
    // Same input: the settle frame is used up.
    try testing.expectEqual(@as(u32, 0), ctx.settle);
}

test "begin: interaction steps against last frame's tree" {
    const n = comptime Context.requiredBytes(example_limits);
    const S = struct {
        var buffer: [n]u8 align(mem.column_align) = undefined;
    };
    var ctx = try Context.init(&S.buffer, example_limits);
    var in: Input = .{ .viewport = .{ 320, 200 }, .pointer = .{ 10, 10 } };
    // Frame 1 has no previous geometry: nothing is under the pointer.
    _ = ctx.begin(&in);
    try testing.expectEqual(@as(u32, 0), ctx.inter.hot);
    // Lay frame 1's root out by hand and make it hoverable; frame 2 finds it.
    const t = &ctx.trees[ctx.cur];
    t.seal(0);
    t.c.sense[0] = @bitCast(types.Sense.any);
    t.c.vis[0][0] = 0;
    t.c.vis[1][0] = 0;
    t.c.vis[2][0] = 320;
    t.c.vis[3][0] = 200;
    t.c.visible[0] = 1;
    in.pointer = .{ 20, 20 };
    _ = ctx.begin(&in);
    try testing.expectEqual(@backingInt(root_id), ctx.inter.hot);
}
