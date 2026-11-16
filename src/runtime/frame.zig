//! Frame: one frame under construction in the runtime front end (tier 1). `Context.begin`
//! returns one; the caller builds the tree through it and ends it. Ported from prototype/ui.zig
//! ("Context and Frame").

const Context = @import("context.zig").Context;
const Input = @import("../core/input.zig").Input;
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const types = @import("../core/types.zig");
const simd = @import("../core/simd.zig");
const Id = types.Id;
const Node = types.Node;
const Style = types.Style;
const TextStyle = types.TextStyle;

/// One frame under construction. Cheap to copy: two pointers.
pub const Frame = struct {
    ctx: *Context,
    in: *const Input,

    pub fn tree(f: *const Frame) *Tree {
        return &f.ctx.trees[f.ctx.cur];
    }
    pub fn texts(f: *const Frame) *Texts {
        return &f.ctx.texts[f.ctx.cur];
    }
    pub fn prevTree(f: *const Frame) *const Tree {
        return &f.ctx.trees[f.ctx.cur ^ 1];
    }

    // ---- building -----------------------------------------------------------

    /// Starts a node. Everything created until the matching `close` is its child.
    pub fn open(f: *Frame, id: Id, style: Style) Node {
        const ctx = f.ctx;
        const i = f.tree().push(ctx.stack[ctx.depth - 1], id, &style);
        // Too deep: the deepest slot is reused, so the stack is never written out of bounds.
        const d = @min(ctx.depth, ctx.limits.depth - 1);
        ctx.status.depth = simd.orB(ctx.status.depth, ctx.depth >= ctx.limits.depth);
        ctx.stack[d] = i;
        ctx.depth = d + 1;
        return @fromBackingInt(i);
    }

    pub fn close(f: *Frame) void {
        const ctx = f.ctx;
        // Never pops the root, even if calls are unbalanced.
        const d = @max(ctx.depth, 2) - 1;
        f.tree().seal(ctx.stack[d]);
        ctx.depth = d;
    }

    /// A node with no children. Same as `open` then `close`.
    pub fn leaf(f: *Frame, id: Id, style: Style) Node {
        const n = f.open(id, style);
        f.close();
        return n;
    }

    /// A text leaf. The bytes are copied, so `str` may be a temporary.
    pub fn text(f: *Frame, str: []const u8, ts: TextStyle) Node {
        return f.textStyled(str, ts, .{ .shrink = ts.wrap, .role = .label });
    }

    /// `text` with full control over the leaf (padding, sizing, background).
    pub fn textStyled(f: *Frame, str: []const u8, ts: TextStyle, style: Style) Node {
        const ctx = f.ctx;
        const n = f.leaf(.none, style);
        const span = ctx.strings[ctx.cur].add(str);
        f.tree().c.text[n.ix()] = f.texts().push(n.ix(), span, &ts);
        return n;
    }

    /// Reserves a rect that the caller draws itself. It comes back in the draw list as
    /// `Cmd.custom`, in paint order, with `data` attached.
    pub fn custom(f: *Frame, id: Id, style: Style, data: u64) Node {
        const ctx = f.ctx;
        const n = f.leaf(id, style);
        f.tree().c.custom[n.ix()] = ctx.customs[ctx.cur].push(n.ix(), id, data);
        return n;
    }
};

const std = @import("std");
const testing = std.testing;
const mem = @import("../core/mem.zig");

/// A context over a static buffer, for tests.
fn Fixture(comptime limits: @import("context.zig").Limits) type {
    return struct {
        var buffer: [Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
        fn context() !Context {
            return Context.init(&buffer, limits);
        }
    };
}

test "open, close, leaf: children nest under the open node, in depth-first rows" {
    const Fx = Fixture(.{ .nodes = 32, .texts = 4, .customs = 2, .strings = 64, .depth = 8 });
    var ctx = try Fx.context();
    const in: Input = .{};
    var f = ctx.begin(&in);
    const a = f.open(.from("a"), .{});
    const a1 = f.leaf(.from("a1"), .{});
    const a2 = f.open(.from("a2"), .{});
    const a21 = f.leaf(.none, .{});
    f.close();
    f.close();
    const b = f.leaf(.from("b"), .{});
    const t = f.tree();
    try testing.expectEqual(@as(u32, 6), t.len);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 1, 1, 3, 0 }, t.c.parent[0..6]);
    try testing.expectEqual(@as(u32, 5), t.c.end[a.ix()]);
    try testing.expectEqual(a1.ix() + 1, t.c.end[a1.ix()]);
    try testing.expectEqual(@as(u32, 5), t.c.end[a2.ix()]);
    try testing.expectEqual(a21.ix() + 1, t.c.end[a21.ix()]);
    try testing.expectEqual(@as(u32, 6), t.c.end[b.ix()]);
    try testing.expectEqual(@as(f32, 2), t.c.nkids[0]);
    try testing.expectEqual(b.ix(), t.find(.from("b")));
    try testing.expectEqual(@as(u32, 1), ctx.depth);
    try testing.expect(ctx.status.ok());
}

test "close: unbalanced calls never pop the root" {
    const Fx = Fixture(.{ .nodes = 8, .texts = 1, .customs = 1, .strings = 16, .depth = 4 });
    var ctx = try Fx.context();
    const in: Input = .{};
    var f = ctx.begin(&in);
    f.close();
    f.close();
    try testing.expectEqual(@as(u32, 1), ctx.depth);
    const n = f.leaf(.none, .{});
    try testing.expectEqual(@as(u32, 0), f.tree().c.parent[n.ix()]);
}

test "open: nesting past the depth limit is reported, not written out of bounds" {
    const Fx = Fixture(.{ .nodes = 32, .texts = 1, .customs = 1, .strings = 16, .depth = 3 });
    var ctx = try Fx.context();
    const in: Input = .{};
    var f = ctx.begin(&in);
    for (0..2) |_| _ = f.open(.none, .{});
    try testing.expect(!ctx.status.depth);
    for (0..5) |_| _ = f.open(.none, .{});
    try testing.expect(ctx.status.depth);
    try testing.expectEqual(@as(u32, 3), ctx.depth);
    for (0..10) |_| f.close();
    try testing.expectEqual(@as(u32, 1), ctx.depth);
    // The next frame starts clean.
    _ = ctx.begin(&in);
    try testing.expect(ctx.status.ok());
}

test "text: copies the bytes and links the leaf to its run" {
    const Fx = Fixture(.{ .nodes = 8, .texts = 4, .customs = 1, .strings = 64, .depth = 4 });
    var ctx = try Fx.context();
    const in: Input = .{};
    var f = ctx.begin(&in);
    var tmp = "hello".*;
    const n = f.text(&tmp, .{ .px = 10, .wrap = true });
    tmp[0] = 'j';
    const t = f.tree();
    const tx = f.texts();
    const k = t.c.text[n.ix()];
    try testing.expectEqual(@as(u32, 0), k);
    try testing.expectEqual(n.ix(), tx.c.node[k]);
    try testing.expectEqualStrings("hello", ctx.strings[ctx.cur].get(.{ .start = tx.c.start[k], .bytes = tx.c.bytes[k] }));
    try testing.expectEqual(@as(f32, 10), tx.c.px[k]);
    // A wrapping label may shrink below its text; it is a label leaf.
    try testing.expectEqual(@as(f32, 1), t.c.shrink[n.ix()]);
    try testing.expectEqual(@backingInt(types.Role.label), t.c.role[n.ix()]);
    try testing.expectEqual(n.ix() + 1, t.c.end[n.ix()]);
    try testing.expectEqual(types.none, t.c.custom[n.ix()]);

    const m = f.textStyled("x", .{}, .{ .pad = @splat(4) });
    try testing.expectEqual(@as(u32, 1), t.c.text[m.ix()]);
    try testing.expectEqual(@as(f32, 4), t.c.pad_lo[0][m.ix()]);
}

test "custom: links the leaf to a row carrying its id and data" {
    const Fx = Fixture(.{ .nodes = 8, .texts = 1, .customs = 2, .strings = 16, .depth = 4 });
    var ctx = try Fx.context();
    const in: Input = .{};
    var f = ctx.begin(&in);
    const n = f.custom(.from("view"), .{ .size = .{ .fill, .fill } }, 42);
    const cu = &ctx.customs[ctx.cur];
    const k = f.tree().c.custom[n.ix()];
    try testing.expectEqual(@as(u32, 0), k);
    try testing.expectEqual(n.ix(), cu.c.node[k]);
    try testing.expectEqual(@backingInt(Id.from("view")), cu.c.id[k]);
    try testing.expectEqual(@as(u64, 42), cu.c.data[k]);
    try testing.expectEqual(n.ix(), f.tree().find(.from("view")));
}
