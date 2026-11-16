//! The tick source: the clock of a board with no OS, after LVGL's `lv_tick_inc` (docs.lvgl.io
//! 9.5, "Requirements"). A timer interrupt adds its period in milliseconds to a `Tick`; the shell
//! reads it for `Input.time` and `dt` and to time its waits. A board with a free-running
//! millisecond counter calls `inc` with the counter's advance instead.

const std = @import("std");
const Input = @import("../../core/input.zig").Input;

/// Milliseconds since start, wrapping after 2^32 (49.7 days); `Clock` and the shell's waits use
/// differences only, which survive the wrap.
pub const Tick = struct {
    ms: std.atomic.Value(u32) = .init(0),

    /// From the timer interrupt: `period` milliseconds passed. There is one writer, so this is a
    /// load and a store, which every target has, not a read-modify-write, which Cortex-M0 has not.
    pub fn inc(t: *Tick, period: u32) void {
        t.ms.store(t.ms.load(.monotonic) +% period, .release);
    }

    pub fn now(t: *const Tick) u32 {
        return t.ms.load(.acquire);
    }
};

/// Turns tick readings into `Input.time` and `Input.dt`.
pub const Clock = struct {
    last: u32,
    /// Seconds since `init`.
    time: f64 = 0,

    pub fn init(now: u32) Clock {
        return .{ .last = now };
    }

    /// Sets `in.time` and `in.dt` for a frame read at tick `now`.
    pub fn step(c: *Clock, now: u32, in: *Input) void {
        const dt = @as(f32, @floatFromInt(now -% c.last)) / 1000;
        c.last = now;
        c.time += dt;
        in.time = c.time;
        in.dt = dt;
    }
};

/// Milliseconds a wait of `seconds` lasts, rounded up; `inf` (and anything from 4e9 ms on) is
/// `maxInt(u32)`, 49.7 days.
pub fn millis(seconds: f32) u32 {
    const ms = @ceil(seconds * 1000);
    if (!(ms < 4e9)) return std.math.maxInt(u32);
    return @intFromFloat(@max(ms, 0));
}

const testing = std.testing;

test "tick: time and dt across the wrap of the counter" {
    var t: Tick = .{};
    t.inc(std.math.maxInt(u32) - 9); // 10 ms before the wrap
    var c: Clock = .init(t.now());
    var in: Input = .{};
    t.inc(5);
    t.inc(5);
    t.inc(20); // wrapped
    try testing.expectEqual(@as(u32, 20), t.now());
    c.step(t.now(), &in);
    try testing.expectApproxEqAbs(@as(f32, 0.030), in.dt, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.030), in.time, 1e-6);
    t.inc(16);
    c.step(t.now(), &in);
    try testing.expectApproxEqAbs(@as(f32, 0.016), in.dt, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.046), in.time, 1e-6);
}

test "tick: millis rounds up and saturates" {
    try testing.expectEqual(@as(u32, 0), millis(0));
    try testing.expectEqual(@as(u32, 17), millis(0.0161));
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), millis(std.math.inf(f32)));
    try testing.expectEqual(@as(u32, 0), millis(-1));
}
