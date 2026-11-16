//! Keys the widgets share: the scancodes that activate a focused widget and move inside a
//! composite one, and how many activations a frame's key events hold. Scancodes are USB HID
//! usage ids, as `focus.Keymap`'s defaults (which also has the arrows, Home and End).

const std = @import("std");
const Input = @import("../core/input.zig").Input;

/// The arrows, Home, End and Tab, as focus moves them (`focus.Keymap`).
pub const map: @import("../interact/focus.zig").Keymap = .{};
pub const enter: u8 = 0x28;
pub const space: u8 = 0x2c;

/// Presses of Enter or Space in this frame's key events (auto-repeat does not count).
pub fn activations(in: *const Input) u32 {
    var k: u32 = 0;
    for (in.events) |e| k += @intFromBool(e.kind == .press and (e.code == enter or e.code == space));
    return k;
}

test "activations: presses of Enter and Space; releases, repeats and other keys do not count" {
    const ev = [5]Input.Event{
        .{ .kind = .press, .code = enter },  .{ .kind = .release, .code = enter }, .{ .kind = .press, .code = space },
        .{ .kind = .repeat, .code = space }, .{ .kind = .press, .code = 0x04 },
    };
    const in: Input = .{ .events = &ev };
    try std.testing.expectEqual(@as(u32, 2), activations(&in));
}
