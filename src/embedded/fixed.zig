//! Signed Q12.4 coordinates for small panels. Keep geometry in eight bytes per box
//! and expand to the shared software shader's f32 inputs at its boundary.
const std = @import("std");

pub const Rect = [4]i16;
const factor: f32 = 16;

/// Round to the closest sixteenth and saturate off-screen edges (e.g. an open clip).
pub fn encode(rect: [4]f32) Rect {
    const f: @Vector(4, f32) = rect;
    const raw = @round(f * @as(@Vector(4, f32), @splat(factor)));
    return @as(@Vector(4, i16), @intFromFloat(@min(@max(raw, @as(@Vector(4, f32), @splat(-32768))), @as(@Vector(4, f32), @splat(32767)))));
}

pub fn decode(rect: Rect) [4]f32 {
    const f: @Vector(4, f32) = @floatFromInt(@as(@Vector(4, i16), rect));
    return f * @as(@Vector(4, f32), @splat(1.0 / factor));
}

test "embedded fixed coordinates saturate and preserve the fractional grid" {
    try std.testing.expectEqual(8, @sizeOf(Rect));
    try std.testing.expectEqual(Rect{ -32768, -8, 24, 32767 }, encode(.{ -1e6, -0.5, 1.49, 1e6 }));
    var i: i32 = -32768;
    while (i <= 32767) : (i += 1) {
        const r: Rect = @splat(@intCast(i));
        try std.testing.expectEqual(r, encode(decode(r)));
    }
}
