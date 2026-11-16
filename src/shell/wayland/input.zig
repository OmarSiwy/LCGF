//! The seat: `wl_pointer`, `wl_keyboard` and `wl_touch` events turned into `Input`. Held state
//! (pointer, buttons, keys, modifiers, fingers) carries over between polls; wheel, scroll,
//! typed text and key events belong to one poll. Positions are surface-local logical pixels,
//! which is what the core reads. Keys are reported as USB HID scancodes (`xkb.hid`), the
//! codes the widgets use, and typed text comes from the compositor's keymap (`xkb.Keymap`).

const std = @import("std");
const lcgr = @import("lcgr");
const wire = @import("wire.zig");
const xkb = @import("xkb.zig");
const linux = std.os.linux;
const Input = lcgr.input.Input;
const inf = std.math.inf(f64);

/// Linux button codes (linux/input-event-codes.h).
const btn_left = 0x110;
const btn_right = 0x111;
const btn_middle = 0x112;

pub const Seat = struct {
    pointer: u32 = 0,
    keyboard: u32 = 0,
    touch: u32 = 0,
    /// Serial of the last `wl_pointer.enter`, for cursor requests.
    enter_serial: u32 = 0,
    /// Serial of the last input event, for requests that need one (the clipboard).
    serial: u32 = 0,
    /// Surface under the pointer, and the one with keyboard focus; 0 for none.
    pointer_focus: u32 = 0,
    key_focus: u32 = 0,
    keymap: xkb.Keymap = .{},
    /// Depressed, latched and locked modifiers, ORed.
    mask: u32 = 0,
    /// Held state, in `Input`'s form.
    held: Input = .{},
    /// This poll's wheel in 1/120 notches and scroll in pixels, x and y, as Wayland signs
    /// them (positive is down and right).
    v120: [2]i32 = .{ 0, 0 },
    px: [2]f32 = .{ 0, 0 },
    /// Typed text of one poll: keys, and a paste or an input method's commit.
    text: [64 * 1024 + 256]u8 = undefined,
    text_len: u32 = 0,
    events: [64]Input.Event = undefined,
    nevents: u32 = 0,
    /// Fingers down; a lifted one stays one poll with `down = false`, so a tap that starts and
    /// ends between two polls is still seen.
    touches: [10]Input.Contact = undefined,
    ntouches: u32 = 0,
    /// Key repeat is the client's job on Wayland: `wl_keyboard.repeat_info` gives the rate
    /// (per second, 0 = off) and the delay (ms); the held key repeats from `repeat_at` (seconds
    /// on the shell's clock) until it is released or focus leaves.
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
    repeat_key: u32 = 0,
    repeat_at: f64 = inf,
    /// The shell's clock, set before events are handled.
    now: f64 = 0,

    /// Starts a poll: clears the per-poll state and drops the fingers lifted in the last one.
    pub fn begin(s: *Seat) void {
        s.v120 = .{ 0, 0 };
        s.px = .{ 0, 0 };
        s.text_len = 0;
        s.nevents = 0;
        var n: u32 = 0;
        for (s.touches[0..s.ntouches]) |c| {
            s.touches[n] = c;
            n += @intFromBool(c.down);
        }
        s.ntouches = n;
    }

    /// This poll's input: held state plus what arrived since `begin`.
    pub fn fill(s: *const Seat, in: *Input) void {
        in.pointer = s.held.pointer;
        in.buttons = s.held.buttons;
        in.mods = s.held.mods;
        in.keys = s.held.keys;
        // The core's wheel is positive up (src/widgets/scroll.zig subtracts it); Wayland's is
        // positive down. A wheel with notches reports them; a touchpad reports pixels.
        for (0..2) |k| {
            in.wheel[k] = -@as(f32, @floatFromInt(s.v120[k])) / 120;
            in.scroll[k] = if (s.v120[k] != 0) 0 else -s.px[k];
        }
        in.text = s.text[0..s.text_len];
        in.events = s.events[0..s.nevents];
        in.contacts = s.touches[0..s.ntouches];
    }

    pub fn pointerEvent(s: *Seat, opcode: u16, a: *wire.Args) void {
        switch (opcode) {
            0 => { // enter: serial, surface, x, y
                s.enter_serial = a.uint();
                s.pointer_focus = a.uint();
                s.held.pointer = .{ a.fixed(), a.fixed() };
            },
            1 => { // leave
                s.pointer_focus = 0;
                s.held.pointer = .{ -1, -1 };
                s.held.buttons = .{};
            },
            2 => { // motion: time, x, y
                _ = a.uint();
                s.held.pointer = .{ a.fixed(), a.fixed() };
            },
            3 => { // button: serial, time, button, state
                s.serial = a.uint();
                _ = a.uint();
                const button = a.uint();
                const down = a.uint() == 1;
                switch (button) {
                    btn_left => s.held.buttons.left = down,
                    btn_right => s.held.buttons.right = down,
                    btn_middle => s.held.buttons.middle = down,
                    else => {},
                }
            },
            4 => { // axis: time, axis, value (pixels)
                _ = a.uint();
                const axis = axisIndex(a.uint());
                s.px[axis] += a.fixed();
            },
            9 => { // axis_value120: axis, value120
                const axis = axisIndex(a.uint());
                s.v120[axis] += a.int();
            },
            else => {},
        }
    }

    pub fn keyboardEvent(s: *Seat, opcode: u16, a: *wire.Args, conn: *wire.Conn) void {
        switch (opcode) {
            0 => { // keymap: format, fd, size
                const format = a.uint();
                const fd = conn.takeFd();
                const size = a.uint();
                defer _ = linux.close(fd);
                if (format != 1 or fd < 0 or size == 0) return;
                const addr = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
                if (linux.errno(addr) != .SUCCESS) return;
                const map = @as([*]const u8, @ptrFromInt(addr))[0..size];
                defer _ = linux.munmap(map.ptr, map.len);
                s.keymap = .parse(map);
            },
            1 => { // enter: serial, surface, keys
                s.serial = a.uint();
                s.key_focus = a.uint();
                s.held.keys = .{};
                const held = a.array();
                for (0..held.len / 4) |k| s.held.keys.press(xkb.hid(std.mem.readInt(u32, held[k * 4 ..][0..4], .little)));
                s.held.keys.bits[0] &= ~@as(u64, 1); // HID 0 is "no key"
            },
            2 => { // leave
                s.key_focus = 0;
                s.repeat_key = 0;
                s.repeat_at = inf;
                s.held.keys = .{};
                s.held.mods = .{};
                s.mask = 0;
            },
            3 => { // key: serial, time, key, state
                s.serial = a.uint();
                _ = a.uint();
                const evdev = a.uint();
                const down = a.uint() != 0;
                s.key(evdev, if (down) .press else .release);
            },
            4 => { // modifiers: serial, depressed, latched, locked, group
                _ = a.uint();
                s.mask = a.uint() | a.uint() | a.uint();
                s.held.mods = xkb.mods(s.mask);
            },
            5 => { // repeat_info: rate, delay
                s.repeat_rate = a.int();
                s.repeat_delay = a.int();
            },
            else => {},
        }
    }

    /// A key went down, up or repeated: held keys, a key event, and the text it types.
    pub fn key(s: *Seat, evdev: u32, kind: Input.Event.Kind) void {
        const code = xkb.hid(evdev);
        // The last key pressed repeats, unless it is a modifier (HID 0xe0 to 0xe7).
        if (kind == .press and s.repeat_rate > 0 and code < 0xe0) {
            s.repeat_key = evdev;
            s.repeat_at = s.now + @as(f64, @floatFromInt(s.repeat_delay)) / 1000;
        }
        if (kind == .release and evdev == s.repeat_key) {
            s.repeat_key = 0;
            s.repeat_at = inf;
        }
        if (code != 0) {
            const bit = @as(u64, 1) << @as(u6, @truncate(code));
            s.held.keys.bits[code >> 6] = if (kind == .release) s.held.keys.bits[code >> 6] & ~bit else s.held.keys.bits[code >> 6] | bit;
            s.push(.{ .kind = kind, .mods = s.held.mods, .code = code });
        }
        if (kind == .release) return;
        // Ctrl and Alt make a key a command, not text (AltGr is Level 3, not Alt).
        if (s.mask & (xkb.mod_ctrl | xkb.mod_alt) != 0) return;
        const c = s.keymap.text(evdev, s.mask);
        if (c < 0x20 or c == 0x7f) return;
        var utf8: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(c, &utf8) catch return;
        if (s.text_len + len > s.text.len) return;
        @memcpy(s.text[s.text_len..][0..len], utf8[0..len]);
        s.push(.{ .kind = .text, .mods = s.held.mods, .at = s.text_len, .len = len });
        s.text_len += len;
    }

    /// Repeats of the held key that are due by `now`.
    pub fn repeat(s: *Seat, now: f64) void {
        if (s.repeat_rate <= 0) return;
        const period = 1 / @as(f64, @floatFromInt(s.repeat_rate));
        // A long stall (the window was hidden) types a few, not hundreds.
        var n: u32 = 0;
        while (s.repeat_key != 0 and s.repeat_at <= now and n < 8) : (n += 1) {
            s.key(s.repeat_key, .repeat);
            s.repeat_at += period;
        }
        s.repeat_at = @max(s.repeat_at, if (n == 8) now + period else s.repeat_at);
    }

    /// Committed text from outside the keyboard (an input method, a paste): typed text and a
    /// `.text` event. Text that does not fit this poll's buffer is dropped.
    pub fn typeText(s: *Seat, t: []const u8) void {
        if (t.len == 0 or s.text_len + t.len > s.text.len) return;
        @memcpy(s.text[s.text_len..][0..t.len], t);
        s.push(.{ .kind = .text, .mods = s.held.mods, .at = s.text_len, .len = @intCast(t.len) });
        s.text_len += @intCast(t.len);
    }

    fn push(s: *Seat, e: Input.Event) void {
        if (s.nevents == s.events.len) return;
        s.events[s.nevents] = e;
        s.nevents += 1;
    }

    pub fn touchEvent(s: *Seat, opcode: u16, a: *wire.Args) void {
        switch (opcode) {
            0 => { // down: serial, time, surface, id, x, y
                s.serial = a.uint();
                _ = a.uint();
                _ = a.uint();
                const id = a.uint();
                const pos: [2]f32 = .{ a.fixed(), a.fixed() };
                if (s.ntouches == s.touches.len) return;
                s.touches[s.ntouches] = .{ .id = id, .pos = pos };
                s.ntouches += 1;
            },
            1 => { // up: serial, time, id
                _ = a.uint();
                _ = a.uint();
                const id = a.uint();
                for (s.touches[0..s.ntouches]) |*c| c.down = c.down and c.id != id;
            },
            2 => { // motion: time, id, x, y
                _ = a.uint();
                const id = a.uint();
                const pos: [2]f32 = .{ a.fixed(), a.fixed() };
                for (s.touches[0..s.ntouches]) |*c| if (c.id == id) {
                    c.pos = pos;
                };
            },
            4 => s.ntouches = 0, // cancel: the compositor took the touches over
            else => {},
        }
    }
};

/// `wl_pointer.axis` to `Input`'s index: vertical (0) is y, horizontal (1) is x.
fn axisIndex(axis: u32) usize {
    return @intFromBool(axis == 0);
}
