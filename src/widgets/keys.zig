//! Keys the widgets share: the scancodes that activate a focused widget and move inside a
//! composite one, and how many activations a frame's key events hold. Scancodes are USB HID
//! usage ids, as `focus.Keymap`'s defaults (which also has the arrows, Home and End).

const std = @import("std");
const Input = @import("../core/input.zig").Input;

/// The arrows, Home, End and Tab, as focus moves them (`focus.Keymap`).
pub const map: @import("../interact/focus.zig").Keymap = .{};
pub const enter: u8 = 0x28;
pub const space: u8 = 0x2c;
pub const page_up: u8 = 0x4b;
pub const page_down: u8 = 0x4e;
/// The arrows, Home and End by name, for widgets that read them themselves while focused.
pub const right = map.right;
pub const left = map.left;
pub const down = map.down;
pub const up = map.up;
pub const home = map.home;
pub const end = map.end;

/// How many of this frame's key events are `kind` (`.press` counts auto-repeat too) for key
/// `code` with no modifier held. Widgets read their keys this way while focused.
pub fn keyCount(in: *const Input, code: u8, kind: Input.Event.Kind) u32 {
    var n: u32 = 0;
    for (in.events) |e| {
        const k = (e.kind == kind) or (kind == .press and e.kind == .repeat);
        const plain = @as(u8, @bitCast(e.mods)) & 0xf == 0;
        n += @intFromBool(k and e.code == code and plain);
    }
    return n;
}

/// Presses of Enter or Space in this frame's key events (auto-repeat does not count).
pub fn activations(in: *const Input) u32 {
    var k: u32 = 0;
    for (in.events) |e| k += @intFromBool(e.kind == .press and (e.code == enter or e.code == space));
    return k;
}

test "keyCount: presses count repeats, a modifier held does not count" {
    const ev = [4]Input.Event{
        .{ .kind = .press, .code = right },                             .{ .kind = .repeat, .code = right },
        .{ .kind = .press, .code = right, .mods = .{ .shift = true } }, .{ .kind = .release, .code = right },
    };
    const in: Input = .{ .events = &ev };
    try std.testing.expectEqual(@as(u32, 2), keyCount(&in, right, .press));
    try std.testing.expectEqual(@as(u32, 1), keyCount(&in, right, .release));
}

test "activations: presses of Enter and Space; releases, repeats and other keys do not count" {
    const ev = [5]Input.Event{
        .{ .kind = .press, .code = enter },  .{ .kind = .release, .code = enter }, .{ .kind = .press, .code = space },
        .{ .kind = .repeat, .code = space }, .{ .kind = .press, .code = 0x04 },
    };
    const in: Input = .{ .events = &ev };
    try std.testing.expectEqual(@as(u32, 2), activations(&in));
}
