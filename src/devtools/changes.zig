//! Signal changes and reuse decisions, for the inspector. Signals are plain counters the core
//! exposes (`Signals.version`), so changes are found by keeping last frame's copy and comparing.
//! A reuse decision is only the `bool` `Frame.reuse` returns to its caller, so the application
//! asks through `ReuseLog.reuse`, which calls `Frame.reuse` and writes the answer down, with
//! why, read from the memo row and the signal stamp before the call. Nothing in the runtime
//! changes for it.

const std = @import("std");
const types = @import("lcgf").types;
const simd = @import("lcgf").simd;
const Frame = @import("lcgf").frame.Frame;
const Signals = @import("lcgf").runtime_signals.Signals;
const Signal = @import("lcgf").runtime_signals.Signal;
const none = types.none;
const Id = types.Id;

/// The signals whose version moved since the last `diff`.
pub const SignalWatch = struct {
    /// Signals watched; ones created past it are not.
    pub const cap = 64;
    seen: [cap]u32 = @splat(0),
    seen_len: u32 = 0,
    changed: [cap]u32 = undefined,
    /// New version of each `changed` row.
    version: [cap]u32 = undefined,
    changed_len: u32 = 0,

    /// Compares `s` with the versions seen last time and keeps them for next time. A signal
    /// created since counts as changed only if it is past version 0.
    pub fn diff(sw: *SignalWatch, s: *const Signals) void {
        const n = @min(s.len, cap);
        sw.changed_len = 0;
        for (0..n) |i| {
            const old = if (i < sw.seen_len) sw.seen[i] else 0;
            sw.changed[sw.changed_len] = @intCast(i);
            sw.version[sw.changed_len] = s.version[i];
            sw.changed_len += @intFromBool(s.version[i] != old);
            sw.seen[i] = s.version[i];
        }
        sw.seen_len = n;
    }
};

/// Why `Frame.reuse` built a subtree again, or that it copied it.
pub const Decision = enum(u8) {
    /// Copied from last frame.
    reused,
    /// First time this id was asked for (or its memo row was taken).
    new,
    /// A dependency's version moved.
    signals,
    /// Same signals, but the pointer is over or holding something in it, a spring or tween in
    /// it is moving, it was not built last frame, or it does not fit.
    other,
};

/// This frame's `reuse` calls, in call order.
pub const ReuseLog = struct {
    pub const cap = 32;
    id: [cap]u32 = undefined,
    decision: [cap]Decision = undefined,
    len: u32 = 0,
    /// Calls past `cap` this frame: decided, not logged.
    dropped: u32 = 0,

    /// `Frame.reuse`, logged. Same arguments, same result.
    pub fn reuse(log: *ReuseLog, f: *Frame, id: Id, deps: []const Signal) bool {
        const m = &f.ctx.memos;
        const slot = simd.find(m.c.id, m.len, @backingInt(id));
        // `reuse` stores the stamp with its low bit flipped after a pointer- or animation-caused
        // rebuild, so a difference of that bit alone is not a signal change.
        const stored = if (slot == none) 0 else m.c.stamp[slot];
        const moved = (stored ^ f.ctx.signals.stamp(deps)) > 1;
        const copied = f.reuse(id, deps);
        const why: Decision = if (copied) .reused else if (slot == none) .new else if (moved) .signals else .other;
        const k = @min(log.len, cap - 1);
        log.id[k] = @backingInt(id);
        log.decision[k] = why;
        log.dropped += @intFromBool(log.len == cap);
        log.len = @min(log.len + 1, cap);
        return copied;
    }

    /// Empties the log for the next frame.
    pub fn clear(log: *ReuseLog) void {
        log.len = 0;
        log.dropped = 0;
    }
};
