//! Signals: change counters for the runtime front end (tier 1). The value lives in the caller's
//! data, not here; a signal is only a version number that goes up when that data changes.
//! Nothing subscribes and nothing is called back: a reader keeps the versions it last saw
//! (`stamp`) and compares. The comptime front end resolves the same graph at compile time
//! (src/comptime/signals.zig). Ported from prototype/ui.zig ("Signals").

const std = @import("std");
const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");

/// A row of `Signals.version`.
pub const Signal = enum(u32) { _ };

pub const Signals = struct {
    /// One counter per signal. Wraps; only equality is ever asked of it.
    version: []u32,
    len: u32 = 0,
    cap: u32,
    /// Something changed since the last frame. The frame's `finish` clears it; the scheduler
    /// reads it to decide whether a frame is needed.
    dirty: bool = false,

    pub fn init(carver: *mem.Carver, cap: u32) Signals {
        return .{ .cap = cap, .version = carver.slice(u32, simd.rows(cap)) };
    }

    /// A new signal at version 0. Past `cap` every new signal shares the last row: they report
    /// each other's changes, which costs extra work but never a missed update.
    pub fn create(s: *Signals) Signal {
        const i = @min(s.len, s.cap - 1);
        s.len = i + 1;
        return @fromBackingInt(i);
    }

    /// Records that the data behind `sig` changed (or did not: `changed` is folded in
    /// arithmetically, so callers need no `if`).
    pub fn bump(s: *Signals, sig: Signal, changed: bool) void {
        s.version[@backingInt(sig)] +%= @intFromBool(changed);
        s.dirty = simd.orB(s.dirty, changed);
    }

    /// `bump` for data that is known to have changed.
    pub fn touch(s: *Signals, sig: Signal) void {
        s.bump(sig, true);
    }
};

const testing = std.testing;

/// Signals over a static buffer, for tests.
fn fixture(comptime cap: u32) Signals {
    const S = struct {
        var buffer: [simd.rows(cap) * 4 + mem.column_align]u8 align(mem.column_align) = undefined;
    };
    var carver: mem.Carver = .{ .buf = &S.buffer };
    return .init(&carver, cap);
}

test "bump: a change raises the version and marks dirty; no change does neither" {
    var s = fixture(4);
    const a = s.create();
    const b = s.create();
    try testing.expect(a != b);
    try testing.expectEqual(@as(u32, 0), s.version[@backingInt(a)]);

    s.bump(a, false);
    try testing.expectEqual(@as(u32, 0), s.version[@backingInt(a)]);
    try testing.expect(!s.dirty);

    s.bump(a, true);
    s.touch(a);
    try testing.expectEqual(@as(u32, 2), s.version[@backingInt(a)]);
    try testing.expectEqual(@as(u32, 0), s.version[@backingInt(b)]);
    try testing.expect(s.dirty);
    // A later unchanged bump does not clear it.
    s.bump(b, false);
    try testing.expect(s.dirty);
}

test "bump: versions wrap instead of overflowing" {
    var s = fixture(1);
    const a = s.create();
    s.version[@backingInt(a)] = std.math.maxInt(u32);
    s.touch(a);
    try testing.expectEqual(@as(u32, 0), s.version[@backingInt(a)]);
}

test "create: past capacity, new signals share the last row" {
    var s = fixture(2);
    _ = s.create();
    const last = s.create();
    const extra = s.create();
    try testing.expectEqual(last, extra);
    try testing.expectEqual(@as(u32, 2), s.len);
}
