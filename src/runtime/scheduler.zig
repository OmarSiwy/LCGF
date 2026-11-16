//! Scheduler: when the host must run a frame and when it may sleep (tier 1). The host asks
//! `Context.needsFrame` before building a frame; when it is false it sleeps until the next event
//! or until `Output.wake` seconds pass, whichever comes first. Ported from prototype/ui.zig
//! (`Context.needsFrame`, the settle step of `Context.begin`, `Output.wake`).

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const mem = @import("../core/mem.zig");
const Input = @import("../core/input.zig").Input;
const hit = @import("../interact/hit.zig");
const Context = @import("context.zig").Context;
const Limits = @import("context.zig").Limits;
const Frame = @import("frame.zig").Frame;
const Output = @import("context.zig").Output;
const Id = types.Id;
const none = types.none;

/// False when a frame built from `in` would be identical to the last one: the input is unchanged
/// (its stamp leaves out the clock, and the pointer position where it changes nothing: see
/// `stamp`), nothing moves, no settle frame is owed and no signal changed. The host can then
/// sleep until the next event.
pub fn needsFrame(ctx: *const Context, in: *const Input) bool {
    const changed = simd.orB(ctx.frame == 0, stamp(ctx, in) != ctx.last_stamp);
    const pending = simd.orB(ctx.motion > 0, simd.orB(ctx.settle > 0, ctx.signals.dirty));
    const due = in.time >= deadline(ctx);
    const woken = ctx.waker.flag.load(.acquire);
    return simd.orB(simd.orB(changed, woken), simd.orB(pending, due));
}

/// Seconds until a frame is due with no new input: 0 while a settle frame is owed, a spring
/// moves or a `Wake` was posted during the frame, else the time left to `deadline`, else inf (sleep until the next event).
pub fn wake(ctx: *const Context, in: *const Input) f32 {
    const left: f32 = @floatCast(@max(deadline(ctx) - in.time, 0));
    const awake = simd.orB(simd.orB(ctx.motion > 0, ctx.settle > 0), ctx.waker.flag.load(.acquire));
    return simd.selF(awake, 0, left);
}

/// Earliest clock time (`Input.time`) at which a frame is due without new input, or inf: a
/// timer of `Frame.timer`, a held press reaching `long_time`, the hot widget reaching
/// `hover_delay`. Kept in f64 so that `needsFrame` at exactly that time says yes. A timer that
/// has fired is no longer pending.
pub fn deadline(ctx: *const Context) f64 {
    const s = &ctx.inter;
    const long_at = @as(f64, @bitCast(s.press_at)) + s.long_time;
    const hover_at = @as(f64, @bitCast(s.hot_at)) + s.hover_delay;
    const long_due = selD(simd.andB(s.active != 0, !s.long_fired), long_at, inf);
    const hover_due = selD(simd.andB(s.hot != 0, s.hover_intent == 0), hover_at, inf);
    return @min(ctx.timers.earliest(), @min(long_due, hover_due));
}

/// How the host should wait for the next frame. `Output.wake` gives the time; this gives the
/// reason, which a host needs to choose between blocking on events, a timed sleep and pacing to
/// the display (and, with a render thread, whether that thread has to keep presenting).
pub const Pace = enum(u8) {
    /// Nothing pending: block until the next event.
    idle,
    /// A deadline is pending: block until the next event or `wake` seconds, whichever is first.
    timer,
    /// One more frame right away (a settle frame, a posted `Wake`), then re-check. No need to
    /// sync it to the display.
    once,
    /// Something animates: run frames at the display's refresh rate until the pace drops.
    display,
};

/// The pace of the frame just built; the strongest reason wins.
pub fn pace(ctx: *const Context) Pace {
    const timed: u8 = @intFromBool(deadline(ctx) != inf);
    const once: u8 = @intFromBool(simd.orB(ctx.settle > 0, ctx.waker.flag.load(.acquire)));
    const moving: u8 = @intFromBool(ctx.motion > 0);
    return @fromBackingInt(@intCast(@max(moving * 3, @max(once * 2, timed))));
}

const inf = std.math.inf(f64);

/// `c ? a : b` on f64 bits, without a branch.
fn selD(c: bool, a: f64, b: f64) f64 {
    const m = -%@as(u64, @intFromBool(c));
    const ab: u64 = @bitCast(a);
    const bb: u64 = @bitCast(b);
    return @bitCast(bb ^ ((ab ^ bb) & m));
}

/// One row per armed timer. Deadlines are absolute clock times (`Input.time`), so a host that
/// sleeps through several frames still fires them on time.
pub const Timers = struct {
    len: u32 = 0,
    cap: u32,
    c: Columns,

    pub const Columns = struct {
        id: []u32,
        at: []f64,
        /// Frame that last asked for the timer; `sweep` drops the others.
        seen: []u32,
    };

    pub fn init(carver: *mem.Carver, cap: u32) Timers {
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }

    /// The nearest deadline, or inf when no timer is armed.
    pub fn earliest(t: *const Timers) f64 {
        var m: f64 = inf;
        for (t.c.at[0..t.len]) |at| m = @min(m, at);
        return m;
    }

    /// Drops timers nobody asked for in frame `frame`, so a timer the UI stopped asking for
    /// cannot keep waking the host. Branch-free stream compaction.
    pub fn sweep(t: *Timers, frame_no: u32) void {
        t.len = simd.compact(t.c, t.len, t.c.seen, frame_no);
    }
};

/// True on the first frame at least `seconds` after the frame that first asked for timer `id`.
/// Ask for it every frame while you want it; a timer not asked for in a frame is dropped.
/// `.repeat` restarts it when it fires (a caret blink); `.once` drops it when it fires, so a
/// one-shot costs exactly one wakeup (asked again later, it starts over). `Output.wake` brings
/// the host back in time, with no input:
///
///     if (f.timer(.from("caret"), 0.5, .repeat)) caret_on = !caret_on;
///     if (toast and f.timer(.from("toast"), 3, .once)) toast = false;
///
/// Past `Limits.timers` the last row is shared, so extra timers fire early or late, never out of
/// bounds.
pub fn timer(f: *Frame, id: Id, seconds: f32, mode: TimerMode) bool {
    const ctx = f.ctx;
    const t = &ctx.timers;
    const k = @backingInt(id);
    const found = simd.find(t.c.id, t.len, k);
    const missing = found == none;
    const i = simd.selU(missing, @min(t.len, t.cap - 1), found);
    t.len = @min(t.len + @intFromBool(missing), t.cap);
    // A one-shot that fired earlier this frame has no deadline left: asked again, it starts over.
    const is_new = simd.orB(missing, t.c.at[i] == inf);
    const now = f.in.time;
    const at = selD(is_new, now + seconds, t.c.at[i]);
    const fired = now >= at;
    const repeat = mode == .repeat;
    const done = simd.andB(fired, !repeat);
    t.c.id[i] = k;
    // A finished one-shot leaves no deadline and is not seen this frame, so `sweep` drops it.
    t.c.at[i] = selD(fired, selD(repeat, now + seconds, inf), at);
    t.c.seen[i] = ctx.frame -% @intFromBool(done);
    return fired;
}

pub const TimerMode = enum { once, repeat };

/// Called by `begin`. Owes one extra frame after any input change, so state that this frame's
/// events modify (a click handled after the widget was drawn) is visible without waiting for the
/// next event. Unchanged input pays one owed frame back.
pub fn settle(ctx: *Context, in: *const Input) void {
    const s = stamp(ctx, in);
    ctx.settle = simd.selU(s != ctx.last_stamp, 1, ctx.settle -| 1);
    ctx.last_stamp = s;
}

/// `Input.stamp` as the frame sees it. Widgets read the pointer position only over a node that
/// senses the pointer or while a button is held, so elsewhere the position is stamped as
/// "outside the window": a move across text and panels builds no frame, as a retained toolkit
/// redraws nothing for it. Entering or leaving a sensing node changes the stamp. Judged on the
/// last frame's tree, as `Interaction.step` judges hover. `Context.track_pointer` keeps every move.
fn stamp(ctx: *const Context, in: *const Input) u64 {
    const over = hit.at(&ctx.trees[ctx.cur], in.pointer[0], in.pointer[1], .any) != none;
    const held = simd.orB(@as(u8, @bitCast(in.buttons)) != 0, ctx.inter.active != 0);
    const keep = simd.orB(simd.orB(over, held), ctx.track_pointer);
    var seen = in.*;
    seen.pointer = @bitCast(selD(keep, @bitCast(in.pointer), @bitCast(Input.outside)));
    return seen.stamp();
}

/// A frame request that any thread may post: a background job posts it after pushing its result
/// to a `Mailbox`, `needsFrame` then says yes, and `begin` clears it. It does not interrupt the
/// host's sleep; the shell's cross-thread wake does that (shell lane, C0430), so a worker posts
/// both.
pub const Wake = struct {
    flag: std.atomic.Value(bool) = .init(false),

    pub fn post(w: *Wake) void {
        w.flag.store(true, .release);
    }
};

/// A bounded queue for results computed off the UI thread, over a buffer the caller owns. One
/// producer thread and one consumer thread (the UI); lock-free, nothing allocated, never blocks.
/// ponytail: single producer; give each worker its own mailbox, or add a CAS on `tail` if one
/// queue must take many producers.
pub fn Mailbox(comptime T: type) type {
    return struct {
        buf: []T,
        /// Next slot to pop. Written only by the consumer.
        head: std.atomic.Value(u32) = .init(0),
        /// Next slot to push. Written only by the producer.
        tail: std.atomic.Value(u32) = .init(0),

        const Self = @This();

        /// `buf.len` must be a power of two, so the free-running u32 counters wrap cleanly.
        pub fn init(buf: []T) Self {
            std.debug.assert(std.math.isPowerOfTwo(buf.len) and buf.len <= 1 << 31);
            return .{ .buf = buf };
        }

        /// Producer side. False when full; the item is not queued.
        pub fn push(m: *Self, item: T) bool {
            const tail = m.tail.load(.monotonic);
            const head = m.head.load(.acquire);
            if (tail -% head == m.buf.len) return false;
            m.buf[tail & (@as(u32, @intCast(m.buf.len)) - 1)] = item;
            m.tail.store(tail +% 1, .release);
            return true;
        }

        /// Consumer side. The oldest item, or null when empty.
        pub fn pop(m: *Self) ?T {
            const head = m.head.load(.monotonic);
            const tail = m.tail.load(.acquire);
            if (head == tail) return null;
            const item = m.buf[head & (@as(u32, @intCast(m.buf.len)) - 1)];
            m.head.store(head +% 1, .release);
            return item;
        }
    };
}

const testing = std.testing;

/// A context over a static buffer, for tests.
fn Fixture(comptime limits: Limits) type {
    return struct {
        var buffer: [Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
        fn context() !Context {
            return Context.init(&buffer, limits);
        }
    };
}

const small: Limits = .{ .nodes = 16, .texts = 2, .customs = 1, .strings = 64, .depth = 4 };

fn frame(ctx: *Context, in: *const Input) f32 {
    var f = ctx.begin(in);
    _ = f.leaf(.from("box"), .{ .size = .{ .px(10), .px(10) } });
    return f.end(.{}).wake;
}

test "needsFrame: the first frame, then only input changes, motion and signals" {
    const Fx = Fixture(small);
    var ctx = try Fx.context();
    var in: Input = .{ .viewport = .{ 100, 100 } };
    // Nothing was ever built.
    try testing.expect(ctx.needsFrame(&in));
    _ = frame(&ctx, &in);
    // The settle frame after the change is still owed.
    try testing.expect(ctx.needsFrame(&in));
    _ = frame(&ctx, &in);
    try testing.expect(!ctx.needsFrame(&in));

    // The clock is not input: time passing alone wakes nothing.
    in.time += 10;
    try testing.expect(!ctx.needsFrame(&in));

    // The pointer moving over nodes that sense nothing changes no frame (see the next test).
    in.pointer = .{ 5, 5 };
    try testing.expect(!ctx.needsFrame(&in));
    in.viewport = .{ 120, 100 };
    try testing.expect(ctx.needsFrame(&in));
    _ = frame(&ctx, &in);
    _ = frame(&ctx, &in);
    try testing.expect(!ctx.needsFrame(&in));

    // A moving spring keeps frames coming until it rests.
    ctx.motion = 0.5;
    try testing.expect(ctx.needsFrame(&in));
    ctx.motion = 0;

    // A signal bumped between frames wakes the host; the frame that sees it clears it.
    ctx.signals.dirty = true;
    try testing.expect(ctx.needsFrame(&in));
    _ = frame(&ctx, &in);
    try testing.expect(!ctx.needsFrame(&in));
}

test "needsFrame: the pointer position counts over sensing nodes and while held" {
    const Fx = Fixture(small);
    var ctx = try Fx.context();
    var in: Input = .{ .viewport = .{ 100, 100 }, .pointer = .{ 50, 50 } };
    const S = struct {
        // A button over the left half, a plain panel over the right.
        fn run(c: *Context, input: *const Input) u32 {
            var built: u32 = 0;
            while (c.needsFrame(input)) : (built += 1) {
                var f = c.begin(input);
                _ = f.open(.from("row"), .{ .dir = .x, .size = .{ .fill, .fill } });
                const b = f.leaf(.from("b"), .{ .size = .{ .px(50), .fill } });
                _ = f.interact(b, .button);
                _ = f.leaf(.from("panel"), .{ .size = .{ .px(50), .fill } });
                f.close();
                _ = f.end(.{});
            }
            return built;
        }
    };
    in.pointer = .{ 75, 50 };
    try testing.expectEqual(@as(u32, 2), S.run(&ctx, &in));
    // Across the panel: nothing to build.
    for (0..10) |i| {
        in.pointer = .{ 60 + @as(f32, @floatFromInt(i)), 10 + @as(f32, @floatFromInt(i)) };
        try testing.expectEqual(@as(u32, 0), S.run(&ctx, &in));
    }
    // Onto the button: the hover frame and its settle frame; every move over it builds.
    in.pointer = .{ 25, 50 };
    try testing.expectEqual(@as(u32, 2), S.run(&ctx, &in));
    try testing.expectEqual(@backingInt(Id.from("b")), ctx.inter.hot);
    in.pointer = .{ 26, 50 };
    try testing.expect(ctx.needsFrame(&in));
    try testing.expectEqual(@as(u32, 2), S.run(&ctx, &in));
    // Off it: the frame that drops the hover, then quiet again.
    in.pointer = .{ 80, 50 };
    try testing.expectEqual(@as(u32, 2), S.run(&ctx, &in));
    try testing.expectEqual(@as(u32, 0), ctx.inter.hot);
    in.pointer = .{ 90, 50 };
    try testing.expectEqual(@as(u32, 0), S.run(&ctx, &in));
    // A held button makes every move count (a drag that leaves its widget).
    in.buttons.left = true;
    try testing.expect(S.run(&ctx, &in) > 0);
    in.pointer = .{ 91, 50 };
    try testing.expect(ctx.needsFrame(&in));
    _ = S.run(&ctx, &in);
    in.buttons.left = false;
    _ = S.run(&ctx, &in);
    // So does `track_pointer`.
    ctx.track_pointer = true;
    in.pointer = .{ 92, 50 };
    try testing.expect(ctx.needsFrame(&in));
}

test "needsFrame: moving springs ask for a frame now through wake" {
    const Fx = Fixture(small);
    var ctx = try Fx.context();
    const in: Input = .{ .viewport = .{ 100, 100 } };
    _ = frame(&ctx, &in);
    try testing.expectEqual(types.inf, frame(&ctx, &in));
    var f = ctx.begin(&in);
    ctx.motion = 0.25;
    try testing.expectEqual(@as(f32, 0), f.end(.{}).wake);
}

test "settle: one frame owed after each input change, none after unchanged input" {
    const Fx = Fixture(small);
    var ctx = try Fx.context();
    var in: Input = .{ .viewport = .{ 100, 100 } };
    settle(&ctx, &in);
    try testing.expectEqual(@as(u32, 1), ctx.settle);
    settle(&ctx, &in);
    try testing.expectEqual(@as(u32, 0), ctx.settle);
    // Never below zero, and the clock alone is not a change.
    in.time = 3;
    settle(&ctx, &in);
    try testing.expectEqual(@as(u32, 0), ctx.settle);
    // A change on every frame keeps exactly one frame owed.
    for (0..3) |i| {
        in.viewport[0] = @floatFromInt(101 + i);
        settle(&ctx, &in);
        try testing.expectEqual(@as(u32, 1), ctx.settle);
    }
}

test "settle: a click is drawn by the frame after the one that handled it" {
    const Fx = Fixture(small);
    var ctx = try Fx.context();
    var in: Input = .{ .viewport = .{ 100, 100 } };
    var clicks: u32 = 0;
    var drawn: u32 = 0;
    for (0..4) |i| {
        // Press on tick 1, release on tick 2; no input after that.
        in.pointer = .{ 5, 5 };
        in.buttons.left = i == 1;
        if (!ctx.needsFrame(&in)) continue;
        var f = ctx.begin(&in);
        // The label shows the count before the button handles this frame's click, as a
        // widget drawn above its handler does.
        drawn = clicks;
        const b = f.leaf(.from("b"), .{ .size = .{ .px(10), .px(10) } });
        clicks += @intFromBool(f.interact(b, .button).clicked);
        _ = f.end(.{});
    }
    try testing.expectEqual(@as(u32, 1), clicks);
    // Without the settle frame the last frame would still show 0.
    try testing.expectEqual(@as(u32, 1), drawn);
    try testing.expect(!ctx.needsFrame(&in));
}

test "timer: fires once per period; the earliest deadline is the wake" {
    const Fx = Fixture(small);
    var ctx = try Fx.context();
    var in: Input = .{ .viewport = .{ 100, 100 } };
    // Two settle-free frames first, so wake answers for the timers alone.
    _ = frame(&ctx, &in);
    _ = frame(&ctx, &in);
    var fired: [2]bool = undefined;
    const S = struct {
        fn run(c: *Context, input: *const Input, out: *[2]bool) f32 {
            var f = c.begin(input);
            out[0] = f.timer(.from("slow"), 2, .once);
            out[1] = f.timer(.from("fast"), 0.5, .repeat);
            return f.end(.{}).wake;
        }
    };
    in.time = 10;
    try testing.expectEqual(@as(f32, 0.5), S.run(&ctx, &in, &fired));
    try testing.expectEqual([2]bool{ false, false }, fired);
    try testing.expectEqual(@as(u32, 2), ctx.timers.len);

    // The host sleeps for `wake`; needsFrame agrees at exactly the deadline, not before.
    in.time = 10.25;
    try testing.expect(!ctx.needsFrame(&in));
    in.time = 10.5;
    try testing.expect(ctx.needsFrame(&in));
    // "fast" fires and restarts: next due at 11, before "slow" at 12.
    try testing.expectEqual(@as(f32, 0.5), S.run(&ctx, &in, &fired));
    try testing.expectEqual([2]bool{ false, true }, fired);
    var f: Frame = undefined;
    // The host overslept "fast" (due at 11): both fire at 12. The one-shot is gone; "fast"
    // restarts at 12.5.
    in.time = 12;
    try testing.expectEqual(@as(f32, 0.5), S.run(&ctx, &in, &fired));
    try testing.expectEqual([2]bool{ true, true }, fired);
    try testing.expectEqual(@as(u32, 1), ctx.timers.len);
    try testing.expectEqual(@as(f64, 12.5), ctx.timers.earliest());
    // A one-shot asked again starts over, even in the frame it fired. ("fast" was not asked
    // for in this frame, so it is gone.)
    f = ctx.begin(&in);
    try testing.expect(f.timer(.from("once"), 0, .once));
    try testing.expect(!f.timer(.from("once"), 1, .once));
    _ = f.end(.{});
    try testing.expectEqual(@as(f64, 13), ctx.timers.earliest());
    try testing.expectEqual(@as(u32, 1), ctx.timers.len);

    // Nobody asks any more: the timers are dropped and the host sleeps.
    f = ctx.begin(&in);
    try testing.expectEqual(types.inf, f.end(.{}).wake);
    try testing.expectEqual(@as(u32, 0), ctx.timers.len);
    in.time = 100;
    try testing.expect(!ctx.needsFrame(&in));
}

test "timer: past the limit the last row is shared, never written out of bounds" {
    const Fx = Fixture(.{ .nodes = 4, .texts = 1, .customs = 1, .strings = 16, .depth = 2, .timers = 2 });
    var ctx = try Fx.context();
    const in: Input = .{};
    var f = ctx.begin(&in);
    for (0..5) |i| _ = f.timer(Id.from("t").with(@intCast(i)), 1, .once);
    try testing.expectEqual(@as(u32, 2), ctx.timers.len);
    _ = f.end(.{});
    try testing.expectEqual(@as(f64, 1), ctx.timers.earliest());
}

test "deadline: a pending hover intent wakes a sleeping host through needsFrame" {
    const Fx = Fixture(small);
    var ctx = try Fx.context();
    var in: Input = .{ .viewport = .{ 100, 100 }, .pointer = .{ 5, 5 } };
    _ = frame(&ctx, &in);
    in.time = 1;
    // The box becomes hot at t = 1 (it needs a sense to be hit). The pointer now stands over a
    // sensing node, which changes its stamp: one settle frame follows.
    for (0..3) |_| {
        var f = ctx.begin(&in);
        const b = f.leaf(.from("box"), .{ .size = .{ .px(10), .px(10) } });
        _ = f.interact(b, .any);
        _ = f.end(.{});
    }
    try testing.expectEqual(@as(f64, 1.5), deadline(&ctx));
    in.time = 1.4;
    try testing.expect(!ctx.needsFrame(&in));
    in.time = 1.5;
    try testing.expect(ctx.needsFrame(&in));
}

test "Mailbox: first in, first out; refuses when full" {
    var buf: [4]u32 = undefined;
    var m: Mailbox(u32) = .init(&buf);
    try testing.expectEqual(@as(?u32, null), m.pop());
    for (0..4) |i| try testing.expect(m.push(@intCast(i)));
    try testing.expect(!m.push(9));
    try testing.expectEqual(@as(?u32, 0), m.pop());
    try testing.expect(m.push(4));
    // Wraps around the buffer in order.
    for (1..5) |i| try testing.expectEqual(@as(?u32, @intCast(i)), m.pop());
    try testing.expectEqual(@as(?u32, null), m.pop());
}

test "Mailbox and Wake: a worker thread's results arrive in order and wake the host" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const Fx = Fixture(small);
    var ctx = try Fx.context();
    var in: Input = .{ .viewport = .{ 100, 100 } };
    _ = frame(&ctx, &in);
    _ = frame(&ctx, &in);
    try testing.expect(!ctx.needsFrame(&in));

    var buf: [8]u64 = undefined;
    var box: Mailbox(u64) = .init(&buf);
    const count = 10_000;
    const Worker = struct {
        fn run(b: *Mailbox(u64), w: *Wake) void {
            for (1..count + 1) |v| {
                while (!b.push(v)) std.Thread.yield() catch {};
                w.post();
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &box, &ctx.waker });

    // The host loop: a frame only when asked for, draining the mailbox inside it.
    var next: u64 = 1;
    var frames: u32 = 0;
    while (next <= count) {
        if (!ctx.needsFrame(&in)) {
            std.Thread.yield() catch {};
            continue;
        }
        frames += 1;
        var f = ctx.begin(&in);
        while (box.pop()) |v| : (next += 1) try testing.expectEqual(next, v);
        _ = f.end(.{});
    }
    thread.join();
    try testing.expect(frames >= 1);
    // The last post may land after the frame that drained it: at most one more frame, then idle.
    if (ctx.needsFrame(&in)) _ = frame(&ctx, &in);
    try testing.expect(!ctx.needsFrame(&in));
    try testing.expectEqual(@as(?u64, null), box.pop());
}

test "pace: idle, timer, once and display, strongest reason first" {
    const Fx = Fixture(small);
    var ctx = try Fx.context();
    var in: Input = .{ .viewport = .{ 100, 100 } };
    const S = struct {
        fn run(c: *Context, input: *const Input, with_timer: bool, motion: f32) Output {
            var f = c.begin(input);
            if (with_timer) _ = f.timer(.from("t"), 1, .repeat);
            c.motion = motion;
            return f.end(.{});
        }
    };
    // First frame: a settle frame is owed.
    try testing.expectEqual(Pace.once, S.run(&ctx, &in, false, 0).pace);
    var out = S.run(&ctx, &in, false, 0);
    try testing.expectEqual(Pace.idle, out.pace);
    try testing.expectEqual(types.inf, out.wake);
    out = S.run(&ctx, &in, true, 0);
    try testing.expectEqual(Pace.timer, out.pace);
    try testing.expectEqual(@as(f32, 1), out.wake);
    // A spring outranks the timer; wake is 0 for both once and display.
    out = S.run(&ctx, &in, true, 0.5);
    try testing.expectEqual(Pace.display, out.pace);
    try testing.expectEqual(@as(f32, 0), out.wake);
    // A wake posted during the frame asks for one more, now.
    var f = ctx.begin(&in);
    ctx.waker.post();
    out = f.end(.{});
    try testing.expectEqual(Pace.once, out.pace);
    try testing.expectEqual(@as(f32, 0), out.wake);
    try testing.expectEqual(Pace.idle, S.run(&ctx, &in, false, 0).pace);
    in.pointer = .{ 1, 1 };
    // Input changed while a spring moves: still display.
    try testing.expectEqual(Pace.display, S.run(&ctx, &in, false, 0.5).pace);
}

/// The idle scene (target D5): a small UI with every scheduler feature in it, run by an
/// event-driven host in the way the Dear ImGui wiki's power-save loop does it, with the clock
/// simulated: build a frame only when `needsFrame` says so, otherwise block on events with
/// `Output.wake` as the timeout.
const IdleScene = struct {
    ctx: Context,
    in: Input = .{ .viewport = .{ 200, 100 } },
    /// The last frame's answer: how long the host may block.
    wake: f32 = 0,
    pace: Pace = .once,
    /// Frames built, and timeouts that expired (the host woke without an event).
    frames: u32 = 0,
    wakeups: u32 = 0,
    // App state.
    toast: bool = false,
    results: u32 = 0,
    box: *Mailbox(u32),

    const id_button = Id.from("button");
    const id_toast = Id.from("toast");

    fn build(s: *IdleScene) void {
        var f = s.ctx.begin(&s.in);
        _ = f.open(.none, .{ .dir = .x, .gap = 10 });
        const b = f.leaf(id_button, .{ .size = .{ .px(40), .px(40) } });
        _ = f.interact(b, .any);
        // A toast that hides itself after 3 s: its timer is asked for only while it shows.
        if (s.toast) {
            _ = f.text("saved", .{});
            if (f.timer(id_toast, 3, .once)) s.toast = false;
        }
        while (s.box.pop()) |v| s.results += v;
        f.close();
        const out = f.end(.{});
        s.wake = out.wake;
        s.pace = out.pace;
        s.frames += 1;
    }

    /// No input for `seconds` of clock time. Fails on a busy loop.
    fn wait(s: *IdleScene, seconds: f64) !void {
        const until = s.in.time + seconds;
        for (0..10_000) |_| {
            if (s.ctx.needsFrame(&s.in)) {
                s.build();
                continue;
            }
            // Blocked on events: only the timeout can end the wait.
            if (s.wake == types.inf or s.in.time + s.wake > until) {
                s.in.time = until;
                return;
            }
            s.in.time += s.wake;
            s.wakeups += 1;
        }
        return error.BusyLoop;
    }

    fn expectIdle(s: *IdleScene, seconds: f64) !void {
        const frames = s.frames;
        const wakeups = s.wakeups;
        try s.wait(seconds);
        try testing.expectEqual(frames, s.frames);
        try testing.expectEqual(wakeups, s.wakeups);
        try testing.expectEqual(Pace.idle, s.pace);
        try testing.expectEqual(types.inf, s.wake);
    }
};

test "idle: zero frames and zero wakeups without input" {
    const Fx = Fixture(small);
    var buf: [4]u32 = undefined;
    var box: Mailbox(u32) = .init(&buf);
    var s: IdleScene = .{ .ctx = try Fx.context(), .box = &box };

    // Start-up: the first frame and its settle frame, then nothing for a minute.
    try s.wait(1);
    try testing.expectEqual(@as(u32, 2), s.frames);
    try testing.expectEqual(@as(u32, 0), s.wakeups);
    try s.expectIdle(60);

    // The pointer comes to rest on the button: 2 frames (input, settle), then one timeout when
    // the hover intent falls due, its frame, and idle again.
    s.in.pointer = .{ 20, 20 };
    s.frames = 0;
    try s.wait(5);
    try testing.expectEqual(@as(u32, 3), s.frames);
    try testing.expectEqual(@as(u32, 1), s.wakeups);
    try testing.expectEqual(@backingInt(IdleScene.id_button), s.ctx.inter.hover_intent);
    try s.expectIdle(60);

    // A one-shot timer: the toast hides itself 3 s later with one timeout, then idle.
    s.toast = true;
    s.ctx.signals.dirty = true; // what a signal bump on the toast flag does
    s.frames = 0;
    s.wakeups = 0;
    try s.wait(10);
    try testing.expect(!s.toast);
    try testing.expectEqual(@as(u32, 1), s.wakeups);
    try testing.expectEqual(@as(u32, 0), s.ctx.timers.len);
    try s.expectIdle(60);

    // A background result: exactly one frame drains it, no timeout, then idle.
    try testing.expect(box.push(7));
    s.ctx.waker.post();
    s.frames = 0;
    s.wakeups = 0;
    try s.wait(1);
    try testing.expectEqual(@as(u32, 7), s.results);
    try testing.expectEqual(@as(u32, 1), s.frames);
    try testing.expectEqual(@as(u32, 0), s.wakeups);
    try s.expectIdle(3600);
}
