//! Keys of the X11 shell: X keycodes to the USB HID scancodes `Input.Keys` and the widgets use,
//! and keycodes plus modifier state to keysyms and typed text, from the server's keyboard
//! mapping. Plain tables and functions, no OS.
//!
//! The keysyms come from the core protocol's GetKeyboardMapping, which XKB servers fill from the
//! active layout, with the group from the XKB state bits of each event; this is the core
//! protocol's keysym selection (shift, lock, num lock, two groups), not libxkbcommon's full
//! state machine. Text is produced for Latin-1 and Unicode keysyms (0x0100_0000 + code point),
//! which is what xkeyboard-config layouts emit for nearly every printable key, and for the
//! keypad; dead keys and Compose sequences belong to the input method (the IME commit).

const std = @import("std");

/// USB HID usage (keyboard page) of each Linux evdev key code; X keycodes on evdev and libinput
/// servers (and Xvfb) are the evdev code plus 8. 0 where HID has no key.
pub const hid_of_evdev: [256]u8 = blk: {
    var t: [256]u8 = @splat(0);
    const pairs = [_][2]u8{
        .{ 1, 0x29 },   .{ 2, 0x1e },   .{ 3, 0x1f },   .{ 4, 0x20 },   .{ 5, 0x21 },   .{ 6, 0x22 },
        .{ 7, 0x23 },   .{ 8, 0x24 },   .{ 9, 0x25 },   .{ 10, 0x26 },  .{ 11, 0x27 },  .{ 12, 0x2d },
        .{ 13, 0x2e },  .{ 14, 0x2a },  .{ 15, 0x2b },  .{ 16, 0x14 },  .{ 17, 0x1a },  .{ 18, 0x08 },
        .{ 19, 0x15 },  .{ 20, 0x17 },  .{ 21, 0x1c },  .{ 22, 0x18 },  .{ 23, 0x0c },  .{ 24, 0x12 },
        .{ 25, 0x13 },  .{ 26, 0x2f },  .{ 27, 0x30 },  .{ 28, 0x28 },  .{ 29, 0xe0 },  .{ 30, 0x04 },
        .{ 31, 0x16 },  .{ 32, 0x07 },  .{ 33, 0x09 },  .{ 34, 0x0a },  .{ 35, 0x0b },  .{ 36, 0x0d },
        .{ 37, 0x0e },  .{ 38, 0x0f },  .{ 39, 0x33 },  .{ 40, 0x34 },  .{ 41, 0x35 },  .{ 42, 0xe1 },
        .{ 43, 0x31 },  .{ 44, 0x1d },  .{ 45, 0x1b },  .{ 46, 0x06 },  .{ 47, 0x19 },  .{ 48, 0x05 },
        .{ 49, 0x11 },  .{ 50, 0x10 },  .{ 51, 0x36 },  .{ 52, 0x37 },  .{ 53, 0x38 },  .{ 54, 0xe5 },
        .{ 55, 0x55 },  .{ 56, 0xe2 },  .{ 57, 0x2c },  .{ 58, 0x39 },  .{ 59, 0x3a },  .{ 60, 0x3b },
        .{ 61, 0x3c },  .{ 62, 0x3d },  .{ 63, 0x3e },  .{ 64, 0x3f },  .{ 65, 0x40 },  .{ 66, 0x41 },
        .{ 67, 0x42 },  .{ 68, 0x43 },  .{ 69, 0x53 },  .{ 70, 0x47 },  .{ 71, 0x5f },  .{ 72, 0x60 },
        .{ 73, 0x61 },  .{ 74, 0x56 },  .{ 75, 0x5c },  .{ 76, 0x5d },  .{ 77, 0x5e },  .{ 78, 0x57 },
        .{ 79, 0x59 },  .{ 80, 0x5a },  .{ 81, 0x5b },  .{ 82, 0x62 },  .{ 83, 0x63 },  .{ 86, 0x64 },
        .{ 87, 0x44 },  .{ 88, 0x45 },  .{ 89, 0x87 },  .{ 96, 0x58 },  .{ 97, 0xe4 },  .{ 98, 0x54 },
        .{ 99, 0x46 },  .{ 100, 0xe6 }, .{ 102, 0x4a }, .{ 103, 0x52 }, .{ 104, 0x4b }, .{ 105, 0x50 },
        .{ 106, 0x4f }, .{ 107, 0x4d }, .{ 108, 0x51 }, .{ 109, 0x4e }, .{ 110, 0x49 }, .{ 111, 0x4c },
        .{ 113, 0x7f }, .{ 114, 0x81 }, .{ 115, 0x80 }, .{ 117, 0x67 }, .{ 119, 0x48 }, .{ 121, 0x85 },
        .{ 124, 0x89 }, .{ 125, 0xe3 }, .{ 126, 0xe7 }, .{ 127, 0x65 },
    };
    for (pairs) |p| t[p[0]] = p[1];
    // F13 to F24.
    for (0..12) |i| t[183 + i] = 0x68 + i;
    break :blk t;
};

/// HID scancode of X keycode `keycode`.
pub fn hid(keycode: u8) u8 {
    return if (keycode < 8) 0 else hid_of_evdev[keycode - 8];
}

/// X keycode of HID scancode `code`, or 0 (for tests that fake key presses).
pub fn keycodeOf(code: u8) u8 {
    for (hid_of_evdev, 0..) |h, e| {
        if (h == code and code != 0) return @intCast(e + 8);
    }
    return 0;
}

/// The first four keysyms of every keycode: group 1 levels 1 and 2, group 2 levels 1 and 2.
pub const Keymap = struct {
    syms: [256][4]u32 = @splat(@splat(0)),

    /// Fills the map from a GetKeyboardMapping reply for keycodes `first` onwards.
    pub fn load(k: *Keymap, reply: []const u8, first: u8) void {
        k.* = .{};
        const per: usize = reply[1];
        const n = std.mem.readInt(u32, reply[4..8], .little) / @max(per, 1);
        for (0..@min(n, 256 - @as(usize, first))) |i| {
            for (0..@min(per, 4)) |l| k.syms[first + i][l] = std.mem.readInt(u32, reply[32 + (i * per + l) * 4 ..][0..4], .little);
        }
    }

    /// The keysym of `keycode` under the modifier `state` of a key event (core protocol rules).
    pub fn keysym(k: *const Keymap, keycode: u8, state: u16) u32 {
        const row = k.syms[keycode];
        // XKB puts the group in bits 13 and 14; the core map has two.
        const group: usize = @intFromBool(((state >> 13) & 3) != 0 and (row[2] != 0 or row[3] != 0));
        var lower = row[group * 2];
        var upper = row[group * 2 + 1];
        if (upper == 0) {
            upper = upperOf(lower);
            lower = lowerOf(lower);
        }
        const shift = state & 1 != 0;
        const lock = state & 2 != 0;
        const numlock = state & 16 != 0;
        if (numlock and isKeypad(upper)) return if (shift) lower else upper;
        const caps = lock and lowerOf(lower) != upperOf(lower);
        return if (shift != caps) upper else lower;
    }
};

fn isKeypad(sym: u32) bool {
    return sym >= 0xff80 and sym <= 0xffbd;
}

/// Case pairs for the keysyms a core map leaves as one entry: ASCII and Latin-1 letters.
fn upperOf(sym: u32) u32 {
    return switch (sym) {
        'a'...'z' => sym - 32,
        0xe0...0xf6, 0xf8...0xfe => sym - 32,
        else => sym,
    };
}

fn lowerOf(sym: u32) u32 {
    return switch (sym) {
        'A'...'Z' => sym + 32,
        0xc0...0xd6, 0xd8...0xde => sym + 32,
        else => sym,
    };
}

/// The code point a keysym types, or 0 for keys that type nothing (arrows, modifiers, function
/// keys, Return and Tab, which widgets read as keys) and for legacy non-Latin-1 keysyms.
pub fn codepoint(sym: u32) u21 {
    return switch (sym) {
        0x20...0x7e, 0xa0...0xff => @intCast(sym),
        0x0100_00a0...0x0110_ffff => @intCast(sym - 0x0100_0000),
        0xff80 => ' ', // KP_Space
        0xffaa => '*',
        0xffab => '+',
        0xffac => ',',
        0xffad => '-',
        0xffae => '.',
        0xffaf => '/',
        0xffb0...0xffb9 => @intCast('0' + sym - 0xffb0),
        0xffbd => '=',
        else => 0,
    };
}

const testing = std.testing;

test "hid: X keycodes are evdev codes plus 8" {
    try testing.expectEqual(@as(u8, 0x04), hid(38)); // A
    try testing.expectEqual(@as(u8, 0x19), hid(55)); // V, for paste
    try testing.expectEqual(@as(u8, 0x2b), hid(23)); // Tab
    try testing.expectEqual(@as(u8, 0x2a), hid(22)); // Backspace
    try testing.expectEqual(@as(u8, 0xe1), hid(50)); // Left Shift
    try testing.expectEqual(@as(u8, 0x50), hid(113)); // Left arrow
    try testing.expectEqual(@as(u8, 0x68), hid(191)); // F13
    try testing.expectEqual(@as(u8, 0), hid(3));
    // Every mapped scancode goes back to its keycode.
    for (0..256) |c| {
        const code: u8 = @intCast(c);
        const k = keycodeOf(code);
        if (k != 0) try testing.expectEqual(code, hid(k));
    }
}

/// A GetKeyboardMapping reply for keycodes 38 ('a'), 10 ('1'/'!'), 87 (KP_1/KP_End) and 24
/// ('q' in group 1, Cyrillic 'й' in group 2, as an "us,ru" layout gives).
fn fakeMapping() [32 + 4 * 4 * 4]u8 {
    var r: [32 + 4 * 4 * 4]u8 = @splat(0);
    r[0] = 1;
    r[1] = 4;
    std.mem.writeInt(u32, r[4..8], 16, .little);
    const rows = [4][4]u32{ .{ 'a', 'A', 0, 0 }, .{ '1', '!', 0, 0 }, .{ 0xff9c, 0xffb1, 0, 0 }, .{ 'q', 0, 0x0100_0439, 0x0100_0419 } };
    for (rows, 0..) |row, i| for (row, 0..) |s, l| std.mem.writeInt(u32, r[32 + (i * 4 + l) * 4 ..][0..4], s, .little);
    return r;
}

test "Keymap.keysym: shift, caps lock, num lock and groups" {
    const r = fakeMapping();
    // Load as keycodes 38..41 and check each row through a remapped keymap.
    var k: Keymap = .{};
    k.load(&r, 38);
    try testing.expectEqual(@as(u32, 'a'), k.keysym(38, 0));
    try testing.expectEqual(@as(u32, 'A'), k.keysym(38, 1));
    try testing.expectEqual(@as(u32, 'A'), k.keysym(38, 2)); // caps lock
    try testing.expectEqual(@as(u32, 'a'), k.keysym(38, 3)); // both cancel
    try testing.expectEqual(@as(u32, '1'), k.keysym(39, 2)); // caps lock leaves digits
    try testing.expectEqual(@as(u32, '!'), k.keysym(39, 1));
    try testing.expectEqual(@as(u32, 0xff9c), k.keysym(40, 0)); // KP_End
    try testing.expectEqual(@as(u32, 0xffb1), k.keysym(40, 16)); // KP_1 with num lock
    try testing.expectEqual(@as(u32, 0xff9c), k.keysym(40, 17));
    // One keysym in the row: its case pair is the second level.
    try testing.expectEqual(@as(u32, 'q'), k.keysym(41, 0));
    try testing.expectEqual(@as(u32, 'Q'), k.keysym(41, 1));
    // XKB group 2.
    try testing.expectEqual(@as(u32, 0x0100_0439), k.keysym(41, 1 << 13));
    try testing.expectEqual(@as(u32, 0x0100_0419), k.keysym(41, (1 << 13) | 1));
    // Group 2 on a key without one falls back to group 1.
    try testing.expectEqual(@as(u32, 'a'), k.keysym(38, 1 << 13));
}

test "codepoint: Latin-1, Unicode and keypad keysyms type text, others do not" {
    try testing.expectEqual(@as(u21, 'a'), codepoint('a'));
    try testing.expectEqual(@as(u21, 0xe9), codepoint(0xe9)); // é
    try testing.expectEqual(@as(u21, 0x439), codepoint(0x0100_0439)); // й
    try testing.expectEqual(@as(u21, 0x1f600), codepoint(0x0101_f600));
    try testing.expectEqual(@as(u21, '7'), codepoint(0xffb7));
    try testing.expectEqual(@as(u21, 0), codepoint(0xff51)); // Left
    try testing.expectEqual(@as(u21, 0), codepoint(0xffe1)); // Shift_L
    try testing.expectEqual(@as(u21, 0), codepoint(0xff08)); // BackSpace: a key, not text
}
