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
const Output = @import("context.zig").Output;
const Cursor = @import("context.zig").Cursor;
const Mono = @import("../text/protocol.zig").Mono;
const Spring = @import("../anim/anims.zig").Spring;
const Ease = @import("../anim/tweens.zig").Ease;
const Transition = @import("../anim/tweens.zig").Transition;
const keyframes = @import("../anim/keyframes.zig");
const flip = @import("../anim/flip.zig");
const layout = @import("../layout/layout.zig");
const paint = @import("../draw/paint.zig");
const scheduler = @import("scheduler.zig");

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

    /// Pointer movement this frame while `id` is dragged; zero otherwise. A drag starts once the
    /// pointer has moved `Interaction.drag_threshold` (4 px) from the press, and that frame
    /// carries the whole movement so far, so a jittery click never drags (`Interaction.drag`).
    pub fn drag(f: *const Frame, id: Id) [2]f32 {
        return f.ctx.inter.drag(id);
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

    /// Requests `cursor` if `when` holds. The last request in a frame wins.
    pub fn setCursor(f: *Frame, cursor: Cursor, when: bool) void {
        const p = &f.ctx.platform;
        p.cursor = @fromBackingInt(@as(u8, @truncate(simd.selU(when, @backingInt(cursor), @backingInt(p.cursor)))));
    }

    pub const timer = scheduler.timer;
    pub const reuse = @import("reuse.zig").reuse;

    /// A value that eases toward `target` across frames on a spring keyed by `id`. Returns this
    /// frame's position (`target` on first use). Keeps the host awake (`Output.wake` 0,
    /// `needsFrame` true) until it lands; a spring not asked for in a frame is dropped.
    pub fn animate(f: *Frame, id: Id, target: f32, spring: Spring) f32 {
        const ctx = f.ctx;
        const a = &ctx.anims;
        const i = a.slot(id, target);
        a.c.target[i] = target;
        a.c.stiffness[i] = spring.stiffness;
        a.c.damping[i] = spring.damping;
        a.c.seen[i] = ctx.frame;
        a.c.node[i] = ctx.stack[ctx.depth - 1];
        if (ctx.settings.reduced_motion) a.land(i);
        // A new target moves the spring from next frame's step on; wake for it now.
        ctx.motion = @max(ctx.motion, @abs(target - a.c.x[i]));
        return a.c.x[i];
    }

    /// Slides `node` (and its subtree) on a spring whenever its laid-out position changes,
    /// starting from where it was shown last frame. The node needs a stable, non-`none` id.
    /// Position only: a size change still takes effect at once. `end` runs the slide
    /// (`flip.apply` between `layout.place` and `layout.finalize`); callers running layout
    /// themselves call it there too.
    pub fn animateLayout(f: *Frame, node: Node, spring: Spring) void {
        f.ctx.flips.add(node.ix(), @fromBackingInt(f.tree().c.id[node.ix()]), spring);
    }

    /// Plays `keys` once, from the first frame that asks for `id`, and returns its value now.
    /// The clock is a linear tween row keyed by `id`, so the host stays awake until the last
    /// key; stop asking for one frame and the next ask plays it again from the start.
    pub fn sequence(f: *Frame, id: Id, keys: []const keyframes.Key) f32 {
        const ctx = f.ctx;
        const t = &ctx.tweens;
        const total = keyframes.duration(keys);
        // A new row rests at 0, so the first retarget starts the clock's only leg.
        const i = t.slot(id, 0);
        t.retarget(i, total, total, .linear);
        t.c.seen[i] = ctx.frame;
        t.c.node[i] = ctx.stack[ctx.depth - 1];
        if (ctx.settings.reduced_motion) t.land(i);
        ctx.motion = @max(ctx.motion, t.c.duration[i] - t.c.elapsed[i]);
        return keyframes.sample(keys, t.c.elapsed[i]);
    }

    /// A colour that moves to `target` along `tr` whenever `target` changes, instead of
    /// jumping: one tween per channel, keyed by `id.with(0..3)`. Returns this frame's colour.
    pub fn transition(f: *Frame, id: Id, target: Color, tr: Transition) Color {
        const want = [4]u8{ target.r, target.g, target.b, target.a };
        var got: [4]u8 = undefined;
        for (want, &got, 0..) |w, *g, k| {
            const v = f.tween(id.with(@intCast(k)), @floatFromInt(w), tr.seconds, tr.ease);
            g.* = @intFromFloat(@min(@max(@round(v), 0), 255));
        }
        return .rgba(got[0], got[1], got[2], got[3]);
    }

    /// `setFill` with a transition: a fill that changes between frames (hover, press, theme)
    /// fades to the new colour along `tr`. `id` keys the transition; use the widget's id.
    pub fn setFillAnimated(f: *Frame, node: Node, id: Id, color: Color, tr: Transition) void {
        f.setFill(node, f.transition(id, color, tr));
    }

    /// A value that moves to `target` over `seconds` along `ease`, keyed by `id`: when the
    /// target changes, a new leg starts from the current value. Returns this frame's value
    /// (`target` on first use). Keeps the host awake until it lands; a tween not asked for in
    /// a frame is dropped.
    pub fn tween(f: *Frame, id: Id, target: f32, seconds: f32, ease: Ease) f32 {
        const ctx = f.ctx;
        const t = &ctx.tweens;
        const i = t.slot(id, target);
        t.retarget(i, target, seconds, ease);
        t.c.seen[i] = ctx.frame;
        t.c.node[i] = ctx.stack[ctx.depth - 1];
        if (ctx.settings.reduced_motion) t.land(i);
        ctx.motion = @max(ctx.motion, t.c.duration[i] - t.c.elapsed[i]);
        return t.c.x[i];
    }

    // ---- finishing ------------------------------------------------------------

    /// Diagonal: measure with `font`, lay out, paint. Each line below is a public tier-0 call;
    /// copy this body to put your own shaper, or your own pass, between any two of them.
    pub fn end(f: *Frame, font: Mono) Output {
        const t = f.tree();
        const tx = f.texts();
        t.seal(0);
        font.measure(tx);
        layout.prepare(t);
        layout.applyText(t, tx, .x);
        layout.fit(t, .x);
        layout.resolve(t, .x, f.in.viewport[0]);
        layout.textAvail(t, tx);
        font.wrap(tx);
        layout.applyText(t, tx, .y);
        layout.fit(t, .y);
        layout.resolve(t, .y, f.in.viewport[1]);
        layout.place(t);
        // Reduced motion: no slide, the layout as it is (the springs go unseen and are dropped).
        if (!f.ctx.settings.reduced_motion) f.ctx.motion = @max(f.ctx.motion, flip.apply(t, f.prevTree(), &f.ctx.flips, &f.ctx.anims, f.ctx.frame));
        layout.finalize(t);
        return f.finish();
    }

    /// Paint and bookkeeping only, for callers who ran layout themselves.
    pub fn finish(f: *Frame) Output {
        const ctx = f.ctx;
        const t = f.tree();
        const tx = f.texts();
        const strings = &ctx.strings[ctx.cur];
        t.seal(0);
        const cu = &ctx.customs[ctx.cur];
        paint.emit(t, tx, cu, strings.buf[0..strings.len], &ctx.draw);
        ctx.anims.sweep(ctx.frame);
        ctx.tweens.sweep(ctx.frame);
        ctx.signals.dirty = false;
        // The tables flag their own overflow; the frame reports them together.
        ctx.status = .{
            .nodes = t.overflow,
            .texts = tx.overflow,
            .customs = cu.overflow,
            .strings = strings.overflow,
            .depth = ctx.status.depth,
        };
        ctx.timers.sweep(ctx.frame);
        return .{
            .draw = &ctx.draw,
            .tree = t,
            .texts = tx,
            .platform = ctx.platform,
            .status = ctx.status,
            .wake = scheduler.wake(ctx, f.in),
            .pace = scheduler.pace(ctx),
        };
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

    // Held and moved 2 px: under the threshold, not a drag yet.
    in.pointer = .{ 62, 21 };
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectEqual([2]f32{ 0, 0 }, f.drag(.from("b")));

    // Held and moved 11 px from the press, past the 4 px threshold: the drag starts with the
    // movement so far, for the held widget only.
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

test "end: the tier-0 pass sequence, then paint; equal to running layout and finish by hand" {
    const Fx = Fixture(.{ .nodes = 16, .texts = 4, .customs = 2, .strings = 64, .depth = 4 });
    var ctx = try Fx.context();
    const in: Input = .{ .viewport = .{ 400, 300 } };

    var f = ctx.begin(&in);
    _ = f.open(.from("bar"), .{ .dir = .x, .size = .{ .fill, .px(40) }, .pad = @splat(10), .gap = 4, .fill = .rgb(9, 9, 9) });
    // 24 bytes at 10 px, 0.5 em each: 120 px wrapping into 100: two lines of 12 px.
    _ = f.open(.none, .{ .size = .{ .px(100), .fit } });
    const para = f.text("twenty-four characters!!", .{ .px = 10, .wrap = true });
    f.close();
    f.close();
    const view = f.custom(.from("view"), .{ .size = .{ .fill, .fill } }, 7);
    // Unbalanced on purpose: end seals the root anyway.
    _ = f.open(.none, .{});
    const out = f.end(.{ .advance = 0.5, .line = 1.2 });

    const t = out.tree;
    try testing.expectEqual(f.tree(), t);
    try testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 400, .y1 = 40 }, t.rect(t.find(.from("bar"))));
    try testing.expectEqual(Rect{ .x0 = 10, .y0 = 10, .x1 = 110, .y1 = 34 }, t.rect(para.ix()));
    try testing.expectEqual(Rect{ .x0 = 0, .y0 = 40, .x1 = 400, .y1 = 300 }, t.rect(view.ix()));
    try testing.expectEqual(t.len, t.c.end[0]);
    // Paint: the bar's quad, the run, the custom draw with its rect, in that order.
    const d = out.draw;
    try testing.expectEqual(@as(u32, 1), d.quad_len);
    try testing.expectEqual(@as(u32, 1), d.run_len);
    try testing.expectEqual(@as(u32, 1), d.custom_len);
    try testing.expectEqual([4]f32{ 0, 40, 400, 300 }, d.customs[0].rect);
    try testing.expectEqual(@as(u32, 3), d.cmd_len);
    // The first frame after an input change owes one more.
    try testing.expectEqual(@as(f32, 0), out.wake);

    // Same input again: rebuilt by hand with the passes run by the caller, then finish.
    f = ctx.begin(&in);
    _ = f.open(.from("bar"), .{ .dir = .x, .size = .{ .fill, .px(40) }, .pad = @splat(10), .gap = 4, .fill = .rgb(9, 9, 9) });
    _ = f.open(.none, .{ .size = .{ .px(100), .fit } });
    _ = f.text("twenty-four characters!!", .{ .px = 10, .wrap = true });
    f.close();
    f.close();
    _ = f.custom(.from("view"), .{ .size = .{ .fill, .fill } }, 7);
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    font.measure(f.texts());
    f.tree().seal(0);
    layout.prepare(f.tree());
    layout.applyText(f.tree(), f.texts(), .x);
    layout.fit(f.tree(), .x);
    layout.resolve(f.tree(), .x, 400);
    layout.textAvail(f.tree(), f.texts());
    font.wrap(f.texts());
    layout.applyText(f.tree(), f.texts(), .y);
    layout.fit(f.tree(), .y);
    layout.resolve(f.tree(), .y, 300);
    layout.place(f.tree());
    layout.finalize(f.tree());
    const again = f.finish();
    try testing.expectEqual(Rect{ .x0 = 10, .y0 = 10, .x1 = 110, .y1 = 34 }, again.tree.rect(para.ix()));
    try testing.expectEqual(@as(u32, 3), again.draw.cmd_len);
    // Nothing changed and nothing moves: sleep until the next event.
    try testing.expectEqual(types.inf, again.wake);
}

test "running out of rows is reported, not fatal" {
    const tiny: @import("context.zig").Limits = .{ .nodes = 8, .texts = 2, .customs = 1, .strings = 16, .depth = 3 };
    const Fx = Fixture(tiny);
    var ctx = try Fx.context();
    try testing.expectError(error.BufferTooSmall, Context.init(Fx.buffer[0..64], tiny));

    const in: Input = .{};
    var f = ctx.begin(&in);
    for (0..40) |i| {
        _ = f.open(Id.from("n").with(@intCast(i)), .{ .pad = @splat(1) });
        _ = f.text("a long label that will not fit", .{});
    }
    for (0..40) |_| f.close();
    _ = f.custom(.from("c1"), .{}, 0);
    _ = f.custom(.from("c2"), .{}, 0);
    const out = f.end(.{});
    try testing.expect(out.status.nodes and out.status.texts and out.status.customs and out.status.strings and out.status.depth);
    try testing.expect(!out.status.ok());
    try testing.expect(out.tree.len <= tiny.nodes);

    // A frame that fits is clean again.
    f = ctx.begin(&in);
    _ = f.text("ok", .{});
    try testing.expect(f.end(.{}).status.ok());
}

test "finish: a signal changed before the frame is consumed by it" {
    const Fx = Fixture(.{ .nodes = 8, .texts = 1, .customs = 1, .strings = 16, .signals = 2, .depth = 4 });
    var ctx = try Fx.context();
    const in: Input = .{};
    const sig = ctx.signals.create();
    ctx.signals.touch(sig);
    var f = ctx.begin(&in);
    try testing.expect(ctx.signals.dirty);
    _ = f.end(.{});
    try testing.expect(!ctx.signals.dirty);
}

test "setCursor: the last request that holds wins; the next frame starts at arrow" {
    const Fx = Fixture(.{ .nodes = 8, .texts = 1, .customs = 1, .strings = 16, .depth = 4 });
    var ctx = try Fx.context();
    const in: Input = .{};
    var f = ctx.begin(&in);
    f.setCursor(.pointer, true);
    f.setCursor(.grab, false);
    try testing.expectEqual(Cursor.pointer, f.end(.{}).platform.cursor);
    f = ctx.begin(&in);
    f.setCursor(.text, true);
    f.setCursor(.resize_h, true);
    try testing.expectEqual(Cursor.resize_h, f.end(.{}).platform.cursor);
    f = ctx.begin(&in);
    try testing.expectEqual(Cursor.arrow, f.end(.{}).platform.cursor);
}

test "wake: long press and hover intent wake the host when they fall due, once" {
    const Fx = Fixture(.{ .nodes = 16, .texts = 1, .customs = 1, .strings = 16, .depth = 4 });
    var ctx = try Fx.context();
    var in: Input = .{ .viewport = .{ 200, 100 } };
    var f = ctx.begin(&in);
    _ = twoButtons(&f);
    _ = f.finish();
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectEqual(types.inf, f.finish().wake);

    // Pointer comes to rest on "a" at t = 1: hover intent is due at 1.5.
    in.pointer = .{ 20, 20 };
    in.time = 1;
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectEqual(@as(f32, 0), f.finish().wake); // settle frame
    in.time = 1.2;
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectApproxEqAbs(@as(f32, 0.3), f.finish().wake, 1e-4);
    in.time = 1.5;
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectEqual(@backingInt(Id.from("a")), ctx.inter.hover_intent);
    try testing.expectEqual(types.inf, f.finish().wake);

    // Press at t = 2: the long press is due at 2.5, then nothing is pending.
    in.buttons.left = true;
    in.time = 2;
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectEqual(@as(f32, 0), f.finish().wake);
    in.time = 2.1;
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectApproxEqAbs(@as(f32, 0.4), f.finish().wake, 1e-4);
    in.time = 2.6;
    f = ctx.begin(&in);
    _ = twoButtons(&f);
    try testing.expectEqual(@backingInt(Id.from("a")), ctx.inter.long_pressed);
    try testing.expectEqual(types.inf, f.finish().wake);
}
