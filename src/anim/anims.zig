//! Anims: every spring in the UI as one table of columns, stepped together (tier 0). A spring is
//! a row keyed by widget id; the caller sets its target each frame and reads its position.
//! Ported from prototype/ui.zig ("Anims").

const std = @import("std");
const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Id = types.Id;
const none = types.none;

/// A damped spring's constants. The defaults settle in about a third of a second without
/// overshoot you can see.
pub const Spring = struct {
    stiffness: f32 = 170,
    damping: f32 = 26,
};

pub const Anims = struct {
    len: u32 = 0,
    cap: u32,
    c: Columns,
    /// The row `slot` tries first: the one after the row it last returned, from row 0 after
    /// each `sweep`. A frame asks for its springs in the same order every frame and `sweep`
    /// keeps that order, so in a steady UI every `slot` is one compare instead of a scan.
    next: u32 = 0,
    /// At least one new ID could not be reserved since the caller last cleared this flag.
    overflow: bool = false,

    /// `simd.rows(cap)` rows each. Padding through `padded(len)` stays inert. The last spare
    /// row is a discard destination, never part of `len` and never stepped or retained.
    pub const Columns = struct {
        id: []u32,
        x: []f32,
        v: []f32,
        target: []f32,
        stiffness: []f32,
        damping: []f32,
        /// Frame this spring was last asked for.
        seen: []u32,
        /// Tree row that was open when it was last asked for (`Frame.animate`), so
        /// `Frame.reuse` can tell the springs inside a subtree from the rest.
        node: []u32,
    };

    pub fn init(carver: *mem.Carver, cap: u32) Anims {
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }

    /// Checked reservation. Exhaustion reports NoSpace and leaves every live spring intact.
    pub fn reserve(a: *Anims, id: Id, initial: f32) error{NoSpace}!u32 {
        const i = a.slot(id, initial);
        return if (i < a.cap) i else error.NoSpace;
    }

    pub fn reserveScan(a: *Anims, id: Id, initial: f32) error{NoSpace}!u32 {
        const i = a.slotScan(id, initial);
        return if (i < a.cap) i else error.NoSpace;
    }

    /// Legacy row-returning operation. Past `cap`, new IDs receive an explicitly discarded
    /// spare row (index >= cap), and set overflow; no live row is overwritten. Prefer reserve
    /// when choosing a settled fallback. O(1) for the next expected ID, otherwise a SIMD scan.
    pub fn slot(a: *Anims, id: Id, initial: f32) u32 {
        const k = @backingInt(id);
        const guess = @min(a.next, a.len -| 1);
        const hit = simd.andB(guess < a.len, a.c.id[guess] == k);
        if (hit) {
            a.next = guess + 1;
            return guess;
        }
        const i = a.place(k, initial, simd.find(a.c.id, a.len, k));
        a.next = simd.selU(i < a.cap, i + 1, 0);
        return i;
    }

    /// `slot` by a SIMD scan only, with no branch on the ids: for callers that look springs up
    /// inside a per-row loop (`flip.apply`), where the branch census applies.
    pub fn slotScan(a: *Anims, id: Id, initial: f32) u32 {
        const k = @backingInt(id);
        return a.place(k, initial, simd.find(a.c.id, a.len, k));
    }

    /// The row for id `k`, given where it was `found` (or `none`): creates it if new.
    inline fn place(a: *Anims, k: u32, initial: f32, found: u32) u32 {
        const c = &a.c;
        const is_new = found == none;
        const spare: u32 = @intCast(c.x.len - 1);
        const available = a.len < a.cap;
        const i = simd.selU(is_new, simd.selU(available, a.len, spare), found);
        a.overflow = simd.orB(a.overflow, simd.andB(is_new, !available));
        a.len += @intFromBool(simd.andB(is_new, available));
        c.id[i] = k;
        // Select the row to write, not the value: a new spring's start goes to its row, an
        // existing one's to the last spare row, which no pass reads (it is past
        // `padded(cap)`). A select of a value loaded only for it becomes a branch on Zig 0.18
        // (docs/CHECKS.md), and `flip.apply` calls this once per registered node.
        const dst = simd.selU(is_new, i, spare);
        c.x[dst] = initial;
        c.v[dst] = 0;
        c.target[dst] = initial;
        c.stiffness[dst] = 0;
        c.damping[dst] = 0;
        c.seen[dst] = 0;
        c.node[dst] = none;
        return i;
    }

    /// Puts row `i` at its target, at rest (reduced motion: the end state, no movement).
    pub fn land(a: *Anims, i: u32) void {
        a.c.x[i] = a.c.target[i];
        a.c.v[i] = 0;
    }

    /// SIMD. Advances every spring by `dt` seconds (semi-implicit Euler, `dt` capped at 1/30 s
    /// so a stalled frame cannot blow up the integration). A spring within 1e-3 of its target
    /// and slower than 1e-2 per second snaps onto it and stops. Returns how much is still
    /// moving; 0 means every spring is at rest and no further frames are needed.
    pub fn step(a: *Anims, dt: f32) f32 {
        const h = @min(dt, 1.0 / 30.0);
        var motion = simd.f(0);
        const n = simd.padded(a.len);
        var i: usize = 0;
        while (i < n) : (i += simd.lanes)
            motion = @max(motion, stepVector(simd.lanes, &a.c, i, h));
        return @reduce(.Max, motion);
    }

    /// Drops springs nobody asked for in frame `frame` (`seen` differs). Branch-free stream
    /// compaction (`simd.compact`) keeps their order and zeroes the freed rows so `step` sees them inert.
    pub fn sweep(a: *Anims, frame: u32) void {
        a.len = simd.compact(a.c, a.len, a.c.seen, frame);
        a.next = 0;
    }
};

/// One full SIMD group or the exact final group of a compile-time table.
inline fn stepVector(comptime width: usize, c: anytype, i: usize, dt: f32) @Vector(width, f32) {
    const V = @Vector(width, f32);
    const h: V = @splat(dt);
    const zero: V = @splat(0);
    const x: V = c.x[i..][0..width].*;
    const v: V = c.v[i..][0..width].*;
    const target: V = c.target[i..][0..width].*;
    const k: V = c.stiffness[i..][0..width].*;
    const d: V = c.damping[i..][0..width].*;
    const v1 = v + (k * (target - x) - d * v) * h;
    const x1 = x + v1 * h;
    const left = @abs(target - x1);
    const speed = @abs(v1);
    const rest = (left < @as(V, @splat(1e-3))) & (speed < @as(V, @splat(1e-2)));
    c.x[i..][0..width].* = @select(f32, rest, target, x1);
    c.v[i..][0..width].* = @select(f32, rest, zero, v1);
    return @select(f32, rest, zero, left + speed);
}

/// A generated UI declares its animated bool and f32 target fields with
/// `pub const springs = .{ .volume = Spring{}, .glow = Spring{} };`.
/// Each declaration has an exact position, velocity and previous target. Constants
/// live in read-only tables. The ordinary runtime table uses the same integration step.
pub fn BoundSprings(comptime State: type) type {
    const decl = if (@hasDecl(State, "springs")) State.springs else .{};
    const names = @typeInfo(@TypeOf(decl)).@"struct".field_names;
    const n = names.len;
    const Coefficients = struct { stiffness: [n]f32, damping: [n]f32 };
    const config: Coefficients = comptime blk: {
        var k: [n]f32 = undefined;
        var d: [n]f32 = undefined;
        for (names, &k, &d) |name, *stiffness, *damping| {
            const T = @FieldType(State, name);
            if (T != f32 and T != bool) @compileError("spring target '" ++ name ++ "' needs an f32 or bool field");
            const spring: Spring = @field(decl, name);
            stiffness.* = spring.stiffness;
            damping.* = spring.damping;
        }
        break :blk .{ .stiffness = k, .damping = d };
    };
    return struct {
        const Self = @This();
        pub const count = n;
        const coefficients = config;
        x: [n]f32 = @splat(0),
        v: [n]f32 = @splat(0),
        target: [n]f32 = @splat(0),

        inline fn goal(state: *const State, comptime name: []const u8) f32 {
            const field_value = @field(state, name);
            return if (@TypeOf(field_value) == bool) simd.b2f(field_value) else field_value;
        }

        /// A declared field's position, or the raw target for a field drawn directly.
        pub fn value(s: *const Self, state: *const State, comptime name: []const u8) f32 {
            if (comptime std.meta.fieldIndex(@TypeOf(decl), name)) |slot| return s.x[slot];
            return goal(state, name);
        }

        pub fn pending(s: *const Self, state: *const State) bool {
            var active = false;
            inline for (names, 0..) |name, i|
                active = simd.orB(active, simd.orB(s.x[i] != goal(state, name), s.v[i] != 0));
            return active;
        }

        /// The runtime frame steps the previous targets, then receives this frame's target.
        pub fn frame(s: *Self, state: *const State, dt: f32, first: bool, reduced_motion: bool) void {
            if (n == 0) return;
            var next: [n]f32 = undefined;
            inline for (names, &next) |name, *t| t.* = goal(state, name);
            if (first or reduced_motion) {
                s.x = next;
                s.v = @splat(0);
            } else {
                const columns = .{ .x = &s.x, .v = &s.v, .target = &s.target, .stiffness = &coefficients.stiffness, .damping = &coefficients.damping };
                const h = @min(dt, 1.0 / 30.0);
                const full = n - n % simd.lanes;
                var i: usize = 0;
                while (i < full) : (i += simd.lanes) _ = stepVector(simd.lanes, columns, i, h);
                if (full != n) _ = stepVector(n - full, columns, full, h);
            }
            s.target = next;
        }
    };
}

const testing = std.testing;

/// Anims over a static buffer, for tests.
fn fixture(comptime cap: u32) Anims {
    const S = struct {
        var buffer: [8 * (simd.rows(cap) * 4 + mem.column_align)]u8 align(mem.column_align) = undefined;
    };
    var carver: mem.Carver = .{ .buf = &S.buffer };
    return .init(&carver, cap);
}

test "slot: one row per id, created at rest at its initial value" {
    var a = fixture(4);
    const glow = Id.from("glow");
    const i = a.slot(glow, 0.5);
    try testing.expectEqual(@as(u32, 1), a.len);
    try testing.expectEqual(@as(f32, 0.5), a.c.x[i]);
    try testing.expectEqual(@as(f32, 0), a.c.v[i]);

    // Later calls find the row and leave its state alone.
    a.c.x[i] = 0.75;
    a.c.v[i] = 2;
    try testing.expectEqual(i, a.slot(glow, 0));
    try testing.expectEqual(@as(f32, 0.75), a.c.x[i]);
    try testing.expectEqual(@as(f32, 2), a.c.v[i]);
    try testing.expectEqual(@as(u32, 1), a.len);

    const j = a.slot(Id.from("width"), 100);
    try testing.expect(i != j);
    try testing.expectEqual(@as(f32, 100), a.c.x[j]);
}

test "spring reservation exhaustion discards overflow without changing a live row" {
    var a = fixture(2);
    _ = a.slot(Id.from("a"), 1);
    const b = a.slot(Id.from("b"), 2);
    const c = a.slot(Id.from("c"), 3);
    try testing.expect(c >= simd.padded(a.cap));
    try testing.expectEqual(@as(u32, 2), a.len);
    try testing.expectEqual(@as(f32, 3), a.c.x[c]);
    try testing.expectEqual(@backingInt(Id.from("c")), a.c.id[c]);
    try testing.expectEqual(@backingInt(Id.from("b")), a.c.id[b]);
    try testing.expectEqual(@as(f32, 2), a.c.x[b]);
    try testing.expect(a.overflow);
    try testing.expectError(error.NoSpace, a.reserve(Id.from("d"), 4));
    try testing.expectError(error.NoSpace, a.reserveScan(Id.from("e"), 5));
    try testing.expectEqual(b, try a.reserve(Id.from("b"), 99));
    a.c.target[c] = 100;
    a.c.stiffness[c] = 170;
    try testing.expectEqual(@as(f32, 0), a.step(1.0 / 60.0));
    var empty = fixture(0);
    try testing.expectError(error.NoSpace, empty.reserve(.from("none"), 9));
    try testing.expectEqual(@as(u32, 0), empty.len);
}

/// A spring pulled from `from` to `to`: the row as `Frame.animate` leaves it.
fn aim(a: *Anims, id: Id, from: f32, to: f32, spring: Spring) u32 {
    const i = a.slot(id, from);
    a.c.target[i] = to;
    a.c.stiffness[i] = spring.stiffness;
    a.c.damping[i] = spring.damping;
    return i;
}

test "step: a spring lands on its target, then reports rest and stays idle" {
    var a = fixture(4);
    const i = aim(&a, Id.from("glow"), 0, 1, .{});
    var frames: u32 = 0;
    var last = a.c.x[i];
    while (a.step(1.0 / 60.0) > 0 and frames < 600) : (frames += 1) {
        // Critically damped or close to it: no visible overshoot, never moves backwards.
        try testing.expect(a.c.x[i] >= last - 1e-3 and a.c.x[i] < 1.01);
        last = a.c.x[i];
    }
    try testing.expect(frames > 5 and frames < 60);
    try testing.expectEqual(@as(f32, 1), a.c.x[i]);
    try testing.expectEqual(@as(f32, 0), a.c.v[i]);
    // At rest: further steps change nothing and keep reporting no motion.
    for (0..3) |_| try testing.expectEqual(@as(f32, 0), a.step(1.0 / 60.0));
    try testing.expectEqual(@as(f32, 1), a.c.x[i]);
}

test "step: every row is stepped as the scalar reference, across vectors and padding" {
    var a = fixture(3 * simd.lanes + 1);
    const n = 3 * simd.lanes + 1;
    var ref_x: [n]f32 = undefined;
    var ref_v: [n]f32 = undefined;
    for (0..n) |k| {
        const fk: f32 = @floatFromInt(k);
        const i = aim(&a, Id.from("s").with(@intCast(k)), fk, 10 - fk, .{ .stiffness = 100 + fk, .damping = 10 + fk });
        ref_x[i] = fk;
        ref_v[i] = 0;
    }
    try testing.expectEqual(@as(u32, n), a.len);
    for (0..5) |_| {
        const moving = a.step(0.1); // capped to 1/30
        var most: f32 = 0;
        for (0..n) |i| {
            const h: f32 = 1.0 / 30.0;
            const acc = a.c.stiffness[i] * (a.c.target[i] - ref_x[i]) - a.c.damping[i] * ref_v[i];
            ref_v[i] += acc * h;
            ref_x[i] += ref_v[i] * h;
            most = @max(most, @abs(a.c.target[i] - ref_x[i]) + @abs(ref_v[i]));
        }
        for (0..n) |i| {
            try testing.expectApproxEqRel(ref_x[i], a.c.x[i], 1e-5);
            try testing.expectApproxEqRel(ref_v[i], a.c.v[i], 1e-5);
        }
        try testing.expectApproxEqRel(most, moving, 1e-5);
    }
    // The padding past len stays inert.
    for (n..simd.padded(n)) |i| try testing.expectEqual(@as(f32, 0), a.c.x[i]);
}

test "step: an empty table is at rest" {
    var a = fixture(4);
    try testing.expectEqual(@as(f32, 0), a.step(1.0 / 60.0));
}

test "sweep: keeps the springs seen this frame, in order, and zeroes the rest" {
    var a = fixture(2 * simd.lanes);
    const n = 2 * simd.lanes;
    for (0..n) |k| {
        const i = aim(&a, Id.from("s").with(@intCast(k)), @floatFromInt(k), 0, .{});
        // Every third spring was asked for in frame 7; the others last in frame 6.
        a.c.seen[i] = @as(u32, 6) + @intFromBool(k % 3 == 0);
    }
    a.sweep(7);
    const kept = (n + 2) / 3;
    try testing.expectEqual(@as(u32, kept), a.len);
    for (0..kept) |r| {
        try testing.expectEqual(@as(f32, @floatFromInt(3 * r)), a.c.x[r]);
        try testing.expectEqual(@backingInt(Id.from("s").with(@intCast(3 * r))), a.c.id[r]);
        try testing.expectEqual(@as(u32, 7), a.c.seen[r]);
    }
    for (kept..n) |r| {
        try testing.expectEqual(@as(u32, 0), a.c.id[r]);
        try testing.expectEqual(@as(f32, 0), a.c.x[r]);
        try testing.expectEqual(@as(f32, 0), a.c.target[r]);
    }
    // A dropped id comes back as a new spring at its initial value.
    const back = a.slot(Id.from("s").with(1), 42);
    try testing.expectEqual(@as(u32, kept), back);
    try testing.expectEqual(@as(f32, 42), a.c.x[back]);
    // Sweeping a frame nobody asked for empties the table.
    a.sweep(8);
    try testing.expectEqual(@as(u32, 0), a.len);
    try testing.expectEqual(@as(f32, 0), a.step(1.0 / 60.0));
}

test "slot: the row after the last one is tried first; any order still finds the right row" {
    var a = fixture(8);
    var rows: [6]u32 = undefined;
    for (&rows, 0..) |*r, k| r.* = a.slot(Id.from("s").with(@intCast(k)), @floatFromInt(k));
    for (rows, 0..) |r, k| a.c.seen[r] = @intCast(k); // mark them apart for the checks below
    a.sweep(0); // keeps row 0 only; next restarts at 0
    try testing.expectEqual(@as(u32, 1), a.len);
    for (&rows, 0..) |*r, k| r.* = a.slot(Id.from("s").with(@intCast(k)), @floatFromInt(10 + k));
    // Same order as before: s0 found at row 0 with its old value, the rest recreated after it.
    try testing.expectEqual(@as(f32, 0), a.c.x[rows[0]]);
    for (rows[1..], 1..) |r, k| try testing.expectEqual(@as(f32, @floatFromInt(10 + k)), a.c.x[r]);
    // Out of order and repeated: every lookup still returns the id's own row.
    const order = [_]u32{ 5, 1, 1, 0, 4, 2, 3, 5 };
    for (order) |k| {
        const r = a.slot(Id.from("s").with(k), 99);
        try testing.expectEqual(rows[k], r);
        try testing.expectEqual(@backingInt(Id.from("s").with(k)), a.c.id[r]);
    }
    try testing.expectEqual(@as(u32, 6), a.len);
    // The same lookups by scan agree.
    for (0..6) |k| try testing.expectEqual(rows[k], a.slotScan(Id.from("s").with(@intCast(k)), 0));
}

test "comptime spring rows are exact and use runtime SIMD dynamics through the last lane" {
    const State = struct {
        a: f32 = 0,
        b: bool = false,
        c: f32 = 1,
        pub const springs = .{ .a = Spring{}, .b = Spring{ .damping = 12 }, .c = Spring{ .stiffness = 220 } };
    };
    const Bound = BoundSprings(State);
    try testing.expectEqual(0, @sizeOf(BoundSprings(struct {})));
    try testing.expectEqual([3]f32, @FieldType(Bound, "x"));
    try testing.expectEqual([3]f32, @FieldType(Bound, "v"));
    var bound: Bound = .{};
    var state: State = .{};
    bound.frame(&state, 0, true, false);
    var rt = fixture(3);
    inline for (.{ "a", "b", "c" }, 0..) |name, i| {
        _ = rt.slot(.hash(name), bound.x[i]);
        const cfg = @field(State.springs, name);
        rt.c.stiffness[i] = cfg.stiffness;
        rt.c.damping[i] = cfg.damping;
        rt.c.target[i] = bound.x[i];
    }
    state = .{ .a = 2, .b = true, .c = -3 };
    bound.frame(&state, 1.0 / 60.0, false, false);
    @memcpy(rt.c.target[0..3], &bound.target);
    for (0..180) |_| {
        _ = rt.step(1.0 / 60.0);
        bound.frame(&state, 1.0 / 60.0, false, false);
        try testing.expectEqualSlices(f32, rt.c.x[0..3], &bound.x);
        try testing.expectEqualSlices(f32, rt.c.v[0..3], &bound.v);
    }
    try testing.expect(!bound.pending(&state));
}

test "declared slider spring drives painted frames and honours reduced motion" {
    const w = @import("../widgets/base.zig");
    const theme = w.Theme{};
    const State = struct {
        volume: f32 = 0.25,
        pub const springs = .{ .volume = Spring{} };
    };
    const Ui = w.ComptimeUi(State, w.ct.slider(theme, .knob, .volume), theme);
    const input: @import("../core/input.zig").Input = .{};
    var ui: Ui = .{};
    const initial = ui.frame(&input);
    try testing.expectEqual(0.25, initial.tree.c.value[1]);
    try testing.expectEqual(types.inf, initial.wake);
    ui.signals.set(.volume, 1);
    try testing.expect(ui.needsAnimationFrame());
    const changed = ui.frame(&input);
    try testing.expectEqual(0, changed.wake);
    try testing.expectEqual(0.25, changed.tree.c.value[1]);
    const next = ui.frame(&input);
    try testing.expect(next.tree.c.value[1] > 0.25 and next.tree.c.value[1] < 1);
    const landed = ui.frameWithSettings(&input, &.{ .reduced_motion = true });
    try testing.expectEqual(1, landed.tree.c.value[1]);
    try testing.expectEqual(types.inf, landed.wake);
    try testing.expect(!ui.needsAnimationFrame());
}

test "comptime springs keep the host awake until they land" {
    const w = @import("../widgets/base.zig");
    const Spec = @import("../comptime/spec.zig").Spec;
    const Input = @import("../core/input.zig").Input;
    const State = struct {
        wireframe: bool = false,
        pub const springs = .{ .wireframe = Spring{} };
    };
    const Glow = struct {
        pub fn push(ui: anytype, comptime node: Spec, parent: u32, next: *u32, _: *const Input) void {
            var style = node.style;
            style.size[0] = .px(100 * ui.animated(.wireframe));
            _ = ui.tables.t.push(parent, .none, &style);
            next.* += 1;
        }
    };
    const Ui = w.ComptimeUi(State, .{ .kind = .col, .style = .{ .size = .{ .fit, .px(8) }, .fill = .rgb(255, 255, 255) }, .widget = Glow }, .{});
    const in: Input = .{ .viewport = .{ 800, 600 } };
    var ui: Ui = .{};
    _ = ui.frame(&in);
    _ = ui.frame(&in);
    try testing.expect(!ui.needsAnimationFrame());

    ui.signals.set(.wireframe, true);
    var frames: u32 = 0;
    var out = ui.frame(&in);
    try testing.expectEqual(0, out.wake);
    while (out.wake == 0 and frames < 600) : (frames += 1) {
        try testing.expect(ui.needsAnimationFrame());
        out = ui.frame(&in);
        try testing.expectEqual(100 * ui.animated(.wireframe), out.tree.c.size[0][1]);
    }
    try testing.expect(frames > 5 and frames < 600);
    try testing.expectEqual(1, ui.animated(.wireframe));
    try testing.expectEqual(types.inf, out.wake);
    try testing.expect(!ui.needsAnimationFrame());
}
