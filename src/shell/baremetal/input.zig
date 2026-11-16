//! Touch and encoder input for bare-metal boards, after LVGL's input device model (docs.lvgl.io
//! 9.5, "Requirements"): the board reads its devices once per frame into a `Sample`, plain data,
//! and `Reader` turns samples into the `Input` the core reads.
//!
//! - A touch panel (one finger) drives the pointer and the left button, as LVGL's pointer device
//!   does. A touch panel has no hover: the pointer is where the finger is while it is down,
//!   stays where it lifted for that one frame (so the release lands on what was pressed), then
//!   leaves the window.
//! - A rotary encoder with a push button moves keyboard focus and activates: each detent is a
//!   Tab press (Shift+Tab turning back), and the button is Enter (`focus.Keymap`, the keys the
//!   widgets read).
//!
//! `sample` maps a recording (`input.Replay`) onto these devices, so a recording drives a board
//! in tests and in the simulator: a finger or the left button is the touch, wheel notches are
//! encoder detents and the middle button is its push button (the mapping of LVGL's desktop
//! simulators).

const std = @import("std");
const Input = @import("../../core/input.zig").Input;
const Keymap = @import("../../interact/focus.zig").Keymap;

/// One finger on the panel, in physical pixels.
pub const Touch = struct {
    pos: [2]f32 = .{ 0, 0 },
    down: bool = false,
};

/// A rotary encoder: detents turned since the last sample (positive moves focus forward), and
/// whether its button is held.
pub const Encoder = struct {
    steps: i32 = 0,
    down: bool = false,
};

/// What a board's devices read for one frame.
pub const Sample = struct {
    touch: Touch = .{},
    encoder: Encoder = .{},
};

/// Detents one frame turns into key events; a faster turn is clamped.
pub const max_steps = 8;

/// The scancode of the encoder's button: Enter (USB HID), what `widgets/keys.zig` activates on.
pub const enter: u8 = 0x28;

/// Turns samples into `Input`, keeping the little it needs from the frame before.
pub const Reader = struct {
    keymap: Keymap = .{},
    /// The finger was down last frame, at `at` (logical pixels).
    touched: bool = false,
    at: [2]f32 = .{ -1, -1 },
    pushed: bool = false,
    /// Backs `Input.events`; valid until the next `read`.
    events: [max_steps + 1]Input.Event = undefined,

    /// Writes `s` into `in`: the pointer, the left button, Enter in `keys`, and this frame's key
    /// events. `in.scale` must already be set. Other fields are left as they are.
    pub fn read(r: *Reader, s: Sample, in: *Input) void {
        const p: [2]f32 = .{ s.touch.pos[0] / in.scale, s.touch.pos[1] / in.scale };
        const away: [2]f32 = .{ -1, -1 };
        in.pointer = if (s.touch.down) p else if (r.touched) r.at else away;
        in.buttons.left = s.touch.down;
        r.touched = s.touch.down;
        r.at = p;

        const steps = std.math.clamp(s.encoder.steps, -max_steps, max_steps);
        var n: usize = 0;
        for (0..@abs(steps)) |_| {
            r.events[n] = .{ .kind = .press, .code = r.keymap.tab, .mods = .{ .shift = steps < 0 } };
            n += 1;
        }
        if (s.encoder.down != r.pushed) {
            r.events[n] = .{ .kind = if (s.encoder.down) .press else .release, .code = enter };
            n += 1;
        }
        r.pushed = s.encoder.down;
        in.keys = .{};
        if (s.encoder.down) in.keys.press(enter);
        in.events = r.events[0..n];
    }
};

/// The devices a recorded frame stands for: the first finger, else the pointer with the left
/// button, as the touch (scaled to physical pixels); the vertical wheel, rounded to whole
/// notches, as encoder detents; the middle button as the encoder's button.
pub fn sample(in: *const Input) Sample {
    const finger = in.contacts.len > 0;
    const pos = if (finger) in.contacts[0].pos else in.pointer;
    return .{
        .touch = .{ .pos = .{ pos[0] * in.scale, pos[1] * in.scale }, .down = if (finger) in.contacts[0].down else in.buttons.left },
        .encoder = .{ .steps = @intFromFloat(@round(in.wheel[1])), .down = in.buttons.middle },
    };
}

const testing = std.testing;
const Replay = @import("../../core/input.zig").Replay;

test "input: a recording replayed through touch and encoder gives the core's input" {
    const recording =
        \\frame
        \\scale 2
        \\# A tap: down, move, lift, then nothing.
        \\frame
        \\pointer 10 20
        \\buttons left
        \\frame
        \\pointer 12 22
        \\frame
        \\buttons
        \\frame
        \\# The encoder: two detents forward, one back, then its button.
        \\frame
        \\wheel 0 2
        \\frame
        \\wheel 0 -1
        \\frame
        \\buttons middle
        \\frame
        \\buttons
        \\# A finger, through the contact rows.
        \\frame
        \\touch 7 30 40
        \\frame
        \\
    ;
    var replay: Replay = .{ .src = recording };
    var text: [8]u8 = undefined;
    var events: [4]Input.Event = undefined;
    var contacts: [2]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &events, .contacts = &contacts };
    var r: Reader = .{};
    var in: Input = .{ .scale = 2 };
    const Want = struct { pointer: [2]f32, left: bool = false, keys: []const Input.Event = &.{}, enter: bool = false };
    const tab: Input.Event = .{ .kind = .press, .code = 0x2b };
    const back: Input.Event = .{ .kind = .press, .code = 0x2b, .mods = .{ .shift = true } };
    const wants = [_]Want{
        .{ .pointer = .{ -1, -1 } },
        .{ .pointer = .{ 10, 20 }, .left = true },
        .{ .pointer = .{ 12, 22 }, .left = true },
        // The lift: the release lands where the finger was.
        .{ .pointer = .{ 12, 22 } },
        .{ .pointer = .{ -1, -1 } },
        .{ .pointer = .{ -1, -1 }, .keys = &.{ tab, tab } },
        .{ .pointer = .{ -1, -1 }, .keys = &.{back} },
        .{ .pointer = .{ -1, -1 }, .keys = &.{.{ .kind = .press, .code = enter }}, .enter = true },
        .{ .pointer = .{ -1, -1 }, .keys = &.{.{ .kind = .release, .code = enter }} },
        .{ .pointer = .{ 30, 40 }, .left = true },
        .{ .pointer = .{ 30, 40 } },
    };
    var frames: u32 = 0;
    while (try replay.next(buf)) |rec| : (frames += 1) {
        const want = wants[frames];
        r.read(sample(rec), &in);
        try testing.expectEqual(want.pointer, in.pointer);
        try testing.expectEqual(want.left, in.buttons.left);
        try testing.expectEqualSlices(Input.Event, want.keys, in.events);
        try testing.expectEqual(want.enter, in.keys.down(enter));
    }
    try testing.expectEqual(wants.len, frames);
}

test "input: a fast turn is clamped to max_steps key events" {
    var r: Reader = .{};
    var in: Input = .{};
    r.read(.{ .encoder = .{ .steps = -100, .down = true } }, &in);
    try testing.expectEqual(@as(usize, max_steps + 1), in.events.len);
    for (in.events[0..max_steps]) |e| try testing.expect(e.mods.shift and e.code == r.keymap.tab);
    try testing.expectEqual(enter, in.events[max_steps].code);
}
