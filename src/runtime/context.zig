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
const scheduler = @import("scheduler.zig");

/// Capacities. Every one is fixed at `init`; running out is reported, never fatal.
pub const Limits = struct {
    nodes: u32 = 4096,
    texts: u32 = 1024,
    customs: u32 = 64,
    /// Bytes of text per frame.
    strings: u32 = 64 * 1024,
    /// Deepest nesting of open nodes.
    depth: u32 = 64,
    /// Timers armed by `Frame.timer`.
    timers: u32 = 32,
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
    /// How much the springs are still moving; 0 at rest. The anim lane's step writes it
    /// (C0716-C0719); until then nothing moves.
    motion: f32 = 0,
    /// Data behind a signal changed since the last frame. The signals lane's bump sets it
    /// (C0238); `Frame.finish` clears it.
    dirty: bool = false,
    timers: scheduler.Timers,
    /// Set from any thread to ask for a frame; see `scheduler.Wake`.
    waker: scheduler.Wake = .{},

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
            .timers = scheduler.Timers.init(carver, limits.timers),
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

    pub const needsFrame = scheduler.needsFrame;

    /// Starts a frame: swaps generations, empties the new one, steps interaction against last
    /// frame's geometry and opens the root, sized to the viewport.
    pub fn begin(ctx: *Context, in: *const Input) Frame {
        scheduler.settle(ctx, in);
        // Cleared before the app drains its mailboxes, so a result posted after this point
        // wakes the next frame instead of being missed.
        _ = ctx.waker.flag.swap(false, .acq_rel);

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

// ---- the prototype example's host loop ---------------------------------------

/// The prototype's theme and widgets (prototype/ui.zig "widgets"), copied as test helpers: the
/// widget lanes own the real ones. Only the public Frame API is used.
const example = struct {
    const Node = types.Node;
    const Color = types.Color;
    const Response = types.Response;

    const Theme = struct {
        text: Color = Color.rgb(230, 230, 235),
        text_px: f32 = 14,
        panel: Color = Color.rgb(30, 31, 36),
        control: Color = Color.rgb(58, 60, 70),
        control_hot: Color = Color.rgb(74, 77, 90),
        control_held: Color = Color.rgb(44, 46, 54),
        accent: Color = Color.rgb(90, 140, 255),
        radius: f32 = 4,
        pad: f32 = 8,
        gap: f32 = 6,
    };

    fn unit(x: f32) f32 {
        return @min(@max(x, 0), 1);
    }

    fn label(f: *Frame, th: *const Theme, str: []const u8) Node {
        return f.text(str, .{ .px = th.text_px, .color = th.text });
    }

    fn button(f: *Frame, th: *const Theme, id: types.Id, str: []const u8) Response {
        const node = f.open(id, .{ .dir = .x, .pad = @splat(th.pad), .radius = th.radius, .main = .center, .cross = .center, .role = .button });
        const r = f.interact(node, .button);
        const fills = [4]Color{ th.control, th.control_hot, th.control_held, th.control_held };
        f.setFill(node, fills[@as(u8, @intFromBool(r.hovered)) | (@as(u8, @intFromBool(r.held)) << 1)]);
        f.setCursor(.pointer, r.hovered);
        _ = label(f, th, str);
        f.close();
        return r;
    }

    fn checkbox(f: *Frame, th: *const Theme, id: types.Id, value: *bool, str: []const u8) Response {
        const row = f.open(id, .{ .dir = .x, .gap = th.gap, .cross = .center, .role = .checkbox });
        const r = f.interact(row, .button);
        value.* = value.* != r.clicked;
        const marks = [2]Color{ th.control, th.accent };
        _ = f.leaf(.none, .{ .size = .{ .px(16), .px(16) }, .radius = 3, .fill = marks[@intFromBool(value.*)], .border = 1, .border_color = th.control_hot });
        _ = label(f, th, str);
        f.close();
        f.tree().c.value[row.ix()] = simd.b2f(value.*);
        return r;
    }

    fn slider(f: *Frame, th: *const Theme, id: types.Id, value: *f32, lo: f32, hi: f32) Response {
        const track = f.open(id, .{ .dir = .x, .size = .{ .fill, .px(8) }, .min = .{ 40, 0 }, .radius = 4, .fill = th.control, .role = .slider });
        const r = f.interact(track, .{ .hover = true, .click = true, .drag = true, .focus = true });
        const rect = f.heldRect();
        const along = unit((f.in.pointer[0] - rect.x0) / @max(rect.w(), 1));
        value.* = simd.selF(r.held, lo + along * (hi - lo), value.*);
        const frac = unit((value.* - lo) / @max(hi - lo, 1e-6));
        _ = f.leaf(.none, .{ .size = .{ .pct(frac), .fill }, .radius = 4, .fill = th.accent });
        f.close();
        f.tree().c.value[track.ix()] = value.*;
        return r;
    }

    const id_reset = types.Id.from("reset");
    const id_wire = types.Id.from("wireframe");
    const id_exposure = types.Id.from("exposure");
    const id_sidebar = types.Id.from("sidebar");
    const id_add = types.Id.from("add-layer");
    const id_viewport = types.Id.from("viewport");

    const App = struct {
        theme: Theme = .{},
        resets: u32 = 0,
        exposure: f32 = 1,
        wireframe: bool = false,
        layers: u32 = 3,
    };

    /// The prototype's buildUi without its spring (`animate`, anim lane) and its sidebar reuse
    /// (`reuse` over a signal, reuse lane): neither changes this test's frames.
    fn buildUi(f: *Frame, app: *App) void {
        const th = &app.theme;
        _ = f.open(types.Id.from("toolbar"), .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel });
        if (button(f, th, id_reset, "Reset").clicked) {
            app.resets += 1;
            app.exposure = 1;
        }
        _ = checkbox(f, th, id_wire, &app.wireframe, "Wireframe");
        _ = slider(f, th, id_exposure, &app.exposure, 0, 4);
        f.close();

        _ = f.open(types.Id.from("body"), .{ .dir = .x, .size = .{ .fill, .fill } });
        _ = f.open(id_sidebar, .{ .size = .{ .px(160), .fill }, .pad = @splat(8), .gap = 4, .fill = th.panel });
        if (button(f, th, id_add, "Add layer").clicked) app.layers += 1;
        var name: [24]u8 = undefined;
        for (0..app.layers) |i| _ = label(f, th, std.fmt.bufPrint(&name, "Layer {d}", .{i}) catch "?");
        f.close();
        _ = f.custom(id_viewport, .{ .size = .{ .fill, .fill } }, 0);
        f.close();
    }

    fn frame(ctx: *Context, app: *App, in: *const Input) Output {
        var f = ctx.begin(in);
        buildUi(&f, app);
        return f.end(.{});
    }

    const Drawn = struct { batches: u32 = 0, quads: u32 = 0, texts: u32 = 0, customs: u32 = 0, viewport: [4]f32 = @splat(0) };

    /// What a renderer does with the output: one switch per command, in paint order.
    fn render(draw: *const DrawList) Drawn {
        var d: Drawn = .{};
        for (0..draw.cmd_len) |i| switch (draw.command(@intCast(i))) {
            .quads => |batch| {
                d.batches += 1;
                d.quads += batch.count;
            },
            .text => d.texts += 1,
            .custom => |k| {
                d.customs += 1;
                d.viewport = draw.customs[k].rect;
            },
        };
        return d;
    }

    fn center(r: types.Rect) [2]f32 {
        return .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    }
};

test "host loop: layout, draw list, click, drag, idle" {
    const n = comptime Context.requiredBytes(example_limits);
    const S = struct {
        var buffer: [n]u8 align(mem.column_align) = undefined;
    };
    const e = example;
    var ctx = try Context.init(&S.buffer, example_limits);
    var app: e.App = .{};
    var in: Input = .{ .viewport = .{ 800, 600 } };

    try testing.expect(ctx.needsFrame(&in));
    var out = e.frame(&ctx, &app, &in);
    try testing.expect(out.status.ok());

    // Layout: toolbar on top, sidebar left, viewport takes the rest.
    const t = out.tree;
    try testing.expectEqual(types.Rect{ .x0 = 0, .y0 = 50, .x1 = 160, .y1 = 600 }, t.rect(t.find(e.id_sidebar)));
    try testing.expectEqual(types.Rect{ .x0 = 160, .y0 = 50, .x1 = 800, .y1 = 600 }, t.rect(t.find(e.id_viewport)));

    // Draw list: quads between text runs are merged into batches; the custom draw arrives
    // last, in paint order, carrying its rect.
    const d = e.render(out.draw);
    try testing.expectEqual(@as(u32, 1), d.customs);
    try testing.expectEqual([4]f32{ 160, 50, 800, 600 }, d.viewport);
    try testing.expectEqual(@as(u32, 6), d.texts); // Reset, Wireframe, Add layer, Layer 0..2
    try testing.expectEqual(@as(u32, 7), d.quads); // toolbar, 2 buttons, box, track, thumb, sidebar
    try testing.expect(d.batches < d.quads);
    try testing.expectEqual(@as(usize, 7 * @sizeOf(@import("../draw/draw_list.zig").Quad)), out.draw.quadBytes().len);

    // Idle: one settle frame after input, then nothing to do.
    try testing.expectEqual(@as(f32, 0), out.wake);
    out = e.frame(&ctx, &app, &in);
    try testing.expectEqual(types.inf, out.wake);
    try testing.expect(!ctx.needsFrame(&in));

    // Click: press and release over the button, found by last frame's geometry.
    in.pointer = e.center(out.tree.rect(out.tree.find(e.id_reset)));
    out = e.frame(&ctx, &app, &in);
    try testing.expectEqual(Cursor.pointer, out.platform.cursor);
    in.buttons.left = true;
    _ = e.frame(&ctx, &app, &in);
    try testing.expectEqual(@as(u32, 0), app.resets);
    in.buttons.left = false;
    out = e.frame(&ctx, &app, &in);
    try testing.expectEqual(@as(u32, 1), app.resets);

    // Drag: holding the slider at 75% of its track sets the value to 3 of 0..4.
    const track = out.tree.rect(out.tree.find(e.id_exposure));
    in.pointer = .{ track.x0 + 0.75 * track.w(), (track.y0 + track.y1) * 0.5 };
    _ = e.frame(&ctx, &app, &in);
    in.buttons.left = true;
    out = e.frame(&ctx, &app, &in);
    try testing.expectApproxEqAbs(@as(f32, 3), app.exposure, 0.01);
    try testing.expectEqual(@as(f32, 3), out.tree.c.value[out.tree.find(e.id_exposure)]);
    in.buttons.left = false;
    _ = e.frame(&ctx, &app, &in);
}
