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
    /// Mouse wheel this frame in notches (detents), x and y. Fractional for high-resolution
    /// wheels: a host with 120 units per notch passes `units / 120`.
    wheel: [2]f32 = .{ 0, 0 },
    /// Pixel-precise scroll this frame in logical pixels, x and y, from touchpads and other
    /// smooth-scrolling devices. A scroll view moves by `wheel * line_height + scroll`.
    scroll: [2]f32 = .{ 0, 0 },
    mods: Mods = .{},
    keys: Keys = .{},
    /// UTF-8 typed this frame. Only read during the frame.
    text: []const u8 = "",
    /// Key presses and typed text this frame, in the order they happened, so a fast typist's
    /// keys and characters are not merged. The host owns the slice. Only read during the frame.
    events: []const Event = &.{},
    /// Fingers and pens on or over the surface this frame, one row each. The mouse stays in
    /// `pointer` and `buttons`. The host owns the slice. Only read during the frame.
    contacts: []const Contact = &.{},

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

    /// One finger or pen. Rows are state, not events: a contact is listed every frame it lasts.
    pub const Contact = extern struct {
        /// Pointer id from the platform, stable from touch-down to lift-off, so a widget can
        /// follow one finger across frames.
        id: u32,
        kind: Kind = .touch,
        /// On the surface. A pen can hover with `down = false`.
        down: bool = true,
        _pad: [2]u8 = @splat(0),
        /// Logical pixels, like `pointer`.
        pos: [2]f32,
        /// 0 to 1; 1 on hardware without pressure.
        pressure: f32 = 1,
        /// Pen tilt from the surface normal in radians, along x and y; 0 for touch.
        tilt: [2]f32 = .{ 0, 0 },

        pub const Kind = enum(u8) { touch, pen, eraser };
    };

    /// No contact has the id (`contact` result).
    pub const none: u32 = 0xffff_ffff;

    /// Row of the contact with pointer id `id` in `contacts`, or `none`.
    pub fn contact(in: *const Input, id: u32) u32 {
        // Ids are unique per frame, so the last match is the only one. A mask select, not a
        // branch (prototype simd.selU; use simd's once that lane exports it).
        var at: u32 = none;
        for (in.contacts, 0..) |c, i| {
            const m = -%@as(u32, @intFromBool(c.id == id));
            at ^= (@as(u32, @intCast(i)) ^ at) & m;
        }
        return at;
    }

    /// The UTF-8 a `.text` event typed; empty for key events.
    pub fn typed(in: *const Input, e: Event) []const u8 {
        return in.text[e.at..][0..e.len];
    }

    /// Wheel and scroll of one axis in one stamp word: wheel bits low, scroll bits high. With
    /// no pixel scroll (+0.0) this is the prototype's wheel word, so its stamps are kept.
    inline fn wheelWord(in: *const Input, axis: usize) u64 {
        return @as(u64, @as(u32, @bitCast(in.scroll[axis]))) << 32 | @as(u32, @bitCast(in.wheel[axis]));
    }

    /// Fingerprint of everything except the clock. Equal stamps mean a frame
    /// built from this input would come out identical to the previous one.
    pub fn stamp(in: *const Input) u64 {
        const words = [_]u64{
            @as(u32, @bitCast(in.viewport[0])), @as(u32, @bitCast(in.viewport[1])),
            @as(u32, @bitCast(in.scale)),       @as(u32, @bitCast(in.pointer[0])),
            @as(u32, @bitCast(in.pointer[1])),  wheelWord(in, 0),
            wheelWord(in, 1),                   @as(u8, @bitCast(in.buttons)),
            @as(u8, @bitCast(in.mods)),         in.keys.bits[0],
            in.keys.bits[1],                    in.keys.bits[2],
            in.keys.bits[3],                    in.text.len,
        };
        // FNV-1a over 64-bit words, then over the typed bytes.
        var h: u64 = 0xcbf2_9ce4_8422_2325;
        for (words) |w| h = (h ^ w) *% 0x0000_0100_0000_01b3;
        for (in.text) |ch| h = (h ^ ch) *% 0x0000_0100_0000_01b3;
        // Events and contacts last: with none the stamp is the prototype's.
        for (std.mem.sliceAsBytes(in.events)) |b| h = (h ^ b) *% 0x0000_0100_0000_01b3;
        for (std.mem.sliceAsBytes(in.contacts)) |b| h = (h ^ b) *% 0x0000_0100_0000_01b3;
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

    var changed: [12]Input = @splat(base);
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
    changed[10].scroll[0] = 0.5;
    changed[11].scroll[1] = -12;
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

test "Input.contacts: a finger and a pen found by pointer id" {
    const rows = [_]Input.Contact{
        .{ .id = 7, .pos = .{ 10, 20 } },
        .{ .id = 3, .kind = .pen, .down = false, .pos = .{ 5, 5 }, .pressure = 0, .tilt = .{ 0.2, -0.1 } },
    };
    const in: Input = .{ .contacts = &rows };
    try std.testing.expectEqual(28, @sizeOf(Input.Contact));
    try std.testing.expectEqual(@as(u32, 0), in.contact(7));
    try std.testing.expectEqual(@as(u32, 1), in.contact(3));
    try std.testing.expectEqual(Input.none, in.contact(4));
    try std.testing.expect(!in.contacts[in.contact(3)].down);
    const empty: Input = .{};
    try std.testing.expectEqual(Input.none, empty.contact(0));
}

test "Input.stamp: sees a contact move or lift" {
    const base = busyInput();
    const at = [_]Input.Contact{.{ .id = 1, .pos = .{ 10, 20 } }};
    const moved = [_]Input.Contact{.{ .id = 1, .pos = .{ 10, 21 } }};
    const lifted = [_]Input.Contact{.{ .id = 1, .down = false, .pos = .{ 10, 20 } }};
    var a = base;
    a.contacts = &at;
    var b = base;
    b.contacts = &moved;
    var c = base;
    c.contacts = &lifted;
    try std.testing.expect(a.stamp() != base.stamp());
    try std.testing.expect(a.stamp() != b.stamp());
    try std.testing.expect(a.stamp() != c.stamp());
}

test "Input: high-resolution wheel and pixel scroll are separate deltas" {
    // A 120-units-per-notch host reporting 30 units, and a touchpad reporting pixels.
    const in: Input = .{ .wheel = .{ 0, 30.0 / 120.0 }, .scroll = .{ -3.5, 12 } };
    const line_height: f32 = 20;
    try std.testing.expectEqual(@as(f32, 5 + 12), in.wheel[1] * line_height + in.scroll[1]);
    try std.testing.expectEqual(@as(f32, -3.5), in.wheel[0] * line_height + in.scroll[0]);
    // Wheel and scroll of the same size are different stamps.
    const as_wheel: Input = .{ .wheel = .{ 0, 1 } };
    const as_scroll: Input = .{ .scroll = .{ 0, 1 } };
    try std.testing.expect(as_wheel.stamp() != as_scroll.stamp());
}

/// Recorded input, replayed one frame per `next` call, so tests can drive the core with input
/// captured from a host. A recording is UTF-8 text, one setting per line:
///
///     # comment                 blank lines and comments anywhere
///     frame                     starts a frame; the lines below it fill that frame
///     time 1.5                  also dt, scale (one number)
///     viewport 800 600          also pointer, wheel, scroll (two numbers)
///     buttons left middle       the held set, replaced (left right middle); bare `buttons` clears
///     mods shift ctrl           likewise (shift ctrl alt cmd)
///     keys 30 31                likewise, scancodes
///     press 30 ctrl             a key event (also release, repeat): code, then the mods held
///     text hello there          a `.text` event: the rest of the line after one space
///     touch 7 10 20 0.8         a finger: id x y [pressure]
///     pen 3 30 40 0.5 0.1 0.2   a pen (also eraser): id x y pressure tilt_x tilt_y; down when pressure > 0
///
/// Held state (time, dt, viewport, scale, pointer, buttons, mods, keys) carries over to the next
/// frame; wheel, scroll, text, events and contacts belong to one frame. `time` advances by `dt`
/// each frame unless the frame sets it. Typed text cannot contain a newline.
pub const Replay = struct {
    src: []const u8,
    /// Byte offset of the next line.
    at: usize = 0,
    /// 1-based number of the last line read; on an error, the line at fault.
    line: u32 = 0,
    in: Input = .{},
    started: bool = false,

    /// Caller-owned storage for the per-frame slices of the returned Input. Reused every frame.
    pub const Buffers = struct { text: []u8, events: []Input.Event, contacts: []Input.Contact };
    pub const Error = error{ Syntax, BufferFull };

    const Words = std.mem.TokenIterator(u8, .scalar);
    const Setting = enum { time, dt, scale, viewport, pointer, wheel, scroll, buttons, mods, keys, press, release, repeat, text, touch, pen, eraser };

    /// The next frame, or null after the last. Valid until the next call.
    pub fn next(r: *Replay, buf: Buffers) Error!?*const Input {
        while (true) {
            const l = r.take() orelse return null;
            if (blank(l)) continue;
            if (!std.mem.eql(u8, l, "frame")) return error.Syntax;
            break;
        }
        if (r.started) r.in.time += r.in.dt;
        r.started = true;
        r.in.wheel = .{ 0, 0 };
        r.in.scroll = .{ 0, 0 };
        var n_text: usize = 0;
        var n_events: usize = 0;
        var n_contacts: usize = 0;
        while (r.peek()) |l| {
            if (std.mem.eql(u8, l, "frame")) break;
            _ = r.take();
            if (blank(l)) continue;
            var words = std.mem.tokenizeScalar(u8, l, ' ');
            const setting = std.meta.stringToEnum(Setting, words.next().?) orelse return error.Syntax;
            const in = &r.in;
            switch (setting) {
                .time => in.time = try num(f64, &words),
                .dt => in.dt = try num(f32, &words),
                .scale => in.scale = try num(f32, &words),
                .viewport => in.viewport = try pair(&words),
                .pointer => in.pointer = try pair(&words),
                .wheel => in.wheel = try pair(&words),
                .scroll => in.scroll = try pair(&words),
                .buttons => in.buttons = try flags(Input.Buttons, &words),
                .mods => in.mods = try flags(Input.Mods, &words),
                .keys => {
                    in.keys = .{};
                    while (words.next()) |w| in.keys.press(try int(u8, w));
                },
                inline .press, .release, .repeat => |key| {
                    if (n_events == buf.events.len) return error.BufferFull;
                    const code = try int(u8, words.next() orelse return error.Syntax);
                    buf.events[n_events] = .{ .kind = @field(Input.Event.Kind, @tagName(key)), .code = code, .mods = try flags(Input.Mods, &words) };
                    n_events += 1;
                },
                .text => {
                    const t = l[@min(l.len, "text ".len)..];
                    if (n_events == buf.events.len or buf.text.len - n_text < t.len) return error.BufferFull;
                    @memcpy(buf.text[n_text..][0..t.len], t);
                    buf.events[n_events] = .{ .kind = .text, .at = @intCast(n_text), .len = @intCast(t.len) };
                    n_text += t.len;
                    n_events += 1;
                },
                .touch, .pen, .eraser => {
                    if (n_contacts == buf.contacts.len) return error.BufferFull;
                    var c: Input.Contact = .{ .id = try int(u32, words.next() orelse return error.Syntax), .pos = .{ 0, 0 } };
                    c.pos[0] = try num(f32, &words);
                    c.pos[1] = try num(f32, &words);
                    if (setting == .touch) {
                        if (words.peek() != null) c.pressure = try num(f32, &words);
                    } else {
                        c.kind = if (setting == .pen) .pen else .eraser;
                        c.pressure = try num(f32, &words);
                        c.tilt = try pair(&words);
                        c.down = c.pressure > 0;
                    }
                    if (words.next() != null) return error.Syntax;
                    buf.contacts[n_contacts] = c;
                    n_contacts += 1;
                },
            }
        }
        r.in.text = buf.text[0..n_text];
        r.in.events = buf.events[0..n_events];
        r.in.contacts = buf.contacts[0..n_contacts];
        return &r.in;
    }

    fn peek(r: *const Replay) ?[]const u8 {
        if (r.at >= r.src.len) return null;
        const rest = r.src[r.at..];
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        return std.mem.trimEnd(u8, rest[0..end], "\r");
    }

    fn take(r: *Replay) ?[]const u8 {
        const rest = r.src[@min(r.at, r.src.len)..];
        const l = r.peek() orelse return null;
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        r.at += end + 1;
        r.line += 1;
        return l;
    }

    fn blank(l: []const u8) bool {
        const t = std.mem.trimStart(u8, l, " ");
        return t.len == 0 or t[0] == '#';
    }

    fn int(comptime T: type, w: []const u8) Error!T {
        return std.fmt.parseInt(T, w, 10) catch error.Syntax;
    }

    fn num(comptime T: type, words: *Words) Error!T {
        return std.fmt.parseFloat(T, words.next() orelse return error.Syntax) catch error.Syntax;
    }

    fn pair(words: *Words) Error![2]f32 {
        const v: [2]f32 = .{ try num(f32, words), try num(f32, words) };
        if (words.next() != null) return error.Syntax;
        return v;
    }

    /// A packed bit set from the names of its fields, all on one line.
    fn flags(comptime T: type, words: *Words) Error!T {
        var v: T = .{};
        while (words.next()) |w| {
            var hit = false;
            inline for (@typeInfo(T).@"struct".field_names) |name| {
                if (comptime name[0] == '_') continue;
                if (std.mem.eql(u8, w, name)) {
                    @field(v, name) = true;
                    hit = true;
                }
            }
            if (!hit) return error.Syntax;
        }
        return v;
    }
};

test "Replay: example recording replays from a file" {
    var text: [64]u8 = undefined;
    var events: [8]Input.Event = undefined;
    var contacts: [4]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &events, .contacts = &contacts };
    var r: Replay = .{ .src = @embedFile("testdata/click.replay") };
    var stamps: [8]u64 = undefined;
    var n: usize = 0;
    while (try r.next(buf)) |in| : (n += 1) {
        try std.testing.expectApproxEqAbs(@as(f64, 0.016) * @as(f64, @floatFromInt(n)), in.time, 1e-6);
        stamps[n] = in.stamp();
        switch (n) {
            0 => {
                try std.testing.expectEqual([2]f32{ 100, 40 }, in.pointer);
                try std.testing.expect(!in.buttons.left);
            },
            1 => try std.testing.expect(in.buttons.left),
            2 => try std.testing.expect(!in.buttons.left),
            3 => {
                try std.testing.expectEqualStrings("hI", in.text);
                try std.testing.expectEqual(6, in.events.len);
                try std.testing.expectEqualStrings("I", in.typed(in.events[4]));
                try std.testing.expectEqual(Input.Event.Kind.press, in.events[3].kind);
                try std.testing.expectEqual(@as(u8, 23), in.events[3].code);
                try std.testing.expect(in.events[3].mods.shift and !in.events[2].mods.shift);
            },
            4 => {
                try std.testing.expect(in.keys.down(42));
                try std.testing.expectEqual(2, in.contacts.len);
                const pen = in.contacts[in.contact(2)];
                try std.testing.expectEqual(Input.Contact.Kind.pen, pen.kind);
                try std.testing.expect(pen.down);
                try std.testing.expectEqual([2]f32{ 0.1, -0.2 }, pen.tilt);
                try std.testing.expectEqual(@as(f32, 1), in.contacts[in.contact(1)].pressure);
            },
            5 => {
                try std.testing.expectEqual([2]f32{ 0, -12.5 }, in.scroll);
                try std.testing.expectEqual([2]f32{ 0, 0.25 }, in.wheel);
                try std.testing.expectEqual(0, in.contacts.len);
                try std.testing.expect(!in.keys.down(42));
            },
            else => {
                try std.testing.expectEqual(0, in.events.len);
                try std.testing.expectEqual([2]f32{ 0, 0 }, in.scroll);
            },
        }
    }
    try std.testing.expectEqual(8, n);
    // Idle detection on replayed input: a frame equal to an earlier one has its stamp.
    try std.testing.expectEqual(stamps[0], stamps[2]);
    try std.testing.expectEqual(stamps[2], stamps[6]);
    try std.testing.expectEqual(stamps[6], stamps[7]);
    try std.testing.expect(stamps[1] != stamps[0]);
}

test "Replay: errors name the line, buffers bound the frame" {
    var text: [2]u8 = undefined;
    var events: [1]Input.Event = undefined;
    var contacts: [0]Input.Contact = .{};
    const buf: Replay.Buffers = .{ .text = &text, .events = &events, .contacts = &contacts };

    var bad: Replay = .{ .src = "frame\npointer 1\n" };
    try std.testing.expectError(error.Syntax, bad.next(buf));
    try std.testing.expectEqual(@as(u32, 2), bad.line);

    var unknown: Replay = .{ .src = "# x\nframe\nbuttons left thumb" };
    try std.testing.expectError(error.Syntax, unknown.next(buf));
    try std.testing.expectEqual(@as(u32, 3), unknown.line);

    var before: Replay = .{ .src = "pointer 1 2\nframe\n" };
    try std.testing.expectError(error.Syntax, before.next(buf));

    var full: Replay = .{ .src = "frame\npress 1\nrelease 1\n" };
    try std.testing.expectError(error.BufferFull, full.next(buf));

    var long: Replay = .{ .src = "frame\ntext abc" };
    try std.testing.expectError(error.BufferFull, long.next(buf));

    var touch: Replay = .{ .src = "frame\ntouch 1 2 3" };
    try std.testing.expectError(error.BufferFull, touch.next(buf));

    var empty: Replay = .{ .src = "" };
    try std.testing.expectEqual(null, try empty.next(buf));
}
