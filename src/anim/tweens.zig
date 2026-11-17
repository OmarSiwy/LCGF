//! Tweens: values that move from where they are to a new target over a fixed duration along an
//! easing curve, all stepped together (tier 0). The time-based companion of the springs in
//! anims.zig, after Floem's transitions (duration plus easing). An easing is a row of a
//! coefficient table, so one SIMD loop steps every curve with no switch.

const std = @import("std");
const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Id = types.Id;
const none = types.none;

/// Easing curves, as rows of `ease_table`.
pub const Ease = enum(u8) { linear, in_quad, out_quad, in_out, in_cubic, out_cubic };

/// e(u) = a*u^3 + b*u^2 + c*u for u in [0, 1]. Every row has a + b + c = 1, so e(0) = 0 and
/// e(1) = 1 exactly. `in_out` is smoothstep.
pub const ease_table = [_][3]f32{
    .{ 0, 0, 1 }, // linear
    .{ 0, 1, 0 }, // in_quad: u^2
    .{ 0, -1, 2 }, // out_quad: 1 - (1 - u)^2
    .{ -2, 3, 0 }, // in_out: 3u^2 - 2u^3
    .{ 1, 0, 0 }, // in_cubic: u^3
    .{ 1, -3, 3 }, // out_cubic: 1 - (1 - u)^3
};
comptime {
    std.debug.assert(ease_table.len == @typeInfo(Ease).@"enum".field_names.len);
}

/// How a style property moves to a new value (`Frame.transition`), after Iced 0.14's
/// `Animation` (`quick`, `easing`): a duration and a curve. The default is a short smoothstep.
pub const Transition = struct {
    seconds: f32 = 0.15,
    ease: Ease = .in_out,
};

pub const Tweens = struct {
    len: u32 = 0,
    cap: u32,
    c: Columns,
    /// The row `slot` tries first: the one after the row it last returned, from row 0 after
    /// each `sweep` (as `Anims.next`). In a steady UI every `slot` is one compare, not a scan.
    next: u32 = 0,

    /// `simd.rows(cap)` rows each. Rows past `len` are kept zero (inert for `step`).
    pub const Columns = struct {
        id: []u32,
        /// This frame's value.
        x: []f32,
        from: []f32,
        to: []f32,
        /// Seconds since the current leg started; stops at `duration`.
        elapsed: []f32,
        duration: []f32,
        /// The leg's `ease_table` row, one column per coefficient (separate fields so
        /// `simd.compact` can move them).
        ease_a: []f32,
        ease_b: []f32,
        ease_c: []f32,
        /// Frame this tween was last asked for.
        seen: []u32,
        /// Tree row that was open when it was last asked for (`Frame.tween`, `Frame.sequence`),
        /// so `Frame.reuse` can tell the tweens inside a subtree from the rest.
        node: []u32,
    };

    pub fn init(carver: *mem.Carver, cap: u32) Tweens {
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }

    /// Row for `id`, created resting at `initial` on first use. Past `cap` new ids share the
    /// last row. O(1) when `id` sits at the row after the previous call's (see `next`), else a
    /// SIMD scan of the ids: one coarse, well-predicted branch per call, none per row.
    pub fn slot(t: *Tweens, id: Id, initial: f32) u32 {
        const c = &t.c;
        const k = @backingInt(id);
        const guess = @min(t.next, t.len -| 1);
        const hit = simd.andB(guess < t.len, c.id[guess] == k);
        if (hit) {
            t.next = guess + 1;
            return guess;
        }
        const found = simd.find(c.id, t.len, k);
        const is_new = found == none;
        const i = simd.selU(is_new, @min(t.len, t.cap - 1), found);
        t.len = @min(t.len + @intFromBool(is_new), t.cap);
        c.id[i] = k;
        c.x[i] = simd.selF(is_new, initial, c.x[i]);
        c.to[i] = simd.selF(is_new, initial, c.to[i]);
        c.from[i] = simd.selF(is_new, initial, c.from[i]);
        c.elapsed[i] = simd.selF(is_new, 0, c.elapsed[i]);
        c.duration[i] = simd.selF(is_new, 0, c.duration[i]);
        t.next = i + 1;
        return i;
    }

    /// Points row `i` at `to`. A new target starts a new leg from the current value, lasting
    /// `duration` seconds along `ease`; the same target leaves the running leg alone.
    pub fn retarget(t: *Tweens, i: u32, to: f32, duration: f32, ease: Ease) void {
        const c = &t.c;
        const fresh = to != c.to[i];
        c.from[i] = simd.selF(fresh, c.x[i], c.from[i]);
        c.to[i] = to;
        c.elapsed[i] = simd.selF(fresh, 0, c.elapsed[i]);
        c.duration[i] = simd.selF(fresh, @max(duration, 0), c.duration[i]);
        const e = ease_table[@backingInt(ease)];
        c.ease_a[i] = simd.selF(fresh, e[0], c.ease_a[i]);
        c.ease_b[i] = simd.selF(fresh, e[1], c.ease_b[i]);
        c.ease_c[i] = simd.selF(fresh, e[2], c.ease_c[i]);
    }

    /// Ends row `i`'s leg now, at its target (reduced motion: the end state, no movement).
    pub fn land(t: *Tweens, i: u32) void {
        t.c.elapsed[i] = t.c.duration[i];
        t.c.x[i] = t.c.to[i];
    }

    /// SIMD. Advances every tween by `dt` seconds. Returns the longest time any tween still
    /// needs; 0 means all have landed and no further frames are needed. A zero duration lands
    /// on the first step.
    pub fn step(t: *Tweens, dt: f32) f32 {
        const c = &t.c;
        const zero = simd.f(0);
        var left = zero;
        const n = simd.padded(t.len);
        var i: usize = 0;
        while (i < n) : (i += simd.lanes) {
            const duration = simd.loadF(c.duration, i);
            const elapsed = @min(simd.loadF(c.elapsed, i) + simd.f(dt), duration);
            // u = 1 when the leg is over, including a zero duration.
            const u = @select(f32, elapsed < duration, elapsed / @max(duration, simd.f(1e-9)), simd.f(1));
            const e = ((simd.loadF(c.ease_a, i) * u + simd.loadF(c.ease_b, i)) * u + simd.loadF(c.ease_c, i)) * u;
            const from = simd.loadF(c.from, i);
            const to = simd.loadF(c.to, i);
            // Landed rows store `to` exactly, not a rounded from + (to - from) * 1.
            simd.storeF(c.x, i, @select(f32, u < simd.f(1), from + (to - from) * e, to));
            simd.storeF(c.elapsed, i, elapsed);
            left = @max(left, duration - elapsed);
        }
        return @reduce(.Max, left);
    }

    /// Drops tweens nobody asked for in frame `frame`, by stream compaction (`simd.compact`).
    pub fn sweep(t: *Tweens, frame: u32) void {
        t.len = simd.compact(t.c, t.len, t.c.seen, frame);
        t.next = 0;
    }
};

const testing = std.testing;

fn fixture(comptime cap: u32) Tweens {
    const S = struct {
        var buffer: [11 * (simd.rows(cap) * 4 + mem.column_align)]u8 align(mem.column_align) = undefined;
    };
    var carver: mem.Carver = .{ .buf = &S.buffer };
    return .init(&carver, cap);
}

test "ease_table: every curve starts at 0, ends at 1 and never leaves [0, 1]" {
    for (ease_table) |e| {
        var last: f32 = 0;
        for (0..101) |k| {
            const u: f32 = @as(f32, @floatFromInt(k)) / 100;
            const v = ((e[0] * u + e[1]) * u + e[2]) * u;
            try testing.expect(v >= -1e-6 and v <= 1 + 1e-6 and v >= last - 1e-6);
            last = v;
        }
        try testing.expectEqual(@as(f32, 1), e[0] + e[1] + e[2]);
    }
}

test "step: a tween lands on its target after its duration, then is idle" {
    var t = fixture(4);
    const i = t.slot(Id.from("fade"), 0);
    t.retarget(i, 1, 0.25, .in_out);
    var frames: u32 = 0;
    while (t.step(1.0 / 64.0) > 0) : (frames += 1) {
        try testing.expect(t.c.x[i] > 0 and t.c.x[i] < 1);
    }
    // 0.25 s at 64 Hz: 15 frames in flight, the 16th lands.
    try testing.expectEqual(@as(u32, 15), frames);
    try testing.expectEqual(@as(f32, 1), t.c.x[i]);
    for (0..3) |_| try testing.expectEqual(@as(f32, 0), t.step(1.0 / 64.0));
    try testing.expectEqual(@as(f32, 1), t.c.x[i]);
}

test "retarget: the same target keeps the leg; a new one starts from where it is" {
    var t = fixture(4);
    const i = t.slot(Id.from("w"), 10);
    t.retarget(i, 10, 1, .linear);
    try testing.expectEqual(@as(f32, 0), t.step(0.1)); // already there
    t.retarget(i, 20, 1, .linear);
    _ = t.step(0.5);
    try testing.expectApproxEqAbs(@as(f32, 15), t.c.x[i], 1e-4);
    t.retarget(i, 20, 1, .linear); // asked again each frame: no restart
    _ = t.step(0.25);
    try testing.expectApproxEqAbs(@as(f32, 17.5), t.c.x[i], 1e-4);
    t.retarget(i, 0, 2, .linear); // reversed mid-way: from 17.5 down to 0 in 2 s
    _ = t.step(1);
    try testing.expectApproxEqAbs(@as(f32, 8.75), t.c.x[i], 1e-4);
    t.retarget(i, 3, 0, .linear); // zero duration: lands on the next step
    try testing.expectEqual(@as(f32, 0), t.step(1.0 / 60.0));
    try testing.expectEqual(@as(f32, 3), t.c.x[i]);
}

test "step: every row and curve as the scalar reference, across vectors and padding" {
    const n = 3 * simd.lanes + 1;
    var t = fixture(n);
    for (0..n) |k| {
        const i = t.slot(Id.from("t").with(@intCast(k)), @floatFromInt(k));
        t.retarget(i, 100, 0.05 * @as(f32, @floatFromInt(k + 1)), @fromBackingInt(@intCast(k % ease_table.len)));
        t.c.seen[i] = 1;
    }
    for (1..6) |s| {
        const most = t.step(0.03);
        const now: f32 = 0.03 * @as(f32, @floatFromInt(s));
        var want_left: f32 = 0;
        for (0..n) |k| {
            const d = 0.05 * @as(f32, @floatFromInt(k + 1));
            const u = @min(now / d, 1);
            const e = ease_table[k % ease_table.len];
            const v = ((e[0] * u + e[1]) * u + e[2]) * u;
            const from: f32 = @floatFromInt(k);
            try testing.expectApproxEqAbs(from + (100 - from) * v, t.c.x[k], 1e-3);
            want_left = @max(want_left, @max(d - now, 0));
        }
        try testing.expectApproxEqAbs(want_left, most, 1e-5);
    }
    for (n..simd.padded(n)) |r| try testing.expectEqual(@as(f32, 0), t.c.x[r]);
    t.sweep(2);
    try testing.expectEqual(@as(u32, 0), t.len);
}

test "slot: the row after the last one is tried first; any order still finds the right row" {
    var t = fixture(8);
    var rows: [5]u32 = undefined;
    for (&rows, 0..) |*r, k| r.* = t.slot(Id.from("t").with(@intCast(k)), @floatFromInt(k));
    for (rows, 0..) |r, k| t.c.seen[r] = @intCast(k);
    t.sweep(0); // keeps t0 only; next restarts at 0
    for (&rows, 0..) |*r, k| r.* = t.slot(Id.from("t").with(@intCast(k)), @floatFromInt(10 + k));
    try testing.expectEqual(@as(f32, 0), t.c.x[rows[0]]);
    for (rows[1..], 1..) |r, k| try testing.expectEqual(@as(f32, @floatFromInt(10 + k)), t.c.x[r]);
    const order = [_]u32{ 4, 1, 1, 0, 3, 2, 4 };
    for (order) |k| {
        const r = t.slot(Id.from("t").with(k), 99);
        try testing.expectEqual(rows[k], r);
        try testing.expectEqual(@backingInt(Id.from("t").with(k)), t.c.id[r]);
    }
    try testing.expectEqual(@as(u32, 5), t.len);
}
