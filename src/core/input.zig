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
    buttons: Buttons = .{},
    wheel: [2]f32 = .{ 0, 0 },
    mods: Mods = .{},
    keys: Keys = .{},
    /// UTF-8 typed this frame. Only read during the frame.
    text: []const u8 = "",
    /// Key presses and typed text this frame, in the order they happened, so a fast typist's
    /// keys and characters are not merged. The host owns the slice. Only read during the frame.
    events: []const Event = &.{},

    /// Mouse buttons held down this frame, one bit each.
    pub const Buttons = packed struct(u8) { left: bool = false, right: bool = false, middle: bool = false, _: u5 = 0 };
    /// Modifier keys held down this frame, one bit each. `cmd` is the platform's command or super key.
    pub const Mods = packed struct(u8) { shift: bool = false, ctrl: bool = false, alt: bool = false, cmd: bool = false, _: u4 = 0 };

    /// 256 key states as a bit set. Index with your platform's scancodes.
    pub const Keys = struct {
        bits: [4]u64 = @splat(0),
        pub fn press(k: *Keys, code: u8) void {
            k.bits[code >> 6] |= @as(u64, 1) << @as(u6, @truncate(code));
        }
        pub fn down(k: *const Keys, code: u8) bool {
            return ((k.bits[code >> 6] >> @as(u6, @truncate(code))) & 1) != 0;
        }
    };

    /// One key transition or one piece of typed text.
    pub const Event = extern struct {
        kind: Kind,
        /// Modifiers held when the event happened.
        mods: Mods = .{},
        /// Scancode, as for `Keys`. 0 for `.text`.
        code: u8 = 0,
        _pad: u8 = 0,
        /// For `.text`: the bytes `Input.text[at..][0..len]`. 0 and 0 for key events.
        at: u32 = 0,
        len: u32 = 0,

        pub const Kind = enum(u8) { press, release, repeat, text };
    };

    /// The UTF-8 a `.text` event typed; empty for key events.
    pub fn typed(in: *const Input, e: Event) []const u8 {
        return in.text[e.at..][0..e.len];
    }

    /// Fingerprint of everything except the clock. Equal stamps mean a frame
    /// built from this input would come out identical to the previous one.
    pub fn stamp(in: *const Input) u64 {
        const words = [_]u64{
            @as(u32, @bitCast(in.viewport[0])), @as(u32, @bitCast(in.viewport[1])),
            @as(u32, @bitCast(in.scale)),       @as(u32, @bitCast(in.pointer[0])),
            @as(u32, @bitCast(in.pointer[1])),  @as(u32, @bitCast(in.wheel[0])),
            @as(u32, @bitCast(in.wheel[1])),    @as(u8, @bitCast(in.buttons)),
            @as(u8, @bitCast(in.mods)),         in.keys.bits[0],
            in.keys.bits[1],                    in.keys.bits[2],
            in.keys.bits[3],                    in.text.len,
        };
        // FNV-1a over 64-bit words, then over the typed bytes.
        var h: u64 = 0xcbf2_9ce4_8422_2325;
        for (words) |w| h = (h ^ w) *% 0x0000_0100_0000_01b3;
        for (in.text) |ch| h = (h ^ ch) *% 0x0000_0100_0000_01b3;
        // Events last: with none queued the stamp is the prototype's.
        for (std.mem.sliceAsBytes(in.events)) |b| h = (h ^ b) *% 0x0000_0100_0000_01b3;
        return h;
    }
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

test "Input: Buttons and Mods are one byte with the prototype's bit order" {
    try std.testing.expectEqual(1, @sizeOf(Input.Buttons));
    try std.testing.expectEqual(1, @sizeOf(Input.Mods));
    try std.testing.expectEqual(@as(u8, 0b101), @as(u8, @bitCast(Input.Buttons{ .left = true, .middle = true })));
    try std.testing.expectEqual(@as(u8, 0b1010), @as(u8, @bitCast(Input.Mods{ .ctrl = true, .cmd = true })));
    const in: Input = .{};
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(in.buttons)));
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(in.mods)));
}

test "Input.Keys: every code sets exactly its own bit" {
    for (0..256) |c| {
        const code: u8 = @intCast(c);
        var k: Input.Keys = .{};
        try std.testing.expect(!k.down(code));
        k.press(code);
        try std.testing.expect(k.down(code));
        try std.testing.expectEqual(@as(u64, 1) << @as(u6, @truncate(code)), k.bits[code >> 6]);
        var total: u32 = 0;
        for (k.bits) |w| total += @popCount(w);
        try std.testing.expectEqual(@as(u32, 1), total);
    }
    var k: Input.Keys = .{};
    k.press(0);
    k.press(255);
    k.press(0);
    try std.testing.expect(k.down(0) and k.down(255) and !k.down(128));
}

/// An input with every stamped field away from its default, for the stamp tests.
fn busyInput() Input {
    var in: Input = .{
        .viewport = .{ 1024, 768 },
        .scale = 2,
        .pointer = .{ 10.5, 20 },
        .buttons = .{ .left = true },
        .wheel = .{ 0, -1 },
        .mods = .{ .shift = true },
        .text = "h\xc3\xa9",
    };
    in.keys.press(30);
    in.keys.press(200);
    return in;
}

test "Input.stamp: values match the prototype" {
    // Printed by prototype/ui.zig Input.stamp for the same two inputs.
    const idle: Input = .{};
    try std.testing.expectEqual(@as(u64, 0xacd84874b9e43add), idle.stamp());
    const busy = busyInput();
    try std.testing.expectEqual(@as(u64, 0x53181a347e6083de), busy.stamp());
}

test "Input.stamp: ignores the clock, sees every other field" {
    const base = busyInput();
    var clock = base;
    clock.time = 99;
    clock.dt = 0.5;
    try std.testing.expectEqual(base.stamp(), clock.stamp());

    var changed: [10]Input = @splat(base);
    changed[0].viewport[1] = 769;
    changed[1].scale = 1;
    changed[2].pointer[0] = 11;
    changed[3].buttons.right = true;
    changed[4].wheel[0] = 1;
    changed[5].mods.alt = true;
    changed[6].keys.press(31);
    changed[7].text = "h\xc3\xa8"; // same length, different byte
    changed[8].text = "h";
    changed[9].keys.press(255);
    for (changed) |c| try std.testing.expect(c.stamp() != base.stamp());
}

test "Input.events: keys and typed text keep their order" {
    const ctrl: Input.Mods = .{ .ctrl = true };
    const queue = [_]Input.Event{
        .{ .kind = .press, .code = 30 },
        .{ .kind = .text, .at = 0, .len = 1 },
        .{ .kind = .release, .code = 30 },
        .{ .kind = .text, .at = 1, .len = 2 },
        .{ .kind = .press, .code = 31, .mods = ctrl },
        .{ .kind = .repeat, .code = 31, .mods = ctrl },
    };
    const in: Input = .{ .text = "a\xc3\xa9", .events = &queue };
    try std.testing.expectEqual(12, @sizeOf(Input.Event));
    try std.testing.expectEqualStrings("a", in.typed(in.events[1]));
    try std.testing.expectEqualStrings("\xc3\xa9", in.typed(in.events[3]));
    try std.testing.expectEqualStrings("", in.typed(in.events[0]));
    var joined: [3]u8 = undefined;
    var n: usize = 0;
    for (in.events) |e| {
        const t = in.typed(e);
        @memcpy(joined[n..][0..t.len], t);
        n += t.len;
    }
    try std.testing.expectEqualStrings(in.text, joined[0..n]);
}

test "Input.stamp: sees queued events" {
    const base = busyInput();
    const press = [_]Input.Event{.{ .kind = .press, .code = 30 }};
    const release = [_]Input.Event{.{ .kind = .release, .code = 30 }};
    var a = base;
    a.events = &press;
    var b = base;
    b.events = &release;
    try std.testing.expect(a.stamp() != base.stamp());
    try std.testing.expect(a.stamp() != b.stamp());
}
