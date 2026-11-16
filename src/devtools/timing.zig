//! Per-pass timers for the inspector (docs/CHECKS.md, "Benchmark": the per-pass means). The core
//! has no clock and no hook between its passes, so timing is the host's job: it copies the body
//! of `Frame.end` (whose comment invites exactly that) with a lap between the passes. `end` below
//! is that copy. It reads the clock through the host's `std.Io`, which puts this file outside
//! the tiers (docs/ARCHITECTURE.md), next to the shells; `Timings` itself is plain data the
//! inspector shows.
//!
//!     var clock: timing.Clock = .start(io);
//!     var f = ctx.begin(&in);
//!     clock.lap(&tm, .begin);
//!     app.build(&f, &ev);
//!     insp.build(&f);
//!     clock.lap(&tm, .build);
//!     const out = timing.end(&f, .{}, &clock, &tm);
//!     insp.timings = tm;   // shown next frame

const std = @import("std");
const simd = @import("../core/simd.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Output = @import("../runtime/context.zig").Output;
const Mono = @import("../text/protocol.zig").Mono;
const layout = @import("../layout/layout.zig");
const incremental = @import("../layout/incremental.zig");
const flip = @import("../anim/flip.zig");

/// The steps of one frame, in order. `layout_x` and `layout_y` are prepare, text, fit and
/// resolve on each axis; `wrap` is text width handed down and the font's wrap; `place` includes
/// the layout slide (`flip.apply`).
pub const Pass = enum(u8) { begin, build, measure, layout_x, wrap, layout_y, place, finalize, paint };

/// Nanoseconds per pass of one frame.
pub const Timings = struct {
    ns: [count]u64 = @splat(0),

    pub const count = @typeInfo(Pass).@"enum".field_names.len;

    pub fn total(tm: *const Timings) u64 {
        var sum: u64 = 0;
        for (tm.ns) |n| sum += n;
        return sum;
    }
};

/// A stopwatch on the host's monotonic clock.
pub const Clock = struct {
    io: std.Io,
    last: std.Io.Timestamp,

    pub fn start(io: std.Io) Clock {
        return .{ .io = io, .last = .now(io, .awake) };
    }

    /// Charges the time since the last lap to `pass`.
    pub fn lap(c: *Clock, tm: *Timings, pass: Pass) void {
        const now = std.Io.Timestamp.now(c.io, .awake);
        tm.ns[@backingInt(pass)] = @intCast(@max(c.last.durationTo(now).toNanoseconds(), 0));
        c.last = now;
    }
};

/// `Frame.end` with a lap after each pass. Same calls in the same order, so the same output.
pub fn end(f: *Frame, font: Mono, c: *Clock, tm: *Timings) Output {
    const t = f.tree();
    const tx = f.texts();
    t.seal(0);
    font.measure(tx);
    c.lap(tm, .measure);
    const m = &f.ctx.memos;
    const kept = m.kept[0..simd.selU(t.overflow, 0, m.kept_len)];
    incremental.prepareKept(t, kept);
    incremental.applyTextKept(t, tx, .x, kept);
    incremental.fitKept(t, .x, kept);
    incremental.resolveKept(t, .x, f.in.viewport[0], kept);
    c.lap(tm, .layout_x);
    layout.textAvail(t, tx);
    font.wrap(tx);
    c.lap(tm, .wrap);
    incremental.applyTextKept(t, tx, .y, kept);
    incremental.fitKept(t, .y, kept);
    incremental.resolveKept(t, .y, f.in.viewport[1], kept);
    c.lap(tm, .layout_y);
    incremental.placeKept(t, kept);
    if (!f.ctx.settings.reduced_motion) f.ctx.motion = @max(f.ctx.motion, flip.apply(t, f.prevTree(), &f.ctx.flips, &f.ctx.anims, f.ctx.frame));
    c.lap(tm, .place);
    layout.finalize(t);
    c.lap(tm, .finalize);
    const out = f.finish();
    c.lap(tm, .paint);
    return out;
}
