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

    /// Fingerprint (FNV-1a) of a dependency list at its current versions. Equal stamps mean
    /// none of `deps` changed in between (barring a 64-bit collision). Order matters.
    pub fn stamp(s: *const Signals, deps: []const Signal) u64 {
        var h: u64 = 0xcbf2_9ce4_8422_2325;
        for (deps) |dep| {
            const i = @backingInt(dep);
            h = (h ^ ((@as(u64, i) << 32) | s.version[i])) *% 0x0000_0100_0000_01b3;
        }
        return h;
    }
};

/// A value paired with its signal. Nothing here the caller could not write with `Signals.bump`;
/// it exists so the common case is one call.
pub fn Cell(comptime T: type) type {
    return struct {
        value: T,
        signal: Signal,

        const Self = @This();

        pub fn init(signals: *Signals, value: T) Self {
            return .{ .value = value, .signal = signals.create() };
        }
        pub fn get(self: *const Self) T {
            return self.value;
        }
        /// Stores `value`; the signal is bumped only if it differs from the old one.
        pub fn set(self: *Self, signals: *Signals, value: T) void {
            const changed = !std.meta.eql(self.value, value);
            self.value = value;
            signals.bump(self.signal, changed);
        }
    };
}

/// A value computed from other signals (a memo), with its own signal and the stamp of the
/// inputs it was last computed from. There is no compute callback: the caller asks `stale` and,
/// if so, computes and `set`s, so the work runs at most once per change of its inputs:
///
///     if (total.stale(&signals, &deps)) total.set(&signals, &deps, a.get() + b.get());
///
/// Its own signal is bumped only when the new value differs, so a recompute that lands on the
/// same value leaves everything downstream valid.
pub fn Derived(comptime T: type) type {
    return struct {
        cell: Cell(T),
        /// `Signals.stamp` of the inputs at the last `set`.
        stamp: u64,

        const Self = @This();

        pub fn init(signals: *Signals, deps: []const Signal, value: T) Self {
            return .{ .cell = .init(signals, value), .stamp = signals.stamp(deps) };
        }
        pub fn get(self: *const Self) T {
            return self.cell.value;
        }
        pub fn signal(self: *const Self) Signal {
            return self.cell.signal;
        }
        /// An input changed since the last `set`.
        pub fn stale(self: *const Self, signals: *const Signals, deps: []const Signal) bool {
            return signals.stamp(deps) != self.stamp;
        }
        /// Stores a value computed from `deps` at their current versions.
        pub fn set(self: *Self, signals: *Signals, deps: []const Signal, value: T) void {
            self.stamp = signals.stamp(deps);
            self.cell.set(signals, value);
        }
    };
}

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

test "Cell: set bumps its signal only when the value changes" {
    var s = fixture(4);
    var n: Cell(u32) = .init(&s, 3);
    var p: Cell([2]f32) = .init(&s, .{ 1, 2 });
    try testing.expect(n.signal != p.signal);
    try testing.expectEqual(@as(u32, 3), n.get());

    n.set(&s, 3);
    p.set(&s, .{ 1, 2 });
    try testing.expect(!s.dirty);
    try testing.expectEqual(@as(u32, 0), s.version[@backingInt(n.signal)]);

    n.set(&s, 4);
    try testing.expectEqual(@as(u32, 4), n.get());
    try testing.expectEqual(@as(u32, 1), s.version[@backingInt(n.signal)]);
    try testing.expectEqual(@as(u32, 0), s.version[@backingInt(p.signal)]);
    try testing.expect(s.dirty);
}

test "stamp: changes with any dependency's version, and with the list" {
    var s = fixture(4);
    const a = s.create();
    const b = s.create();
    const ab = s.stamp(&.{ a, b });
    try testing.expectEqual(ab, s.stamp(&.{ a, b }));
    try testing.expect(ab != s.stamp(&.{a}));
    try testing.expect(ab != s.stamp(&.{ b, a }));
    try testing.expect(s.stamp(&.{}) != ab);
    s.bump(b, false);
    try testing.expectEqual(ab, s.stamp(&.{ a, b }));
    s.touch(b);
    try testing.expect(ab != s.stamp(&.{ a, b }));
}

test "Derived: recomputed once per input change; downstream sees only real changes" {
    var s = fixture(8);
    var a: Cell(i32) = .init(&s, 2);
    var b: Cell(i32) = .init(&s, 3);
    const deps = [_]Signal{ a.signal, b.signal };
    var sum: Derived(i32) = .init(&s, &deps, a.get() + b.get());
    // A second level reads the first through its signal.
    var sign: Derived(bool) = .init(&s, &.{sum.signal()}, sum.get() > 0);
    var computes: u32 = 0;

    const Step = struct {
        fn run(sg: *Signals, x: *Cell(i32), y: *Cell(i32), d: *Derived(i32), e: *Derived(bool), n: *u32) void {
            const in = [_]Signal{ x.signal, y.signal };
            if (d.stale(sg, &in)) {
                n.* += 1;
                d.set(sg, &in, x.get() + y.get());
            }
            const up = [_]Signal{d.signal()};
            if (e.stale(sg, &up)) e.set(sg, &up, d.get() > 0);
        }
    };

    Step.run(&s, &a, &b, &sum, &sign, &computes);
    try testing.expectEqual(@as(u32, 0), computes);

    a.set(&s, 4);
    b.set(&s, 1);
    Step.run(&s, &a, &b, &sum, &sign, &computes);
    Step.run(&s, &a, &b, &sum, &sign, &computes);
    try testing.expectEqual(@as(u32, 1), computes);
    try testing.expectEqual(@as(i32, 5), sum.get());

    // Inputs changed, sum did not: the second level keeps its stamp and its signal.
    const sign_version = s.version[@backingInt(sign.signal())];
    const sum_stamp = sign.stamp;
    a.set(&s, 3);
    b.set(&s, 2);
    Step.run(&s, &a, &b, &sum, &sign, &computes);
    try testing.expectEqual(@as(u32, 2), computes);
    try testing.expectEqual(sum_stamp, sign.stamp);

    a.set(&s, -9);
    Step.run(&s, &a, &b, &sum, &sign, &computes);
    try testing.expect(!sign.get());
    try testing.expectEqual(sign_version + 1, s.version[@backingInt(sign.signal())]);
}
