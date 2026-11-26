//! Explicit motion, tier 0. Curves/tracks are borrowed data; Playback is caller-owned time.
//! Sampling never registers an animation or changes an unrelated property. `apply` returns
//! the same invalidation metadata as a non-animated style edit. Existing spring/tween APIs
//! remain useful shortcuts for their fixed-size rows.

const std = @import("std");
const types = @import("../core/types.zig");
const properties = @import("../style/properties.zig");
const colors = @import("../draw/color_math.zig");
const paths = @import("../draw/paths.zig");
const geometry = @import("../draw/geometry.zig");
const tweens = @import("tweens.zig");

pub const Error = error{ InvalidCurve, InvalidTiming, InvalidKeys, IncompatiblePath, NoSpace, EmptyPath };
pub const Stop = struct { at: f32, value: f32 };
pub const StepPosition = enum { jump_start, jump_end, jump_none, jump_both };
pub const Curve = union(enum) {
    standard: tweens.Ease,
    /// x controls are in 0..1; y controls may overshoot. Endpoints are (0,0),(1,1).
    cubic: [4]f32,
    steps: struct { count: u32, position: StepPosition = .jump_end },
    /// Ordered stops with at in 0..1. End values hold outside the stop range.
    linear: []const Stop,
    /// Uniform samples including the endpoints. At least two values.
    samples: []const f32,

    pub fn validate(curve: Curve) Error!void {
        switch (curve) {
            .standard => {},
            .cubic => |v| {
                for (v) |x| if (!std.math.isFinite(x)) return error.InvalidCurve;
                if (v[0] < 0 or v[0] > 1 or v[2] < 0 or v[2] > 1) return error.InvalidCurve;
            },
            .steps => |s| if (s.count == 0 or (s.count < 2 and s.position == .jump_none)) return error.InvalidCurve,
            .linear => |stops| {
                if (stops.len == 0) return error.InvalidCurve;
                var prev: f32 = 0;
                for (stops) |s| {
                    if (!std.math.isFinite(s.at) or !std.math.isFinite(s.value) or s.at < prev or s.at > 1) return error.InvalidCurve;
                    prev = s.at;
                }
            },
            .samples => |values| {
                if (values.len < 2) return error.InvalidCurve;
                for (values) |v| if (!std.math.isFinite(v)) return error.InvalidCurve;
            },
        }
    }

    /// Validate authoring data once; evaluation is bounded (24 bisection steps for Bézier).
    pub fn at(curve: Curve, fraction: f32) f32 {
        const t = std.math.clamp(fraction, 0, 1);
        return switch (curve) {
            .standard => |e| blk: {
                const c = tweens.ease_table[@backingInt(e)];
                break :blk ((c[0] * t + c[1]) * t + c[2]) * t;
            },
            .cubic => |c| blk: {
                if (t == 0 or t == 1) break :blk t;
                var lo: f32 = 0;
                var hi: f32 = 1;
                for (0..24) |_| {
                    const u = (lo + hi) * 0.5;
                    if (bezier(c[0], c[2], u) < t) lo = u else hi = u;
                }
                break :blk bezier(c[1], c[3], (lo + hi) * 0.5);
            },
            .steps => |s| blk: {
                const n: f32 = @floatFromInt(s.count);
                const start: f32 = if (s.position == .jump_start or s.position == .jump_both) 1 else 0;
                const denom = n + @as(f32, if (s.position == .jump_both) 1 else if (s.position == .jump_none) -1 else 0);
                break :blk std.math.clamp((@floor(t * n) + start) / denom, 0, 1);
            },
            .linear => |stops| blk: {
                var value = stops[0].value;
                for (stops[1..], stops[0 .. stops.len - 1]) |b, a| {
                    const u = if (a.at == b.at) @as(f32, @floatFromInt(@intFromBool(t >= b.at))) else std.math.clamp((t - a.at) / (b.at - a.at), 0, 1);
                    value += (b.value - a.value) * u;
                }
                break :blk value;
            },
            .samples => |values| blk: {
                const x = t * @as(f32, @floatFromInt(values.len - 1));
                const i: usize = @min(@as(usize, @intFromFloat(x)), values.len - 2);
                break :blk values[i] + (values[i + 1] - values[i]) * (x - @as(f32, @floatFromInt(i)));
            },
        };
    }
};

fn bezier(a: f32, b: f32, t: f32) f32 {
    const v = 1 - t;
    return 3 * v * v * t * a + 3 * v * t * t * b + t * t * t;
}

pub const Direction = enum { normal, reverse, alternate, alternate_reverse };
pub const Fill = enum { none, backwards, forwards, both };
pub const Hidden = enum { continue_playing, pause, finish, cancel };
pub const Timing = struct {
    duration: f64,
    delay: f64 = 0,
    /// Nonnegative, fractional iterations allowed; infinity is explicit endless playback.
    iterations: f64 = 1,
    direction: Direction = .normal,
    fill: Fill = .none,
    essential: bool = false,

    pub fn validate(timing: Timing) Error!void {
        if (!std.math.isFinite(timing.duration) or timing.duration < 0 or !std.math.isFinite(timing.delay) or
            std.math.isNan(timing.iterations) or timing.iterations < 0) return error.InvalidTiming;
    }
};

pub const Sample = struct {
    /// Null before/after the active interval when the requested fill does not retain a value.
    progress: ?f32,
    iteration: u64 = 0,
    active: bool = false,
    complete: bool = false,
};

pub const Playback = struct {
    timing: Timing,
    time: f64 = 0,
    rate: f64 = 1,
    paused: bool = false,
    cancelled: bool = false,
    finished: bool = false,
    /// Completion edge for this advance/seek; consumers may enqueue their own command.
    completed_now: bool = false,

    pub fn init(timing: Timing) Error!Playback {
        try timing.validate();
        return .{ .timing = timing };
    }

    pub fn seek(playback: *Playback, time: f64) Error!Sample {
        if (!std.math.isFinite(time)) return error.InvalidTiming;
        const before = playback.finished;
        playback.time = time;
        playback.cancelled = false;
        playback.finished = playback.reachedEnd();
        playback.completed_now = !before and playback.finished;
        return playback.sample();
    }

    pub fn advance(playback: *Playback, dt: f64, visible: bool, hidden: Hidden, reduced_motion: bool) Error!Sample {
        if (!std.math.isFinite(dt) or dt < 0 or !std.math.isFinite(playback.rate)) return error.InvalidTiming;
        playback.completed_now = false;
        if (playback.cancelled) return playback.sample();
        if (reduced_motion and !playback.timing.essential) return playback.finish();
        if (!visible) switch (hidden) {
            .continue_playing => {},
            .pause => return playback.sample(),
            .finish => return playback.finish(),
            .cancel => {
                playback.cancel();
                return playback.sample();
            },
        };
        if (!playback.paused and !playback.finished) return playback.seek(playback.time + dt * playback.rate);
        return playback.sample();
    }

    pub fn pause(playback: *Playback) void {
        playback.paused = true;
    }
    pub fn play(playback: *Playback) void {
        playback.paused = false;
    }
    pub fn cancel(playback: *Playback) void {
        playback.cancelled = true;
        playback.completed_now = false;
    }

    pub fn restart(playback: *Playback) void {
        playback.time = if (playback.rate < 0) playback.endTime() else 0;
        playback.paused = false;
        playback.cancelled = false;
        playback.finished = false;
        playback.completed_now = false;
    }

    pub fn reverse(playback: *Playback) void {
        playback.rate = if (playback.rate == 0) -1 else -playback.rate;
        playback.finished = false;
        playback.cancelled = false;
    }

    /// An endless decorative animation lands at the end of its current iteration.
    pub fn finish(playback: *Playback) Sample {
        const was_finished = playback.finished;
        playback.time = if (playback.rate < 0) 0 else playback.endTime();
        playback.finished = true;
        playback.cancelled = false;
        playback.completed_now = !was_finished;
        var value = playback.sample();
        // Explicit finish/reduced-motion always has a useful settled value, even fill:none.
        if (value.progress == null) value.progress = playback.endpoint(playback.rate >= 0);
        value.complete = true;
        value.active = false;
        return value;
    }

    fn endTime(playback: *const Playback) f64 {
        const count = if (std.math.isInf(playback.timing.iterations))
            @floor(@max(0, playback.time - playback.timing.delay) / @max(playback.timing.duration, 1e-20)) + 1
        else
            playback.timing.iterations;
        return playback.timing.delay + playback.timing.duration * count;
    }

    fn reachedEnd(playback: *const Playback) bool {
        return if (playback.rate < 0) playback.time <= 0 else !std.math.isInf(playback.timing.iterations) and playback.time >= playback.endTime();
    }

    fn directed(playback: *const Playback, iteration: u64, fraction: f64) f32 {
        const reversed = switch (playback.timing.direction) {
            .normal => false,
            .reverse => true,
            .alternate => iteration % 2 == 1,
            .alternate_reverse => iteration % 2 == 0,
        };
        return @floatCast(if (reversed) 1 - fraction else fraction);
    }

    fn endpoint(playback: *const Playback, end: bool) f32 {
        if (!end) return playback.directed(0, 0);
        const total = if (std.math.isInf(playback.timing.iterations)) @max(1, @ceil((playback.endTime() - playback.timing.delay) / @max(playback.timing.duration, 1e-20))) else playback.timing.iterations;
        if (total == 0) return playback.directed(0, 0);
        const index = @max(0, @ceil(total) - 1);
        return playback.directed(toIteration(index), total - index);
    }

    pub fn sample(playback: *const Playback) Sample {
        if (playback.cancelled) return .{ .progress = null };
        const elapsed = playback.time - playback.timing.delay;
        if (elapsed < 0) return .{ .progress = if (playback.timing.fill == .backwards or playback.timing.fill == .both) playback.endpoint(false) else null };
        if (playback.timing.duration == 0 or (!std.math.isInf(playback.timing.iterations) and elapsed >= playback.timing.duration * playback.timing.iterations)) {
            return .{ .progress = if (playback.timing.fill == .forwards or playback.timing.fill == .both) playback.endpoint(true) else null, .complete = true };
        }
        const total = elapsed / playback.timing.duration;
        const iteration = toIteration(@floor(total));
        return .{ .progress = playback.directed(iteration, total - @floor(total)), .iteration = iteration, .active = true };
    }

    /// Positive seconds until an active/delayed clock needs progress; infinity when idle.
    pub fn wake(playback: *const Playback) f32 {
        if (playback.cancelled or playback.finished or playback.paused or playback.rate == 0) return types.inf;
        if (playback.time < playback.timing.delay and playback.rate > 0) return @floatCast((playback.timing.delay - playback.time) / playback.rate);
        return 0;
    }
};

fn toIteration(v: f64) u64 {
    return @intFromFloat(@min(@max(0, v), @as(f64, @floatFromInt(std.math.maxInt(u64) - 4096))));
}

pub fn Key(comptime property: properties.Property) type {
    return struct { at: f32, value: properties.Type(property), curve: Curve = .{ .standard = .linear } };
}

pub fn interpolate(comptime property: properties.Property, a: properties.Type(property), b: properties.Type(property), t: f32, color: colors.Interpolation) properties.Type(property) {
    return switch (comptime properties.kind(property)) {
        .number => a + (b - a) * t,
        .color => @bitCast(colors.pack(colors.mix(colors.fromColor(a), colors.fromColor(b), t, color))),
        .vector2, .vector4, .matrix => blk: {
            var out: properties.Type(property) = undefined;
            inline for (0..out.len) |i| out[i] = a[i] + (b[i] - a[i]) * t;
            break :blk out;
        },
        .size => if (a.kind == b.kind) .{ .kind = a.kind, .v = a.v + (b.v - a.v) * t } else if (t < 0.5) a else b,
        else => if (t < 0.5) a else b,
    };
}

pub fn sample(comptime property: properties.Property, keys: []const Key(property), progress: f32, color: colors.Interpolation) Error!properties.Type(property) {
    if (keys.len == 0 or !std.math.isFinite(progress)) return error.InvalidKeys;
    var previous: f32 = 0;
    for (keys) |key| {
        if (!std.math.isFinite(key.at) or key.at < previous or key.at > 1) return error.InvalidKeys;
        try key.curve.validate();
        previous = key.at;
    }
    var a = keys[0];
    if (progress < a.at) return a.value;
    for (keys[1..]) |b| {
        if (progress < b.at) return interpolate(property, a.value, b.value, b.curve.at((progress - a.at) / (b.at - a.at)), color);
        a = b;
    }
    return a.value;
}

/// Apply exactly one property and report its invalidation domains. Paint-only tracks do not
/// force text shaping or layout. A null playback sample leaves the caller's base style intact.
pub fn apply(comptime property: properties.Property, computed: *properties.Computed, keys: []const Key(property), value: Sample, color: colors.Interpolation) Error!properties.Invalidation {
    const fraction = value.progress orelse return .{};
    properties.write(property, computed, try sample(property, keys, fraction, color));
    return properties.metadata(property).invalidates;
}

pub const PathSample = struct {
    position: [2]f32,
    tangent: [2]f32,
    pub fn matrix(value: PathSample, anchor: [2]f32, rotate: bool, offset: f32) [6]f32 {
        const angle = (if (rotate) std.math.atan2(value.tangent[1], value.tangent[0]) else @as(f32, 0)) + offset;
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ c, s, -s, c, value.position[0] - c * anchor[0] + s * anchor[1], value.position[1] - s * anchor[0] - c * anchor[1] };
    }
};

/// Distance along flattened contours; a contour break never creates a connecting segment.
/// Flattening tolerance is chosen by the caller with paths.flatten. Closed seams participate.
pub fn alongPath(path: *const paths.Polyline, distance: f32) Error!PathSample {
    if (path.points == 0 or path.contours == 0 or !std.math.isFinite(distance)) return error.EmptyPath;
    var left = @max(0, distance);
    var start: u32 = 0;
    var last: PathSample = .{ .position = .{ path.x[0], path.y[0] }, .tangent = .{ 1, 0 } };
    for (path.end[0..path.contours], path.closed[0..path.contours]) |end, closed| {
        const count = end - start;
        if (count < 2) {
            start = end;
            continue;
        }
        const segments = count - 1 + @intFromBool(closed);
        for (0..segments) |j| {
            const a = start + j;
            const b = start + (j + 1) % count;
            const dx = path.x[b] - path.x[a];
            const dy = path.y[b] - path.y[a];
            const length = @sqrt(dx * dx + dy * dy);
            if (length == 0) continue;
            const t = @min(left / length, 1);
            last = .{ .position = .{ path.x[a] + dx * t, path.y[a] + dy * t }, .tangent = .{ dx / length, dy / length } };
            if (left <= length) return last;
            left -= length;
        }
        start = end;
    }
    return last;
}

/// Compatible path interpolation. On a different verb topology the caller explicitly picks
/// a discrete path or crossfade; no hidden resampling changes shape or winding.
pub fn morph(a: *const paths.Path, b: *const paths.Path, t: f32, out: *paths.Path) Error!void {
    if (a.verbs != b.verbs or a.points != b.points or !std.mem.eql(paths.Verb, a.verb[0..a.verbs], b.verb[0..b.verbs])) return error.IncompatiblePath;
    if (out.verb.len < a.verbs or out.x.len < a.points or out.y.len < a.points) return error.NoSpace;
    @memcpy(out.verb[0..a.verbs], a.verb[0..a.verbs]);
    for (0..a.points) |i| {
        out.x[i] = a.x[i] + (b.x[i] - a.x[i]) * t;
        out.y[i] = a.y[i] + (b.y[i] - a.y[i]) * t;
    }
    out.verbs = a.verbs;
    out.points = a.points;
}

/// FLIP matrix mapping the newly laid-out box to an interpolated old/new visual box. Applying
/// this as a transform preserves layout's final constraints while hit geometry follows paint.
pub fn layoutTransform(before: [4]f32, after: [4]f32, progress: f32) [6]f32 {
    const t = std.math.clamp(progress, 0, 1);
    var rect: [4]f32 = undefined;
    inline for (0..4) |k| rect[k] = before[k] + (after[k] - before[k]) * t;
    const sx = if (after[2] != after[0]) (rect[2] - rect[0]) / (after[2] - after[0]) else 1;
    const sy = if (after[3] != after[1]) (rect[3] - rect[1]) / (after[3] - after[1]) else 1;
    return .{ sx, 0, 0, sy, rect[0] - sx * after[0], rect[1] - sy * after[1] };
}

test "caller-owned playback handles delay alternation pause reverse and reduced motion" {
    var clock = try Playback.init(.{ .duration = 2, .delay = 1, .iterations = 2.5, .direction = .alternate, .fill = .both });
    try std.testing.expectEqual(@as(?f32, 0), clock.sample().progress);
    try std.testing.expectEqual(@as(f32, 1), clock.wake());
    try std.testing.expectEqual(@as(?f32, 0.5), (try clock.advance(2, true, .pause, false)).progress);
    clock.pause();
    _ = try clock.advance(9, true, .pause, false);
    try std.testing.expectEqual(@as(f64, 2), clock.time);
    clock.play();
    _ = try clock.seek(4);
    try std.testing.expectEqual(@as(?f32, 0.5), clock.sample().progress);
    clock.reverse();
    _ = try clock.advance(1, true, .pause, false);
    try std.testing.expectEqual(@as(?f32, 1), clock.sample().progress);
    clock.reverse();
    const settled = try clock.advance(0, true, .pause, true);
    try std.testing.expectEqual(@as(?f32, 0.5), settled.progress);
    try std.testing.expect(settled.complete and clock.completed_now);
    clock.cancel();
    try std.testing.expectEqual(@as(?f32, null), clock.sample().progress);
}

test "extended easing and typed tracks drive real style properties" {
    const curve: Curve = .{ .cubic = .{ 0.42, 0, 0.58, 1 } };
    try curve.validate();
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), curve.at(0.5), 1e-5);
    const steps: Curve = .{ .steps = .{ .count = 4 } };
    try std.testing.expectEqual(@as(f32, 0.25), steps.at(0.49));
    const keys = [_]Key(.width){ .{ .at = 0, .value = .px(10) }, .{ .at = 1, .value = .px(30), .curve = curve } };
    var computed: properties.Computed = .{};
    const dirty = try apply(.width, &computed, &keys, .{ .progress = 0.5 }, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 20), computed.box.size[0].v, 1e-4);
    try std.testing.expect(dirty.layout and dirty.hit);
    const fill = [_]Key(.fill){ .{ .at = 0, .value = .black }, .{ .at = 1, .value = .white } };
    const paint = try apply(.fill, &computed, &fill, .{ .progress = 0.5 }, .{ .space = .linear_srgb });
    try std.testing.expect(computed.box.fill.r > 180 and computed.box.fill.r < 190);
    try std.testing.expect(paint.paint and !paint.measure and !paint.layout);
}

test "path traversal morphing and size FLIP consume existing geometry" {
    var x = [_]f32{ 0, 10, 10 };
    var y = [_]f32{ 0, 0, 10 };
    var ends = [_]u32{3};
    var closed = [_]bool{false};
    const path: paths.Polyline = .{ .x = &x, .y = &y, .end = &ends, .closed = &closed, .points = 3, .contours = 1 };
    const at = try alongPath(&path, 15);
    try std.testing.expectEqual([2]f32{ 10, 5 }, at.position);
    try std.testing.expectEqual([2]f32{ 0, 1 }, at.tangent);
    const box: [4]f32 = .{ 20, 20, 60, 60 };
    const old: [4]f32 = .{ 0, 0, 20, 20 };
    try std.testing.expectEqual(old, geometry.transformRect(box, layoutTransform(old, box, 0)));
    var a_buf: paths.TestBuffers(4, 8) = .{};
    var b_buf: paths.TestBuffers(4, 8) = .{};
    var out_buf: paths.TestBuffers(4, 8) = .{};
    var a = a_buf.path();
    var b = b_buf.path();
    var out = out_buf.path();
    a.moveTo(0, 0);
    a.lineTo(10, 10);
    b.moveTo(10, 0);
    b.lineTo(30, 20);
    try morph(&a, &b, 0.5, &out);
    try std.testing.expectEqualSlices(f32, &.{ 5, 20 }, out.x[0..out.points]);
    b.close();
    try std.testing.expectError(error.IncompatiblePath, morph(&a, &b, 0.5, &out));
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Playback);
    std.testing.refAllDecls(Curve);
}
