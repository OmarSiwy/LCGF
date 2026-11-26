//! Context: the runtime front end's state that outlives a frame (tier 1). It owns two
//! generations of the tier-0 columns, all carved from one caller-owned buffer, and hands out a
//! `Frame` per frame. Ported from prototype/ui.zig ("Context and Frame").

const std = @import("std");
const mem = @import("../core/mem.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;
const Strings = @import("../core/strings.zig").Strings;
const draw_list = @import("../draw/draw_list.zig");
const DrawList = draw_list.DrawList;
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Input = @import("../core/input.zig").Input;
const Interaction = @import("../interact/interaction.zig").Interaction;
const focus = @import("../interact/focus.zig");
const Frame = @import("frame.zig").Frame;
const scheduler = @import("scheduler.zig");
const Signals = @import("signals.zig").Signals;
const Anims = @import("../anim/anims.zig").Anims;
const Tweens = @import("../anim/tweens.zig").Tweens;
const Flips = @import("../anim/flip.zig").Flips;
const Memos = @import("reuse.zig").Memos;
const Levels = @import("../layout/levels.zig").Levels;
const damage = @import("../draw/damage.zig");
const Damage = damage.Damage;
const Settings = @import("../a11y/settings_data.zig").Settings;

/// Capacities. Every one is fixed at `init`; running out is reported, never fatal.
pub const Limits = struct {
    nodes: u32 = 4096,
    texts: u32 = 1024,
    customs: u32 = 64,
    /// Bytes of text per frame.
    strings: u32 = 64 * 1024,
    /// Springs alive at once (`Frame.animate`).
    anims: u32 = 256,
    /// Tweens alive at once (`Frame.tween`).
    tweens: u32 = 128,
    /// Nodes per frame that animate their layout (`Frame.animateLayout`).
    flips: u32 = 64,
    signals: u32 = 256,
    /// Deepest nesting of open nodes.
    depth: u32 = 64,
    /// Timers armed by `Frame.timer`.
    timers: u32 = 32,
    /// Subtrees remembered by `Frame.reuse`.
    memos: u32 = 128,
    /// Room to track what each frame changed (`damage.Damage`, about 50 bytes a node); tracking
    /// starts with `Context.trackDamage`.
    damage: bool = false,
};

/// Capacity problems this frame. Nothing is written out of bounds when a limit is hit; the frame
/// is simply incomplete and says so here.
pub const Status = bitpack struct(u8) {
    nodes: bool = false,
    texts: bool = false,
    customs: bool = false,
    strings: bool = false,
    depth: bool = false,
    anims: bool = false,
    tweens: bool = false,
    flips: bool = false,

    pub fn ok(s: Status) bool {
        return @as(u8, @bitCast(s)) == 0;
    }
};

pub const Cursor = types.Cursor;

/// Effects the host should apply, returned as data instead of called back.
pub const Platform = struct {
    cursor: Cursor = .arrow,
    /// Show the on-screen keyboard / enable IME, anchored at `ime_rect`.
    wants_text: bool = false,
    ime_rect: types.Rect = .{},
    /// What the focused field takes, so the keyboard lays out for it (digits, an email's @)
    /// and a password gets no IME and no suggestions. Read with `wants_text`.
    purpose: Purpose = .normal,
    /// The focused field's text around the caret, and the caret or selection in it as byte
    /// offsets (equal for a caret), so the IME and autocorrect see what is being edited. Empty
    /// when the field does not say. Valid until the next `begin`.
    surrounding: []const u8 = "",
    selection: [2]u32 = .{ 0, 0 },
    /// Non-empty when the UI asks to set the clipboard. Valid until the next `begin`.
    clipboard: []const u8 = "",
    /// The UI asks for the clipboard's text (`keyboard.Clipboard.paste`). The shell types it
    /// into a later frame, a `.text` event and `Input.text`, for the widget focused then.
    paste: bool = false,
};

pub const Purpose = @import("../interact/keyboard.zig").Purpose;

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
    /// Why `wake` is what it is, so the host can choose how to wait for the next frame.
    pace: scheduler.Pace,
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
    signals: Signals,
    anims: Anims,
    tweens: Tweens,
    flips: Flips,
    /// Rows of the currently open nodes.
    stack: []u32,
    depth: u32 = 0,
    inter: Interaction = .{},
    /// Keyboard focus: Tab and Shift+Tab, arrows in focus groups, modal traps, the ring.
    /// `begin` steps it after `inter`, so `inter.focus` is where the keys left it.
    focus: focus.Focus = .{},
    /// Focus groups and traps of the tree `focus` steps through. The derived scope columns
    /// are scratch; the declared kind bytes follow the two tree generations for reuse.
    scopes: focus.Scopes,
    previous_scope_kind: []u8,
    previous_scoped: bool = false,
    /// `Frame.focusScope` was called this frame.
    scoped: bool = false,
    platform: Platform = .{},
    /// Previous-tree owner of active text input. Its subtree must republish borrowed IME
    /// and caret data each frame; it cannot preserve that per-frame output by copying rows.
    text_input_node: u32 = types.none,
    status: Status = .{},
    frame: u32 = 0,
    /// Frames still owed after the last input change.
    settle: u32 = 0,
    last_stamp: u64 = 0,
    /// Every pointer move asks for a frame, also over nodes that sense nothing. Set it while
    /// the UI draws from the raw pointer position outside sensing nodes (a crosshair, the
    /// inspector's outline); otherwise such a move changes no frame and `needsFrame` skips it.
    track_pointer: bool = false,
    /// The platform's accessibility settings; the host sets them, on change or every frame.
    /// Under `reduced_motion` springs, tweens, transitions and sequences show their end state at
    /// once and layout changes do not slide, so nothing keeps the host awake.
    settings: Settings = .{},
    /// How much the springs and tweens are still moving; 0 at rest. `begin` sets it from
    /// `Anims.step` and `Tweens.step`.
    motion: f32 = 0,
    timers: scheduler.Timers,
    /// Set from any thread to ask for a frame; see `scheduler.Wake`.
    waker: scheduler.Wake = .{},
    /// Where each reusable subtree was built and from which signal versions (`Frame.reuse`).
    memos: Memos,
    /// Level-order index of the tree, rebuilt by `Frame.end` when no subtree is kept, so resolve
    /// sweeps level by level (docs/perf/port-perf.md).
    levels: Levels,
    /// What changed since the last frame, with `limits.damage` (no rows without).
    damage: Damage,
    /// Set by `trackDamage`: records each frame and culls its draw list.
    damage_hook: ?*const fn (ctx: *Context, t: *const Tree, tx: *const Texts, cu: *const Customs, strings: []const u8) void = null,
    /// The next frame repaints everything (`redrawAll`, or a new viewport or scale).
    redraw_all: bool = false,
    /// Viewport and scale of the last `begin`.
    last_view: [3]f32 = @splat(0),
    /// Set by `enableCanvas`: turns this frame's canvas nodes' custom commands into `canvas`
    /// commands after paint.
    canvas_hook: ?*const fn (ctx: *Context) void = null,
    /// `frame` when `Frame.canvas` last ran: a frame without a canvas skips the marking.
    canvas_frame: u32 = 0,

    /// Carves every column in a fixed order. With a counting carver it only sizes them, so
    /// `requiredBytes` and `init` run the same code and cannot disagree.
    fn build(carver: *mem.Carver, limits: Limits) Context {
        // The generations are never laid out at once, so they share layout scratch.
        const first = Tree.init(carver, limits.nodes);
        return .{
            .limits = limits,
            .trees = .{ first, Tree.initSharing(carver, limits.nodes, &first) },
            .texts = .{ Texts.init(carver, limits.texts), Texts.init(carver, limits.texts) },
            .customs = .{ Customs.init(carver, limits.customs), Customs.init(carver, limits.customs) },
            .strings = .{ .{ .buf = carver.slice(u8, limits.strings) }, .{ .buf = carver.slice(u8, limits.strings) } },
            .draw = DrawList.init(carver, limits.nodes, limits.texts, limits.customs),
            .signals = Signals.init(carver, limits.signals),
            .anims = Anims.init(carver, limits.anims),
            .tweens = Tweens.init(carver, limits.tweens),
            .flips = Flips.init(carver, limits.flips),
            .stack = carver.slice(u32, limits.depth),
            .timers = scheduler.Timers.init(carver, limits.timers),
            .memos = Memos.init(carver, limits.memos),
            .levels = Levels.init(carver, limits.nodes),
            .scopes = focus.Scopes.init(carver, limits.nodes),
            .previous_scope_kind = carver.slice(u8, simd.rows(limits.nodes)),
            .damage = if (limits.damage) Damage.init(carver, limits.nodes) else Damage.none,
        };
    }

    /// From the next frame on, keeps in the draw list only the quads that reach what changed
    /// since the last frame, with `DrawList.damage` saying where: for a host that keeps last
    /// frame's pixels and redraws only that (`sw.Setup.draw`, the X11 and Wayland shells, the
    /// bare-metal flush). The first frame is whole. Needs `Limits.damage`; a host that draws
    /// every frame whole (a GPU back end clearing its target) must not call it. Its code is
    /// linked only into programs that call it.
    pub fn trackDamage(ctx: *Context) void {
        std.debug.assert(ctx.limits.damage);
        ctx.damage_hook = &recordDamage;
        ctx.redraw_all = true;
    }

    fn recordDamage(ctx: *Context, t: *const Tree, tx: *const Texts, cu: *const Customs, strings: []const u8) void {
        _ = ctx.damage.frame(t, tx, cu, strings);
        damage.cull(&ctx.draw, if (ctx.redraw_all) &damage.Region.everything else &ctx.damage.region);
        ctx.redraw_all = false;
    }

    /// Lets frames make canvas nodes (`Frame.canvas`): `rows` (at least `limits.customs` of
    /// them, the caller's, alive as long as the context) become `DrawList.canvases`, one per
    /// custom row. Like `trackDamage`, a program that never calls it links none of its code.
    pub fn enableCanvas(ctx: *Context, rows: []draw_list.CanvasDraw) void {
        std.debug.assert(rows.len >= ctx.limits.customs);
        // No stamp may be this frame's or a later one's: those rows would read as canvases.
        for (rows) |*r| r.stamp = ctx.frame -% 1;
        ctx.draw.canvases = rows;
        ctx.canvas_hook = &markCanvases;
    }

    /// Custom ops and commands whose row was written by `Frame.canvas` this frame become
    /// canvas ones. The ops too, so a pass that encodes them again (`order.mergeAcrossText`)
    /// keeps them; both index `customs` and `canvases` by the same row.
    fn markCanvases(ctx: *Context) void {
        if (ctx.canvas_frame != ctx.frame) return;
        const d = &ctx.draw;
        const custom = @backingInt(DrawList.Kind.custom);
        const canvas = @backingInt(DrawList.Kind.canvas);
        const last = d.canvases.len - 1;
        for (d.op.kind[0..d.op_len], d.op.ref[0..d.op_len]) |*kind, ref| {
            const is = (kind.* == custom) & (d.canvases[@min(ref, last)].stamp == ctx.frame);
            kind.* = @intCast(simd.selU(is, canvas, kind.*));
        }
        for (d.cmd.kind[0..d.cmd_len], d.cmd.first[0..d.cmd_len]) |*kind, ref| {
            const is = (kind.* == custom) & (d.canvases[@min(ref, last)].stamp == ctx.frame);
            kind.* = @intCast(simd.selU(is, canvas, kind.*));
        }
    }

    /// With `trackDamage`: the next frame's draw list covers the whole window, as for a host
    /// that has lost last frame's pixels (a new buffer).
    pub fn redrawAll(ctx: *Context) void {
        ctx.redraw_all = true;
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

    /// `init` over a buffer that is all zero bytes (a static buffer never used before, fresh
    /// `mmap` memory): it is not cleared, so capacity the frames never reach stays untouched and
    /// costs no resident memory. A reused buffer needs `init`.
    ///
    /// The contract: every byte of `buffer[0..requiredBytes(limits)]` is zero. A static buffer
    /// must be declared `= @splat(0)`, which is bss in every build mode; `= undefined` is 0xAA
    /// in Debug (in .data), and the context would start from garbage. Debug builds check the
    /// first and last page and panic when either is not zero.
    pub fn initZeroed(buffer: []align(mem.column_align) u8, limits: Limits) error{BufferTooSmall}!Context {
        const n = requiredBytes(limits);
        if (buffer.len < n) return error.BufferTooSmall;
        if (@import("builtin").mode == .debug and !looksZeroed(buffer[0..n]))
            @panic("Context.initZeroed: the buffer is not all zero bytes; declare a static buffer `= @splat(0)`, or use `init`");
        var carver: mem.Carver = .{ .buf = buffer, .zeroed = true };
        return build(&carver, limits);
    }

    pub const needsFrame = scheduler.needsFrame;

    /// `initZeroed`'s Debug check: the first and last page of `b` are zero bytes. Two pages, so
    /// the check makes no other page resident.
    fn looksZeroed(b: []const u8) bool {
        const page = @min(4096, b.len);
        return std.mem.allEqual(u8, b[0..page], 0) and std.mem.allEqual(u8, b[b.len - page ..], 0);
    }

    /// Starts a frame: swaps generations, empties the new one, steps interaction against last
    /// frame's geometry and opens the root, sized to the viewport.
    pub fn begin(ctx: *Context, in: *const Input) Frame {
        return ctx.beginWithHit(in, @import("../interact/hit.zig").at(&ctx.trees[ctx.cur], in.pointer[0], in.pointer[1], .any));
    }

    /// Starts the ordinary frame with a caller-computed row in the previous completed tree
    /// (`ctx.trees[ctx.cur]` before this call). Use hit_targets.at, hit.atLayered or a custom
    /// scene query; `types.none` means nothing hit. Invalid/ineligible rows are ignored.
    pub fn beginWithHit(ctx: *Context, in: *const Input, node: u32) Frame {
        // Cleared before the app drains its mailboxes, so a result posted after this point
        // wakes the next frame instead of being missed.
        _ = ctx.waker.flag.swap(false, .acq_rel);

        ctx.cur ^= 1;
        const t = &ctx.trees[ctx.cur];
        t.reset();
        ctx.texts[ctx.cur].reset();
        ctx.customs[ctx.cur].reset();
        ctx.strings[ctx.cur].reset();
        const text_input = ctx.platform.wants_text;
        ctx.platform = .{};
        ctx.status = .{};
        ctx.anims.overflow = false;
        ctx.tweens.overflow = false;
        ctx.flips.overflow = false;
        ctx.frame +%= 1;
        ctx.memos.kept_len = 0;

        const prev = &ctx.trees[ctx.cur ^ 1];
        ctx.inter.stepWithHit(prev, in, node);
        // Keyboard focus. Its sweeps (the scope scan, `step`'s searches of the id column) run
        // only on frames with key events, after a frame that set a scope, or while a modal
        // layer is open; otherwise nothing they compute is read, and the frame does only the
        // bookkeeping `step` would.
        const sc = &ctx.scopes;
        const scoped = ctx.scoped;
        ctx.scoped = false;
        const keys = in.events.len != 0;
        const fo = &ctx.focus;
        if (simd.orB(simd.orB(keys, scoped), fo.depth != 0)) {
            if (simd.orB(keys, scoped)) focus.scan(prev, sc) else sc.modal = types.none;
            fo.step(&ctx.inter, prev, sc, in);
        } else {
            fo.visible = simd.andB(fo.visible, !simd.andB(in.buttons.left, !fo.left));
            fo.left = in.buttons.left;
            fo.last = ctx.inter.focus;
            fo.taken = 0;
        }
        fo.visible = simd.orB(fo.visible, ctx.settings.always_show_focus);
        // Resolve once per IME-active frame, never once per memo. Ordinary focused buttons
        // remain reusable; text-input widgets rerun their per-frame host requests.
        ctx.text_input_node = if (simd.andB(text_input, ctx.inter.focus != 0)) prev.find(@fromBackingInt(ctx.inter.focus)) else types.none;
        // Only declarations survive reuse; scan's group/lead/stop columns are recomputed.
        // Swap one byte column with the tree generation, clearing only a generation that
        // actually declared scopes. The copy path can now restore a moved subtree's kinds.
        std.mem.swap([]u8, &sc.c.kind, &ctx.previous_scope_kind);
        if (ctx.previous_scoped) sc.reset();
        ctx.previous_scoped = scoped;
        scheduler.settle(ctx, in);
        ctx.motion = @max(ctx.anims.step(in.dt), ctx.tweens.step(in.dt));
        ctx.flips.len = 0;

        // Damage is in logical pixels: a new scale, or a new size, moves every physical pixel.
        const view: [3]f32 = .{ in.viewport[0], in.viewport[1], in.scale };
        ctx.redraw_all = ctx.redraw_all or !std.mem.eql(f32, &view, &ctx.last_view);
        ctx.last_view = view;
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

test "requiredBytes: 1005 bytes per node of capacity (docs/perf/bytes.md)" {
    // Two tree generations of 276 bytes a row and a 112-byte extras row each, less the 48
    // bytes of layout scratch they share, plus 170 bytes of draw list, 16 of level-order
    // index (docs/perf/port-perf.md) and 11 of focus scopes, including the previous kind byte.
    // A change here is a change to the recorded footprint.
    var a = example_limits;
    a.nodes = 4096;
    var b = a;
    b.nodes = 8192;
    try testing.expectEqual(1005 * 4096, Context.requiredBytes(b) - Context.requiredBytes(a));
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
    try testing.expectEqual(example_limits.signals, ctx.signals.cap);
    try testing.expectEqual(example_limits.anims, ctx.anims.cap);
    try testing.expectEqual(example_limits.tweens, ctx.tweens.cap);
    try testing.expectEqual(example_limits.memos, ctx.memos.cap);
    try testing.expect(@intFromPtr(ctx.memos.c.stamp.ptr + ctx.memos.c.stamp.len) <= hi);
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

test "begin: Tab and Shift+Tab move focus through the focusable nodes in tree order" {
    const n = comptime Context.requiredBytes(example_limits);
    const S = struct {
        var buffer: [n]u8 align(mem.column_align) = undefined;
    };
    var ctx = try Context.init(&S.buffer, example_limits);
    const ids = [_]types.Id{ .from("a"), .from("label"), .from("b"), .from("c") };
    const tab: Input.Event = .{ .kind = .press, .code = ctx.focus.keys.tab };
    const back: Input.Event = .{ .kind = .press, .code = ctx.focus.keys.tab, .mods = .{ .shift = true } };
    // Each frame presses one key; the label senses no focus, so Tab skips it, as the comptime
    // front end's `focus_order` does.
    const Step = struct { key: Input.Event, want: usize };
    const steps = [_]Step{
        .{ .key = tab, .want = 0 },
        .{ .key = tab, .want = 2 },
        .{ .key = tab, .want = 3 },
        .{ .key = tab, .want = 0 }, // wraps
        .{ .key = back, .want = 3 }, // and back
        .{ .key = back, .want = 2 },
    };
    var in: Input = .{ .viewport = .{ 320, 200 } };
    var events: [1]Input.Event = undefined;
    for (0..steps.len + 1) |k| {
        var f = ctx.begin(&in);
        for (ids, 0..) |id, i| {
            const node = f.leaf(id, .{ .size = .{ .px(40), .px(20) } });
            _ = f.interact(node, if (i == 1) .{ .hover = true } else .button);
        }
        _ = f.end(.{});
        if (k == steps.len) break;
        events[0] = steps[k].key;
        in.events = &events;
        if (k > 0) try testing.expectEqual(@backingInt(ids[steps[k - 1].want]), ctx.inter.focus);
    }
    try testing.expectEqual(@backingInt(ids[steps[steps.len - 1].want]), ctx.inter.focus);
    // The ring shows after a key.
    try testing.expect(ctx.focus.visible);
}

test "begin: a focus group set with Frame.focusScope is one Tab stop" {
    const n = comptime Context.requiredBytes(example_limits);
    const S = struct {
        var buffer: [n]u8 align(mem.column_align) = undefined;
    };
    var ctx = try Context.init(&S.buffer, example_limits);
    const ids = [_]types.Id{ .from("a"), .from("g1"), .from("g2"), .from("c") };
    const tab = [1]Input.Event{.{ .kind = .press, .code = ctx.focus.keys.tab }};
    var in: Input = .{ .viewport = .{ 320, 200 } };
    var want: [3]u32 = undefined;
    for (0..4) |k| {
        var f = ctx.begin(&in);
        if (k > 0) want[k - 1] = ctx.inter.focus;
        _ = f.interact(f.leaf(ids[0], .{ .size = .{ .px(40), .px(20) } }), .button);
        f.focusScope(f.open(.from("group"), .{}), focus.Scopes.group);
        for (ids[1..3]) |id| _ = f.interact(f.leaf(id, .{ .size = .{ .px(40), .px(20) } }), .button);
        f.close();
        _ = f.interact(f.leaf(ids[3], .{ .size = .{ .px(40), .px(20) } }), .button);
        _ = f.end(.{});
        in.events = &tab;
    }
    // a, then the group's first, then past the group to c.
    try testing.expectEqualSlices(u32, &.{ @backingInt(ids[0]), @backingInt(ids[1]), @backingInt(ids[3]) }, &want);
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
        glow: f32 = 0,
        /// A signal, so the sidebar can be skipped while it does not change.
        layers: @import("signals.zig").Cell(u32),
        sidebar_builds: u32 = 0,
    };

    const id_glow = types.Id.from("glow");

    /// The prototype's buildUi.
    fn buildUi(f: *Frame, app: *App) void {
        const th = &app.theme;
        _ = f.open(types.Id.from("toolbar"), .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel });
        if (button(f, th, id_reset, "Reset").clicked) {
            app.resets += 1;
            app.exposure = 1;
        }
        _ = checkbox(f, th, id_wire, &app.wireframe, "Wireframe");
        _ = slider(f, th, id_exposure, &app.exposure, 0, 4);
        // A spring: eases toward its target and keeps the host awake until it lands.
        app.glow = f.animate(id_glow, simd.b2f(app.wireframe), .{});
        f.close();

        _ = f.open(types.Id.from("body"), .{ .dir = .x, .size = .{ .fill, .fill } });
        // Rebuilt only when `layers` changes or the pointer is on one of its widgets.
        if (!f.reuse(id_sidebar, &.{app.layers.signal})) {
            app.sidebar_builds += 1;
            _ = f.open(id_sidebar, .{ .size = .{ .px(160), .fill }, .pad = @splat(8), .gap = 4, .fill = th.panel });
            if (button(f, th, id_add, "Add layer").clicked) app.layers.set(&f.ctx.signals, app.layers.get() + 1);
            var name: [24]u8 = undefined;
            for (0..app.layers.get()) |i| _ = label(f, th, std.fmt.bufPrint(&name, "Layer {d}", .{i}) catch "?");
            f.close();
        }
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
            .canvas => {},
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
    var app: e.App = .{ .layers = .init(&ctx.signals, 3) };
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

test "signals: the sidebar is rebuilt only when it has to be" {
    const n = comptime Context.requiredBytes(example_limits);
    const S = struct {
        var buffer: [n]u8 align(mem.column_align) = undefined;
    };
    const e = example;
    var ctx = try Context.init(&S.buffer, example_limits);
    var app: e.App = .{ .layers = .init(&ctx.signals, 3) };
    var in: Input = .{ .viewport = .{ 800, 600 } };

    var out = e.frame(&ctx, &app, &in);
    try testing.expectEqual(@as(u32, 1), app.sidebar_builds);
    const before = out.tree.rect(out.tree.find(e.id_add));

    // Unchanged dependencies: copied from last frame, same geometry, same text.
    out = e.frame(&ctx, &app, &in);
    out = e.frame(&ctx, &app, &in);
    try testing.expectEqual(@as(u32, 1), app.sidebar_builds);
    try testing.expectEqual(before, out.tree.rect(out.tree.find(e.id_add)));
    try testing.expectEqual(@as(u32, 6), e.render(out.draw).texts);

    // A changed signal wakes the host and rebuilds exactly once.
    app.layers.set(&ctx.signals, 5);
    try testing.expect(ctx.needsFrame(&in));
    out = e.frame(&ctx, &app, &in);
    try testing.expectEqual(@as(u32, 2), app.sidebar_builds);
    try testing.expectEqual(@as(u32, 8), e.render(out.draw).texts);
    out = e.frame(&ctx, &app, &in);
    try testing.expectEqual(@as(u32, 2), app.sidebar_builds);

    // The pointer on a widget inside the subtree forces rebuilds, so the click is seen; "Add
    // layer" then changes the signal itself.
    in.pointer = e.center(before);
    _ = e.frame(&ctx, &app, &in);
    in.buttons.left = true;
    _ = e.frame(&ctx, &app, &in);
    in.buttons.left = false;
    out = e.frame(&ctx, &app, &in);
    try testing.expectEqual(@as(u32, 6), app.layers.get());
    const builds_while_hovering = app.sidebar_builds;
    try testing.expect(builds_while_hovering > 2);

    // Pointer leaves: one more rebuild clears the hover colour, then reuse resumes.
    in.pointer = .{ 700, 500 };
    _ = e.frame(&ctx, &app, &in);
    _ = e.frame(&ctx, &app, &in);
    const settled = app.sidebar_builds;
    out = e.frame(&ctx, &app, &in);
    try testing.expectEqual(settled, app.sidebar_builds);
    try testing.expectEqual(@as(u32, 9), e.render(out.draw).texts);
}

test "springs keep the host awake until they land" {
    const n = comptime Context.requiredBytes(example_limits);
    const S = struct {
        var buffer: [n]u8 align(mem.column_align) = undefined;
    };
    const e = example;
    var ctx = try Context.init(&S.buffer, example_limits);
    var app: e.App = .{ .layers = .init(&ctx.signals, 1) };
    const in: Input = .{ .viewport = .{ 800, 600 } };

    _ = e.frame(&ctx, &app, &in);
    _ = e.frame(&ctx, &app, &in);
    try testing.expect(!ctx.needsFrame(&in));

    app.wireframe = true; // the glow spring now has a new target
    var frames: u32 = 0;
    var out = e.frame(&ctx, &app, &in);
    try testing.expectEqual(@as(f32, 0), out.wake);
    while (out.wake == 0 and frames < 600) : (frames += 1) out = e.frame(&ctx, &app, &in);
    try testing.expect(frames > 5 and frames < 600);
    try testing.expectEqual(@as(f32, 1), app.glow);
    try testing.expectEqual(types.inf, out.wake);
    try testing.expect(!ctx.needsFrame(&in));
}

test "animate: a spring nobody asks for is dropped at the end of the frame" {
    const n = comptime Context.requiredBytes(example_limits);
    const S = struct {
        var buffer: [n]u8 align(mem.column_align) = undefined;
    };
    var ctx = try Context.init(&S.buffer, example_limits);
    const in: Input = .{ .viewport = .{ 100, 100 } };
    var f = ctx.begin(&in);
    try testing.expectEqual(@as(f32, 5), f.animate(types.Id.from("a"), 5, .{}));
    _ = f.animate(types.Id.from("b"), 1, .{});
    _ = f.end(.{});
    try testing.expectEqual(@as(u32, 2), ctx.anims.len);
    f = ctx.begin(&in);
    // Retargeted: still at 5 this frame, moving from the next step on.
    try testing.expectEqual(@as(f32, 5), f.animate(types.Id.from("a"), 0, .{}));
    try testing.expect(ctx.motion > 0);
    _ = f.end(.{});
    try testing.expectEqual(@as(u32, 1), ctx.anims.len);
    f = ctx.begin(&in);
    try testing.expect(f.animate(types.Id.from("a"), 0, .{}) < 5);
    _ = f.end(.{});
}

test "tween: wakes the host for its duration, lands, then the host sleeps" {
    const n = comptime Context.requiredBytes(example_limits);
    const S = struct {
        var buffer: [n]u8 align(mem.column_align) = undefined;
    };
    var ctx = try Context.init(&S.buffer, example_limits);
    const in: Input = .{ .viewport = .{ 100, 100 }, .dt = 1.0 / 64.0 };
    const id = types.Id.from("fade");
    var target: f32 = 0;
    var value: f32 = 0;
    for (0..2) |_| {
        var f = ctx.begin(&in);
        value = f.tween(id, target, 0.25, .out_cubic);
        _ = f.end(.{});
    }
    try testing.expect(!ctx.needsFrame(&in));
    target = 1;
    var frames: u32 = 0;
    while (frames < 100) : (frames += 1) {
        var f = ctx.begin(&in);
        value = f.tween(id, target, 0.25, .out_cubic);
        const out = f.end(.{});
        if (out.wake != 0) break;
    }
    // The frame that sets the target, then 16 steps of 1/64 s.
    try testing.expectEqual(@as(u32, 16), frames);
    try testing.expectEqual(@as(f32, 1), value);
    try testing.expect(!ctx.needsFrame(&in));
}

test "animate, tween: a Rect and a Color move per component, and land on their targets" {
    const n = comptime Context.requiredBytes(example_limits);
    const S = struct {
        var buffer: [n]u8 align(mem.column_align) = undefined;
    };
    var ctx = try Context.init(&S.buffer, example_limits);
    const in: Input = .{ .viewport = .{ 100, 100 }, .dt = 1.0 / 64.0 };
    const from: types.Rect = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 };
    const to: types.Rect = .{ .x0 = 50, .y0 = 0, .x1 = 90, .y1 = 30 };
    var rect = from;
    var color: types.Color = .rgb(0, 0, 0);
    var f = ctx.begin(&in);
    // First use: the target itself.
    try testing.expectEqual(from, f.animate(.from("box"), from, .{}));
    try testing.expectEqual(color, f.tween(.from("ink"), color, 0.25, .linear));
    _ = f.end(.{});
    var frames: u32 = 0;
    while (frames < 200) : (frames += 1) {
        f = ctx.begin(&in);
        rect = f.animate(.from("box"), to, .{});
        color = f.tween(.from("ink"), types.Color.rgb(200, 100, 0), 0.25, .linear);
        if (frames == 4) {
            // Partway: each component between its ends, the one that does not move still.
            try testing.expect(rect.x0 > 0 and rect.x0 < 50);
            try testing.expect(rect.y1 > 10 and rect.y1 < 30);
            try testing.expectEqual(@as(f32, 0), rect.y0);
            try testing.expect(color.r > 0 and color.r < 200 and color.g < 100);
        }
        if (f.end(.{}).wake != 0) break;
    }
    try testing.expectEqual(to, rect);
    try testing.expectEqual(types.Color.rgb(200, 100, 0), color);
    try testing.expect(!ctx.needsFrame(&in));
}

test "transition: a fill change on hover fades over its duration, then the host sleeps" {
    const n = comptime Context.requiredBytes(example_limits);
    const S = struct {
        var buffer: [n]u8 align(mem.column_align) = undefined;
    };
    var ctx = try Context.init(&S.buffer, example_limits);
    var in: Input = .{ .viewport = .{ 200, 100 }, .pointer = .{ 150, 50 }, .dt = 1.0 / 64.0 };
    const idle = types.Color.rgb(0, 0, 0);
    const hot = types.Color.rgb(200, 100, 40);
    const Ui = struct {
        fn frame(c: *Context, i: *const Input) types.Color {
            var f = c.begin(i);
            const node = f.leaf(types.Id.from("btn"), .{ .size = .{ .px(100), .px(100) } });
            const r = f.interact(node, .button);
            const want = if (r.hovered) types.Color.rgb(200, 100, 40) else types.Color.rgb(0, 0, 0);
            f.setFillAnimated(node, types.Id.from("btn"), want, .{ .seconds = 0.125, .ease = .linear });
            const fill: types.Color = @bitCast(f.tree().c.look[node.ix()].fill);
            _ = f.end(.{});
            return fill;
        }
    };
    // Start-up with the pointer away: the first fill is the target itself, no fade.
    try testing.expectEqual(idle, Ui.frame(&ctx, &in));
    _ = Ui.frame(&ctx, &in);
    try testing.expect(!ctx.needsFrame(&in));

    in.pointer = .{ 50, 50 }; // onto the button
    var last = Ui.frame(&ctx, &in); // hover is known this frame: the leg starts
    var frames: u32 = 0;
    while (ctx.needsFrame(&in) and frames < 100) : (frames += 1) {
        const c = Ui.frame(&ctx, &in);
        try testing.expect(c.r >= last.r and c.g >= last.g and c.b >= last.b);
        last = c;
    }
    try testing.expectEqual(hot, last);
    // 0.125 s at 64 Hz is 8 steps, plus the settle frame after the pointer moved.
    try testing.expect(frames >= 8 and frames <= 10);
    try testing.expect(!ctx.needsFrame(&in));
}

test "sequence: plays its keys once on the frame clock, then the host sleeps" {
    const n = comptime Context.requiredBytes(example_limits);
    const S = struct {
        var buffer: [n]u8 align(mem.column_align) = undefined;
    };
    var ctx = try Context.init(&S.buffer, example_limits);
    const in: Input = .{ .viewport = .{ 100, 100 }, .dt = 1.0 / 64.0 };
    const keys = [_]@import("../anim/keyframes.zig").Key{
        .{ .at = 0, .value = 0 },
        .{ .at = 0.125, .value = 1, .ease = .out_quad },
        .{ .at = 0.25, .value = 0, .ease = .in_quad },
    };
    const id = types.Id.from("pulse");
    var seen: [32]f32 = undefined;
    var frames: usize = 0;
    while (frames < seen.len) : (frames += 1) {
        var f = ctx.begin(&in);
        seen[frames] = f.sequence(id, &keys);
        if (f.end(.{}).wake != 0) break;
    }
    // Frame 1 is at t = 0; each later frame is 1/64 s on; t = 0.25 lands on frame 17.
    try testing.expectEqual(@as(usize, 16), frames);
    try testing.expectEqual(@as(f32, 0), seen[0]);
    try testing.expectApproxEqAbs(@as(f32, 1), seen[8], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), seen[16], 1e-5);
    for (1..8) |k| try testing.expect(seen[k] > seen[k - 1]);
    for (9..17) |k| try testing.expect(seen[k] < seen[k - 1]);
    try testing.expect(!ctx.needsFrame(&in));
}

test "animateLayout: a node pushed down by a growing sibling slides there, then rests" {
    const n = comptime Context.requiredBytes(example_limits);
    const S = struct {
        var buffer: [n]u8 align(mem.column_align) = undefined;
    };
    var ctx = try Context.init(&S.buffer, example_limits);
    const in: Input = .{ .viewport = .{ 100, 200 } };
    const card = types.Id.from("card");
    const Ui = struct {
        fn frame(c: *Context, i: *const Input, top: f32) Output {
            var f = c.begin(i);
            _ = f.leaf(.none, .{ .size = .{ .fill, .px(top) } });
            const node = f.open(types.Id.from("card"), .{ .size = .{ .fill, .px(40) } });
            f.animateLayout(node, .{});
            _ = f.leaf(types.Id.from("inside"), .{ .size = .{ .px(10), .px(10) } });
            f.close();
            return f.end(.{});
        }
    };
    // First appearance: no slide.
    var out = Ui.frame(&ctx, &in, 10);
    try testing.expectEqual(@as(f32, 10), out.tree.rect(out.tree.find(card)).y0);
    _ = Ui.frame(&ctx, &in, 10);
    try testing.expect(!ctx.needsFrame(&in));

    // The sibling grows: the card's layout moves to y = 50, but it is shown where it was and
    // slides down, its child with it.
    out = Ui.frame(&ctx, &in, 50);
    var y = out.tree.rect(out.tree.find(card)).y0;
    try testing.expectEqual(@as(f32, 10), y);
    try testing.expect(ctx.needsFrame(&in));
    var frames: u32 = 0;
    while (ctx.needsFrame(&in) and frames < 600) : (frames += 1) {
        out = Ui.frame(&ctx, &in, 50);
        const t = out.tree;
        const now = t.rect(t.find(card)).y0;
        try testing.expect(now >= y and now <= 50.5);
        try testing.expectEqual(now, t.rect(t.find(types.Id.from("inside"))).y0);
        y = now;
    }
    try testing.expect(frames > 5 and frames < 600);
    try testing.expectEqual(@as(f32, 50), y);
    try testing.expectEqual(types.inf, out.wake);
}

test "reduced motion: every animation shows its end state in the frame it changes; idle at once" {
    const n = comptime Context.requiredBytes(example_limits);
    const S = struct {
        var buffer: [n]u8 align(mem.column_align) = undefined;
    };
    var ctx = try Context.init(&S.buffer, example_limits);
    ctx.settings.reduced_motion = true;
    const in: Input = .{ .viewport = .{ 100, 200 } };
    const Key = @import("../anim/keyframes.zig").Key;
    const keys = [_]Key{ .{ .at = 0, .value = 0 }, .{ .at = 0.5, .value = 7 } };
    const Shown = struct { spring: f32, tween: f32, fill: types.Color, seq: f32, y: f32, out: Output };
    const Ui = struct {
        fn frame(c: *Context, i: *const Input, on: bool) Shown {
            var f = c.begin(i);
            var s: Shown = undefined;
            s.spring = f.animate(types.Id.from("glow"), simd.b2f(on), .{});
            s.tween = f.tween(types.Id.from("fade"), 10 * simd.b2f(on), 0.3, .in_out);
            s.fill = f.transition(types.Id.from("fill"), if (on) types.Color.white else types.Color.black, .{});
            s.seq = f.sequence(types.Id.from("pulse"), &keys);
            _ = f.leaf(.none, .{ .size = .{ .fill, .px(if (on) 50 else 10) } });
            const card = f.leaf(types.Id.from("card"), .{ .size = .{ .fill, .px(20) } });
            f.animateLayout(card, .{});
            s.out = f.end(.{});
            s.y = s.out.tree.rect(card.ix()).y0;
            return s;
        }
    };
    var s = Ui.frame(&ctx, &in, false);
    try testing.expectEqual(@as(f32, 7), s.seq); // a sequence shows its last key
    _ = Ui.frame(&ctx, &in, false);
    try testing.expect(!ctx.needsFrame(&in));

    s = Ui.frame(&ctx, &in, true);
    try testing.expectEqual(@as(f32, 1), s.spring);
    try testing.expectEqual(@as(f32, 10), s.tween);
    try testing.expectEqual(types.Color.white, s.fill);
    try testing.expectEqual(@as(f32, 7), s.seq);
    try testing.expectEqual(@as(f32, 50), s.y);
    try testing.expectEqual(types.inf, s.out.wake);
    try testing.expect(!ctx.needsFrame(&in));

    // Turned off again: the next change moves as usual.
    ctx.settings.reduced_motion = false;
    _ = Ui.frame(&ctx, &in, true);
    s = Ui.frame(&ctx, &in, false);
    try testing.expectEqual(@as(f32, 1), s.spring);
    try testing.expectEqual(@as(f32, 50), s.y);
    try testing.expectEqual(@as(f32, 0), s.out.wake);
}

test "initZeroed: Debug checks the buffer's first and last page are zero" {
    var buf: [3 * 4096]u8 = @splat(0);
    try testing.expect(Context.looksZeroed(&buf));
    // What a static `= undefined` buffer holds in Debug: 0xAA everywhere.
    @memset(&buf, 0xaa);
    try testing.expect(!Context.looksZeroed(&buf));
    @memset(&buf, 0);
    buf[buf.len - 1] = 1;
    try testing.expect(!Context.looksZeroed(&buf));
    // Smaller than a page: the whole buffer is checked.
    try testing.expect(Context.looksZeroed(buf[0..100]));
    // A static buffer declared `= @splat(0)` passes the check and carves.
    const small: Limits = .{ .nodes = 8, .texts = 2, .customs = 1, .strings = 16, .depth = 4 };
    const S = struct {
        var zeroed: [Context.requiredBytes(small)]u8 align(mem.column_align) = @splat(0);
    };
    _ = try Context.initZeroed(&S.zeroed, small);
}
