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
const Rect = types.Rect;
const Sense = types.Sense;
const Response = types.Response;
const Color = types.Color;
const none = types.none;

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

    // ---- queries: input is asked for, never delivered ----------------------

    /// Makes `node` interactive and reports what happened to it this frame. The node must have
    /// been created with an id; anonymous nodes report nothing.
    pub fn interact(f: *Frame, node: Node, sense: Sense) Response {
        const c = &f.tree().c;
        c.sense[node.ix()] = @bitCast(sense);
        return f.ctx.inter.response(@fromBackingInt(c.id[node.ix()]));
    }

    /// Pointer movement this frame while `id` is held; zero otherwise. (`Interaction.drag` is
    /// the thresholded form, for drags that must not start on a jittery click.)
    pub fn drag(f: *const Frame, id: Id) [2]f32 {
        const s = &f.ctx.inter;
        const k = @backingInt(id);
        const m = simd.b2f(simd.andB(k != 0, s.active == k));
        return .{ s.delta[0] * m, s.delta[1] * m };
    }

    /// Where `id` was laid out last frame. A zero rect if it did not exist. Scans the id
    /// column (SIMD, O(n)); prefer `heldRect` inside widgets.
    pub fn lastRect(f: *const Frame, id: Id) Rect {
        const prev = f.prevTree();
        return rowRect(prev, simd.find(prev.c.id, prev.len, @backingInt(id)));
    }

    /// Last frame's rect of the widget the pointer is holding. O(1): the interaction step
    /// already knows its row. A zero rect if nothing is held.
    pub fn heldRect(f: *const Frame) Rect {
        return rowRect(f.prevTree(), f.ctx.inter.active_node);
    }

    pub fn setFill(f: *Frame, node: Node, color: Color) void {
        f.tree().c.look[node.ix()].fill = color.bitsOf();
    }
};

/// Rect of row `i` of `t`, or a zero rect for `none`. The read is clamped into bounds and the
/// result scaled by 0 or 1, so there is no branch.
fn rowRect(t: *const Tree, i: u32) Rect {
    const row = @min(i, t.cap - 1);
    const m = simd.b2f(i != none);
    return .{
        .x0 = t.c.rect[0][row] * m,
        .y0 = t.c.rect[1][row] * m,
        .x1 = t.c.rect[2][row] * m,
        .y1 = t.c.rect[3][row] * m,
    };
}

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

/// Two 40 x 40 buttons, "a" at x 0..40 and "b" at 50..90, laid out by hand (Frame.end comes later).
fn twoButtons(f: *Frame) [2]Response {
    const layout = @import("../layout/layout.zig");
    _ = f.open(.none, .{ .dir = .x, .gap = 10 });
    const a = f.leaf(.from("a"), .{ .size = .{ .px(40), .px(40) } });
    const ra = f.interact(a, .button);
    const b = f.leaf(.from("b"), .{ .size = .{ .px(40), .px(40) } });
    const rb = f.interact(b, .any);
    f.setFill(b, .rgb(1, 2, 3));
    f.close();
    f.tree().seal(0);
    layout.run(f.tree(), f.texts(), f.in.viewport);
    return .{ ra, rb };
}

test "interact, drag, lastRect, heldRect: answers from last frame's geometry" {
    const Fx = Fixture(.{ .nodes = 16, .texts = 1, .customs = 1, .strings = 16, .depth = 4 });
    var ctx = try Fx.context();
    var in: Input = .{ .viewport = .{ 200, 100 } };
    var f = ctx.begin(&in);
    var r = twoButtons(&f);
    try testing.expect(!r[0].hovered and !r[1].hovered);
    try testing.expectEqual(Color.rgb(1, 2, 3).bitsOf(), f.tree().c.look[f.tree().find(.from("b"))].fill);
    try testing.expectEqual(@as(u8, @bitCast(Sense.button)), f.tree().c.sense[f.tree().find(.from("a"))]);
    // Nothing existed before frame 1, and nothing is held.
    try testing.expectEqual(Rect{}, f.lastRect(.from("a")));
    try testing.expectEqual(Rect{}, f.heldRect());

    in.pointer = .{ 60, 20 };
    f = ctx.begin(&in);
    r = twoButtons(&f);
    try testing.expect(!r[0].hovered and r[1].hovered);
    try testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 40, .y1 = 40 }, f.lastRect(.from("a")));
    try testing.expectEqual(Rect{}, f.lastRect(.from("missing")));

    in.buttons.left = true;
    f = ctx.begin(&in);
    r = twoButtons(&f);
    try testing.expect(r[1].pressed and r[1].held);
    try testing.expectEqual(Rect{ .x0 = 50, .y0 = 0, .x1 = 90, .y1 = 40 }, f.heldRect());
    try testing.expectEqual([2]f32{ 0, 0 }, f.drag(.from("b")));

    // Held and moved: the movement this frame, for the held widget only.
    in.pointer = .{ 70, 25 };
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectEqual([2]f32{ 10, 5 }, f.drag(.from("b")));
    try testing.expectEqual([2]f32{ 0, 0 }, f.drag(.from("a")));
    try testing.expectEqual([2]f32{ 0, 0 }, f.drag(.none));

    in.buttons.left = false;
    f = ctx.begin(&in);
    r = twoButtons(&f);
    try testing.expect(r[1].released and r[1].clicked);
    try testing.expectEqual(Rect{}, f.heldRect());
}
