//! Input: one plain struct per frame, filled by the host from any window layer.
//! Tier 0: plain data, no allocator, no I/O. Ported from prototype/ui.zig ("Input").

const std = @import("std");

/// Everything the core reads from the host for one frame. The host owns it and refills it
/// before each frame; the core only reads it.
pub const Input = struct {
    /// Seconds since the app started.
    time: f64 = 0,
    /// Seconds since the previous frame.
    dt: f32 = 1.0 / 60.0,
    /// Logical pixels.
    viewport: [2]f32 = .{ 800, 600 },
    /// Physical pixels per logical pixel.
    scale: f32 = 1,
    /// Logical pixels; `{ -1, -1 }` when the pointer is outside the window.
    pointer: [2]f32 = .{ -1, -1 },
    wheel: [2]f32 = .{ 0, 0 },
    /// UTF-8 typed this frame. Only read during the frame.
    text: []const u8 = "",
};

test "Input: defaults match the prototype" {
    const in: Input = .{};
    try std.testing.expectEqual(@as(f64, 0), in.time);
    try std.testing.expectEqual(@as(f32, 1.0 / 60.0), in.dt);
    try std.testing.expectEqual([2]f32{ 800, 600 }, in.viewport);
    try std.testing.expectEqual(@as(f32, 1), in.scale);
    try std.testing.expectEqual([2]f32{ -1, -1 }, in.pointer);
    try std.testing.expectEqual([2]f32{ 0, 0 }, in.wheel);
    try std.testing.expectEqualStrings("", in.text);
}

test "Input: host fills only the fields it has" {
    const typed = "hé";
    const in: Input = .{ .viewport = .{ 1024, 768 }, .scale = 2, .pointer = .{ 10, 20 }, .text = typed };
    try std.testing.expectEqual([2]f32{ 1024, 768 }, in.viewport);
    try std.testing.expectEqual(@as(f32, 2), in.scale);
    try std.testing.expectEqual([2]f32{ 10, 20 }, in.pointer);
    try std.testing.expectEqual(@as(usize, 3), in.text.len);
}
