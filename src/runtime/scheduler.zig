//! Scheduler: when the host must run a frame and when it may sleep (tier 1). The host asks
//! `Context.needsFrame` before building a frame; when it is false it sleeps until the next event
//! or until `Output.wake` seconds pass, whichever comes first. Ported from prototype/ui.zig
//! (`Context.needsFrame`, the settle step of `Context.begin`, `Output.wake`).

const std = @import("std");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const mem = @import("../core/mem.zig");
const Input = @import("../core/input.zig").Input;
const Context = @import("context.zig").Context;
const Limits = @import("context.zig").Limits;
const Frame = @import("frame.zig").Frame;
const Output = @import("context.zig").Output;
const Id = types.Id;
const none = types.none;

/// False when a frame built from `in` would be identical to the last one: the input is unchanged
/// (its stamp leaves out the clock), nothing moves, no settle frame is owed and no signal changed.
/// The host can then sleep until the next event.
pub fn needsFrame(ctx: *const Context, in: *const Input) bool {
    const changed = simd.orB(ctx.frame == 0, in.stamp() != ctx.last_stamp);
    const pending = simd.orB(ctx.motion > 0, simd.orB(ctx.settle > 0, ctx.dirty));
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

/// True on the first frame at least `seconds` after the frame that first asked for timer `id`,
/// which then restarts. Ask every frame for a repeating timer (a caret blink); stop asking to
/// drop it (it is gone after the first frame that does not ask). `Output.wake` brings the host
/// back in time, with no input:
///
///     if (f.timer(.from("caret"), 0.5)) caret_on = !caret_on;
///
/// Past `Limits.timers` the last row is shared, so extra timers fire early or late, never out of
/// bounds.
pub fn timer(f: *Frame, id: Id, seconds: f32) bool {
    const ctx = f.ctx;
    const t = &ctx.timers;
    const k = @backingInt(id);
    const found = simd.find(t.c.id, t.len, k);
    const is_new = found == none;
    const i = simd.selU(is_new, @min(t.len, t.cap - 1), found);
    t.len = @min(t.len + @intFromBool(is_new), t.cap);
    const now = f.in.time;
    const at = selD(is_new, now + seconds, t.c.at[i]);
    const fired = now >= at;
    t.c.id[i] = k;
    t.c.at[i] = selD(fired, now + seconds, at);
    t.c.seen[i] = ctx.frame;
    return fired;
}

/// Called by `begin`. Owes one extra frame after any input change, so state that this frame's
/// events modify (a click handled after the widget was drawn) is visible without waiting for the
/// next event. Unchanged input pays one owed frame back.
pub fn settle(ctx: *Context, in: *const Input) void {
    const stamp = in.stamp();
    ctx.settle = simd.selU(stamp != ctx.last_stamp, 1, ctx.settle -| 1);
    ctx.last_stamp = stamp;
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

    in.pointer = .{ 5, 5 };
    try testing.expect(ctx.needsFrame(&in));
    _ = frame(&ctx, &in);
    _ = frame(&ctx, &in);
    try testing.expect(!ctx.needsFrame(&in));

    // A moving spring keeps frames coming until it rests.
    ctx.motion = 0.5;
    try testing.expect(ctx.needsFrame(&in));
    ctx.motion = 0;

    // A signal bumped between frames wakes the host; the frame that sees it clears it.
    ctx.dirty = true;
    try testing.expect(ctx.needsFrame(&in));
    _ = frame(&ctx, &in);
    try testing.expect(!ctx.needsFrame(&in));
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
        in.pointer[0] = @floatFromInt(i);
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
            out[0] = f.timer(.from("slow"), 2);
            out[1] = f.timer(.from("fast"), 0.5);
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
    in.time = 12;
    _ = S.run(&ctx, &in, &fired);
    try testing.expectEqual([2]bool{ true, true }, fired);

    // Nobody asks any more: the timers are dropped and the host sleeps.
    var f = ctx.begin(&in);
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
    for (0..5) |i| _ = f.timer(Id.from("t").with(@intCast(i)), 1);
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
    // The box becomes hot at t = 1 (it needs a sense to be hit).
    for (0..2) |_| {
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
            if (with_timer) _ = f.timer(.from("t"), 1);
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

/// What an event-driven host did over `ticks` turns of its loop with no new input: frames it
/// built (`needsFrame` held) and timed wakeups it would have armed (a finite `wake`).
const Idle = struct { frames: u32 = 0, wakeups: u32 = 0 };

fn idle(ctx: *Context, in: *Input, ticks: u32) Idle {
    var r: Idle = .{};
    for (0..ticks) |_| {
        in.time += in.dt;
        if (!ctx.needsFrame(in)) continue;
        r.frames += 1;
        r.wakeups += @intFromBool(frame(ctx, in) != types.inf);
    }
    return r;
}

test "idle: zero frames and zero wakeups without input" {
    const Fx = Fixture(small);
    var ctx = try Fx.context();
    var in: Input = .{ .viewport = .{ 100, 100 } };
    // Start-up: the first frame and its settle frame, which asks for no timed wake.
    try testing.expectEqual(Idle{ .frames = 2, .wakeups = 1 }, idle(&ctx, &in, 2));
    try testing.expectEqual(Idle{}, idle(&ctx, &in, 600));
    // One input change: one frame and one settle frame, then idle again.
    in.pointer = .{ 3, 3 };
    try testing.expectEqual(Idle{ .frames = 2, .wakeups = 1 }, idle(&ctx, &in, 600));
}
