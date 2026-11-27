//! Keyframes: a value that passes through a list of stops at given times, each segment along
//! its own easing curve (tier 0). The list is caller-owned constant data; `sample` is a pure
//! function of time, with no search: every segment contributes its eased share of the change,
//! 1 for segments already past and 0 for those not reached, so the loop has no data-dependent
//! branch. `Frame.sequence` plays one from a tween row used as its clock.

const std = @import("std");
const simd = @import("../core/simd.zig");
const tweens = @import("tweens.zig");
const Ease = tweens.Ease;

/// An extern struct.
pub const Key = extern struct {
    /// Seconds from the start. Non-decreasing along the list.
    at: f32,
    value: f32,
    /// Curve of the segment that arrives at this key (unused for the first).
    ease: Ease = .linear,
};

/// Value of `keys` at `t` seconds: the first value before the first key, the last after the
/// last key. Asserts the list is not empty.
pub fn sample(keys: []const Key, t: f32) f32 {
    std.debug.assert(keys.len > 0);
    var v = keys[0].value;
    for (keys[0 .. keys.len - 1], keys[1..]) |k0, k1| {
        const span = k1.at - k0.at;
        // A zero-length segment is a step: all of it once t reaches it.
        const ramp = std.math.clamp((t - k0.at) / @max(span, 1e-9), 0, 1);
        const u = simd.selF(span > 0, ramp, simd.b2f(t >= k1.at));
        const e = tweens.ease_table[@backingInt(k1.ease)];
        v += (k1.value - k0.value) * (((e[0] * u + e[1]) * u + e[2]) * u);
    }
    return v;
}

/// Time of the last key: how long the sequence plays.
pub fn duration(keys: []const Key) f32 {
    return keys[keys.len - 1].at;
}

const testing = std.testing;

test "sample: passes through every key, eases between them, holds at both ends" {
    const keys = [_]Key{
        .{ .at = 0.1, .value = 0 },
        .{ .at = 0.3, .value = 10 },
        .{ .at = 0.3, .value = 20 }, // a step
        .{ .at = 0.5, .value = 5, .ease = .in_out },
    };
    try testing.expectEqual(@as(f32, 0), sample(&keys, 0));
    try testing.expectEqual(@as(f32, 0), sample(&keys, 0.1));
    try testing.expectApproxEqAbs(@as(f32, 5), sample(&keys, 0.2), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 20), sample(&keys, 0.3), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 12.5), sample(&keys, 0.4), 1e-4); // smoothstep midpoint
    try testing.expectApproxEqAbs(@as(f32, 5), sample(&keys, 0.5), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 5), sample(&keys, 9), 1e-4);
    try testing.expectEqual(@as(f32, 0.5), duration(&keys));
    const one = [_]Key{.{ .at = 0, .value = 3 }};
    try testing.expectEqual(@as(f32, 3), sample(&one, 1));
}
