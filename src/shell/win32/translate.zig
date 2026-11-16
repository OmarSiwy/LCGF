//! Win32 window messages as `Events`: the part of the Win32 shell (win32.zig) that touches no
//! OS, so it builds and is tested on any host. The shell's window procedure hands every message
//! to `Translator.feed`; `poll` drains the queue and calls `frame`. Everything the translator
//! keeps is carved from the caller's buffers; it allocates nothing.
//!
//! Message layouts are the Win32 API documentation's (learn.microsoft.com, "Window messages"):
//! `WM_SIZE` carries the client size in the low and high words of lParam, and so on.

const std = @import("std");
const Input = @import("../../core/input.zig").Input;
const Events = @import("../iface.zig").Events;
const Cursor = @import("../../runtime/context.zig").Cursor;
const Rect = @import("../../core/types.zig").Rect;
const Pace = @import("../../runtime/scheduler.zig").Pace;

/// The window messages the translator reads, by their winuser.h values.
pub const Wm = enum(u32) {
    size = 0x0005,
    killfocus = 0x0008,
    close = 0x0010,
    keydown = 0x0100,
    keyup = 0x0101,
    char = 0x0102,
    syskeydown = 0x0104,
    syskeyup = 0x0105,
    mousemove = 0x0200,
    lbuttondown = 0x0201,
    lbuttonup = 0x0202,
    rbuttondown = 0x0204,
    rbuttonup = 0x0205,
    mbuttondown = 0x0207,
    mbuttonup = 0x0208,
    mousewheel = 0x020a,
    mousehwheel = 0x020e,
    mouseleave = 0x02a3,
    dpichanged = 0x02e0,
    _,
};

/// One window message, as the window procedure receives it.
pub const Msg = struct { msg: u32, wparam: usize = 0, lparam: isize = 0 };

/// `MAKELPARAM(lo, hi)`: two 16-bit words, as most mouse and size messages pack them.
pub fn lparam(lo: i32, hi: i32) isize {
    const w: u32 = (@as(u32, @as(u16, @truncate(@as(u32, @bitCast(hi))))) << 16) | @as(u16, @truncate(@as(u32, @bitCast(lo))));
    return @as(i32, @bitCast(w));
}

/// The signed low and high words of `lp` (`GET_X_LPARAM`, `GET_Y_LPARAM`).
fn words(lp: isize) [2]i32 {
    const v: u32 = @truncate(@as(usize, @bitCast(lp)));
    return .{ @as(i16, @bitCast(@as(u16, @truncate(v)))), @as(i16, @bitCast(@as(u16, @truncate(v >> 16)))) };
}

/// `WM_SIZE`'s wParam when the window was minimized: the client is 0 x 0 and nothing is shown.
const size_minimized = 1;
/// Mouse buttons held, in a mouse message's wParam (`MK_LBUTTON`, `MK_RBUTTON`, `MK_MBUTTON`).
const mk_left = 0x0001;
const mk_right = 0x0002;
const mk_middle = 0x0010;
/// The DPI at which one logical pixel is one physical pixel (`USER_DEFAULT_SCREEN_DPI`).
pub const dpi_default = 96;
/// One notch of a mouse wheel (`WHEEL_DELTA`).
const wheel_delta = 120;

/// USB HID usage (the scancodes of `Input.Keys`, src/interact/keyboard.zig) of each PC scancode
/// a key message carries in lParam bits 16 to 23, indexed by `extended << 7 | scancode`. 0: no
/// key. From the USB HID Usage Tables' PS/2 set 1 column, as Windows reports set 1.
pub const hid: [256]u8 = table: {
    var t: [256]u8 = @splat(0);
    // Letters, digits and punctuation in scancode order, from 0x01 (Escape).
    const plain = [_]u8{
        0x29, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2d, 0x2e, 0x2a, 0x2b, // Esc 1..0 - = Backspace Tab
        0x14, 0x1a, 0x08, 0x15, 0x17, 0x1c, 0x18, 0x0c, 0x12, 0x13, 0x2f, 0x30, 0x28, 0xe0, // Q..P [ ] Enter LCtrl
        0x04, 0x16, 0x07, 0x09, 0x0a, 0x0b, 0x0d, 0x0e, 0x0f, 0x33, 0x34, 0x35, 0xe1, 0x31, // A..L ; ' ` LShift \
        0x1d, 0x1b, 0x06, 0x19, 0x05, 0x11, 0x10, 0x36, 0x37, 0x38, 0xe5, 0x55, 0xe2, 0x2c, 0x39, // Z..M , . / RShift KP* LAlt Space Caps
        0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40, 0x41, 0x42, 0x43, 0x53, 0x47, // F1..F10 NumLock ScrollLock
        0x5f, 0x60, 0x61, 0x56, 0x5c, 0x5d, 0x5e, 0x57, 0x59, 0x5a, 0x5b, 0x62, 0x63, // keypad 7 8 9 - 4 5 6 + 1 2 3 0 .
    };
    for (plain, 1..) |u, sc| t[sc] = u;
    t[0x56] = 0x64; // the key between left Shift and Z on ISO keyboards
    t[0x57] = 0x44; // F11
    t[0x58] = 0x45; // F12
    // Extended (0xE0-prefixed) keys.
    const ext = [_][2]u8{
        .{ 0x1c, 0x58 }, .{ 0x1d, 0xe4 }, .{ 0x35, 0x54 }, .{ 0x37, 0x46 }, .{ 0x38, 0xe6 }, // KP Enter, RCtrl, KP /, PrintScreen, RAlt
        .{ 0x45, 0x53 }, .{ 0x47, 0x4a }, .{ 0x48, 0x52 }, .{ 0x49, 0x4b }, .{ 0x4b, 0x50 }, // NumLock, Home, Up, PageUp, Left
        .{ 0x4d, 0x4f }, .{ 0x4f, 0x4d }, .{ 0x50, 0x51 }, .{ 0x51, 0x4e }, .{ 0x52, 0x49 }, // Right, End, Down, PageDown, Insert
        .{ 0x53, 0x4c }, .{ 0x5b, 0xe3 }, .{ 0x5c, 0xe7 }, .{ 0x5d, 0x65 }, // Delete, LWin, RWin, Menu
    };
    for (ext) |e| t[0x80 | e[0]] = e[1];
    break :table t;
};

/// The system cursor (`IDC_*`, for `LoadCursorW`) of each `Platform.cursor`. Win32 has no
/// grab hand, so `grab` is the four-way move arrow, as for dragging a whole object.
pub const cursor_ids = ids: {
    const n = @typeInfo(Cursor).@"enum".field_names.len;
    var a: [n]u16 = undefined;
    a[@backingInt(Cursor.arrow)] = 32512; // IDC_ARROW
    a[@backingInt(Cursor.pointer)] = 32649; // IDC_HAND
    a[@backingInt(Cursor.text)] = 32513; // IDC_IBEAM
    a[@backingInt(Cursor.grab)] = 32646; // IDC_SIZEALL
    a[@backingInt(Cursor.resize_h)] = 32644; // IDC_SIZEWE
    a[@backingInt(Cursor.resize_v)] = 32645; // IDC_SIZENS
    break :ids a;
};

pub const Translator = struct {
    /// Held state, kept from message to message: viewport, scale, pointer, buttons, keys, mods.
    /// The per-frame part (wheel, text, events) collects the messages since the last `frame`.
    in: Input = .{},
    /// The client area in physical pixels, from `WM_SIZE`; `in.viewport` is it in logical
    /// pixels, at `in.scale`.
    client: [2]f32 = .{ 800, 600 },
    /// `WM_CLOSE` arrived: the user asked to close the window.
    closed: bool = false,
    /// Caller-owned storage for the typed text and key events arriving (`frame` copies them
    /// to `out`).
    text: []u8 = &.{},
    events: []Input.Event = &.{},
    n_text: u32 = 0,
    n_events: u32 = 0,
    /// Key events and characters that did not fit the buffers, since `init`.
    dropped: u32 = 0,
    /// A UTF-16 high surrogate from `WM_CHAR`, waiting for its low half in the next one.
    high: u16 = 0,
    /// The IME's composition as UTF-8, held until it changes or ends (`compose`).
    preedit: []u8 = &.{},
    composition: struct { len: u32 = 0, range: [2]u32 = .{ 0, 0 } } = .{},
    /// Paths dropped since the last frame, UTF-8 back to back, and where each ends.
    names: []u8 = &.{},
    ends: []u32 = &.{},
    n_names: u32 = 0,
    n_files: u32 = 0,
    /// Files were dropped since the last frame, at `drop_at` (logical pixels).
    dropped_files: bool = false,
    drop_at: [2]f32 = .{ -1, -1 },
    /// The frame handed out by `frame`, which its `Events` point into. Kept apart from what
    /// arrives so that, with several windows on one thread, another window's `poll` (which
    /// dispatches this window's messages too) cannot change a frame not yet built.
    out: Buffers = .{ .text = &.{}, .events = &.{} },

    /// Each buffer is split in two halves: the messages arriving, and the frame handed out.
    /// `preedit` holds twice the longest composition shown; a longer one is cut at a character.
    /// `names` and `ends` hold the paths of a drop, as `gestures.Files` lists them.
    pub const Buffers = struct { text: []u8, events: []Input.Event, preedit: []u8 = &.{}, names: []u8 = &.{}, ends: []u32 = &.{} };

    pub fn init(buf: Buffers) Translator {
        const t = buf.text.len / 2;
        const e = buf.events.len / 2;
        const p = buf.preedit.len / 2;
        const n = buf.names.len / 2;
        const f = buf.ends.len / 2;
        return .{
            .text = buf.text[0..t],
            .events = buf.events[0..e],
            .preedit = buf.preedit[0..p],
            .names = buf.names[0..n],
            .ends = buf.ends[0..f],
            .out = .{
                .text = buf.text[t..][0..t],
                .events = buf.events[e..][0..e],
                .preedit = buf.preedit[p..][0..p],
                .names = buf.names[n..][0..n],
                .ends = buf.ends[f..][0..f],
            },
        };
    }

    /// Reads one message. Messages the translator does not know are ignored.
    pub fn feed(t: *Translator, m: Msg) void {
        switch (@as(Wm, @fromBackingInt(@intCast(m.msg)))) {
            .size => {
                // A minimized window keeps the size it had, so the UI does not lay out for 0 x 0.
                if (m.wparam == size_minimized) return;
                const s = words(m.lparam);
                t.client = .{ @floatFromInt(s[0]), @floatFromInt(s[1]) };
                t.in.viewport = .{ t.client[0] / t.in.scale, t.client[1] / t.in.scale };
            },
            // The window moved to a monitor of another DPI, or that monitor's scale changed.
            // The shell resizes the window to the suggested rectangle, whose WM_SIZE follows.
            .dpichanged => t.setDpi(@as(u16, @truncate(m.wparam))),
            .close => t.closed = true,
            // Keys released while another window had the focus never send WM_KEYUP.
            .killfocus => {
                t.in.keys = .{};
                t.in.mods = .{};
            },
            .keydown, .syskeydown => t.key(m.lparam, true),
            .keyup, .syskeyup => t.key(m.lparam, false),
            .char => t.char(@truncate(m.wparam)),
            .mousemove, .lbuttondown, .lbuttonup, .rbuttondown, .rbuttonup, .mbuttondown, .mbuttonup => {
                const p = words(m.lparam);
                t.in.pointer = .{ @as(f32, @floatFromInt(p[0])) / t.in.scale, @as(f32, @floatFromInt(p[1])) / t.in.scale };
                t.in.buttons = .{ .left = m.wparam & mk_left != 0, .right = m.wparam & mk_right != 0, .middle = m.wparam & mk_middle != 0 };
            },
            // Positive: the wheel turned away from the user, which scrolls toward the start
            // (`Input.wheel`). Tilting right scrolls toward the end, so it is negated. lParam is
            // in screen coordinates; the pointer comes from the mouse moves.
            .mousewheel => t.in.wheel[1] += notches(m.wparam),
            .mousehwheel => t.in.wheel[0] -= notches(m.wparam),
            .mouseleave => t.in.pointer = .{ -1, -1 },
            _ => {},
        }
    }

    /// Physical pixels per logical pixel from the window's DPI (`GetDpiForWindow`,
    /// `WM_DPICHANGED`): 1 at 96, 1.5 at 144, 2 at 192. The client keeps its physical size
    /// until the next `WM_SIZE`.
    pub fn setDpi(t: *Translator, dpi: u32) void {
        t.in.scale = @as(f32, @floatFromInt(@max(dpi, 1))) / dpi_default;
        t.in.viewport = .{ t.client[0] / t.in.scale, t.client[1] / t.in.scale };
    }

    fn notches(wp: usize) f32 {
        const delta: i16 = @bitCast(@as(u16, @truncate(wp >> 16)));
        return @as(f32, @floatFromInt(delta)) / wheel_delta;
    }

    /// A key message: lParam has the scancode (bits 16 to 23), the extended flag (24) and
    /// whether the key was already down (30), which makes a press a repeat.
    fn key(t: *Translator, lp: isize, down: bool) void {
        const bits: usize = @bitCast(lp);
        const code = hid[((bits >> 17) & 0x80) | ((bits >> 16) & 0x7f)];
        if (code == 0) return;
        const k = &t.in.keys.bits[code >> 6];
        const bit = @as(u64, 1) << @as(u6, @truncate(code));
        k.* = if (down) k.* | bit else k.* & ~bit;
        // Modifiers from the held keys: HID 0xE0 to 0xE7 are left Ctrl, Shift, Alt, GUI, then right.
        const mod: u8 = @truncate(t.in.keys.bits[3] >> 32);
        t.in.mods = .{ .ctrl = mod & 0x11 != 0, .shift = mod & 0x22 != 0, .alt = mod & 0x44 != 0, .cmd = mod & 0x88 != 0 };
        const kind: Input.Event.Kind = if (!down) .release else if ((bits >> 30) & 1 != 0) .repeat else .press;
        t.push(.{ .kind = kind, .mods = t.in.mods, .code = code });
    }

    /// A UTF-16 unit of typed text. Control characters (Backspace, Tab, Enter, Ctrl+letter) are
    /// not text; their key events carry them.
    fn char(t: *Translator, unit: u16) void {
        if (std.unicode.utf16IsHighSurrogate(unit)) {
            t.high = unit;
            return;
        }
        const high = t.high;
        t.high = 0;
        const cp: u21 = if (std.unicode.utf16IsLowSurrogate(unit))
            std.unicode.utf16DecodeSurrogatePair(&.{ high, unit }) catch return
        else
            unit;
        if (cp < 0x20 or cp == 0x7f) return;
        t.typeCodepoint(cp);
    }

    /// Appends `cp` to the frame's text as one `.text` event.
    fn typeCodepoint(t: *Translator, cp: u21) void {
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &utf8) catch return;
        if (t.text.len - t.n_text < n or t.n_events == t.events.len) {
            t.dropped += 1;
            return;
        }
        @memcpy(t.text[t.n_text..][0..n], utf8[0..n]);
        t.push(.{ .kind = .text, .mods = t.in.mods, .at = t.n_text, .len = @intCast(n) });
        t.n_text += @intCast(n);
    }

    /// One path of a drop (`DragQueryFileW`), UTF-16. A path that does not fit, or is not
    /// valid UTF-16, is left out and counted in `dropped`.
    pub fn dropFile(t: *Translator, path: []const u16) void {
        var len: usize = 0;
        var it = std.unicode.Utf16LeIterator.init(path);
        while (it.nextCodepoint() catch {
            t.dropped += 1;
            return;
        }) |cp| len += std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
        if (t.names.len - t.n_names < len or t.n_files == t.ends.len) {
            t.dropped += 1;
            return;
        }
        t.n_names += @intCast(std.unicode.utf16LeToUtf8(t.names[t.n_names..], path) catch unreachable);
        t.ends[t.n_files] = t.n_names;
        t.n_files += 1;
    }

    /// The drop itself (`WM_DROPFILES`), at `pos` in client pixels (`DragQueryPoint`), after
    /// its paths. Its frame has `Events.files` with `drop` and `hover` set.
    pub fn drop(t: *Translator, pos: [2]i32) void {
        t.dropped_files = true;
        t.drop_at = .{ @as(f32, @floatFromInt(pos[0])) / t.in.scale, @as(f32, @floatFromInt(pos[1])) / t.in.scale };
    }

    /// The clock, in seconds since the shell started: sets `Input.time`, and `dt` to the time
    /// since the last frame. The scheduler's timers (`scheduler.deadline`) run on it.
    pub fn clock(t: *Translator, seconds: f64) void {
        t.in.dt = @floatCast(@max(seconds - t.in.time, 0));
        t.in.time = seconds;
    }

    /// The IME's composition string (`ImmGetCompositionStringW` with `GCS_COMPSTR`), its
    /// attributes (`GCS_COMPATTR`, one byte per UTF-16 unit) and the caret (`GCS_CURSORPOS`,
    /// in UTF-16 units), as `Events.composition`: UTF-8, with the range the IME converts
    /// (the target clause) or, without one, the caret. Empty `units` ends the composition.
    pub fn compose(t: *Translator, units: []const u16, attrs: []const u8, cursor: u32) void {
        var n: u32 = 0;
        var range: [2]u32 = .{ std.math.maxInt(u32), 0 };
        var caret: u32 = 0;
        var i: usize = 0;
        while (i < units.len) {
            const pair = std.unicode.utf16IsHighSurrogate(units[i]) and i + 1 < units.len;
            const w: usize = if (pair) 2 else 1;
            const cp: u21 = if (pair) std.unicode.utf16DecodeSurrogatePair(units[i..][0..2]) catch 0xfffd else units[i];
            const len = std.unicode.utf8CodepointSequenceLength(cp) catch 3;
            if (t.preedit.len - n < len) break;
            n += std.unicode.utf8Encode(cp, t.preedit[n..]) catch blk: {
                t.preedit[n..][0..3].* = "\u{fffd}".*;
                break :blk 3;
            };
            const attr = if (i < attrs.len) attrs[i] else 0;
            if (attr == attr_target_converted or attr == attr_target_notconverted) {
                range = .{ @min(range[0], n - len), n };
            }
            i += w;
            if (i <= cursor) caret = n;
        }
        t.composition.len = n;
        t.composition.range = if (range[0] <= range[1]) range else .{ caret, caret };
    }

    /// Text the IME committed (`GCS_RESULTSTR`): typed, as one `.text` event.
    pub fn commit(t: *Translator, units: []const u16) void {
        t.paste(units);
    }

    /// Clipboard text (`CF_UNICODETEXT`) delivered as typed text, the way `keyboard.Clipboard`
    /// asks a host to answer a paste: one `.text` event, line ends as `\n`, other control
    /// characters but tabs left out. A paste that does not fit is dropped whole.
    pub fn paste(t: *Translator, units: []const u16) void {
        const at = t.n_text;
        var it = std.unicode.Utf16LeIterator.init(units);
        while (it.nextCodepoint() catch null) |cp| {
            if (cp < 0x20 and cp != '\n' and cp != '\t') continue;
            if (cp == 0x7f) continue;
            const n = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
            if (t.text.len - t.n_text < n) {
                t.n_text = at;
                t.dropped += 1;
                return;
            }
            _ = std.unicode.utf8Encode(cp, t.text[t.n_text..][0..n]) catch unreachable;
            t.n_text += n;
        }
        if (t.n_text == at) return;
        if (t.n_events == t.events.len) {
            t.n_text = at;
            t.dropped += 1;
            return;
        }
        t.push(.{ .kind = .text, .mods = t.in.mods, .at = at, .len = t.n_text - at });
    }

    fn push(t: *Translator, e: Input.Event) void {
        if (t.n_events == t.events.len) {
            t.dropped += 1;
            return;
        }
        t.events[t.n_events] = e;
        t.n_events += 1;
    }

    /// This frame's events: the messages since the last `frame`, copied to `out`, where `ev`
    /// points until the next call. Then the next frame starts empty. False once the window
    /// was closed.
    pub fn frame(t: *Translator, ev: *Events) bool {
        const o = t.out;
        @memcpy(o.text[0..t.n_text], t.text[0..t.n_text]);
        @memcpy(o.events[0..t.n_events], t.events[0..t.n_events]);
        @memcpy(o.preedit[0..t.composition.len], t.preedit[0..t.composition.len]);
        @memcpy(o.names[0..t.n_names], t.names[0..t.n_names]);
        @memcpy(o.ends[0..t.n_files], t.ends[0..t.n_files]);
        ev.in = t.in;
        ev.in.text = o.text[0..t.n_text];
        ev.in.events = o.events[0..t.n_events];
        ev.composition = .{ .text = o.preedit[0..t.composition.len], .range = t.composition.range };
        // ponytail: WM_DROPFILES says nothing while files are dragged over the window, so
        // `hover` is only set on the drop frame and drop targets cannot highlight before it.
        // Over-the-window feedback needs an OLE IDropTarget; add it when a UI asks for it.
        const dropped = t.dropped_files;
        ev.files = .{
            .names = o.names[0..t.n_names],
            .ends = o.ends[0 .. t.n_files * @intFromBool(dropped)],
            .pos = t.drop_at,
            .hover = dropped,
            .drop = dropped,
        };
        t.dropped_files = false;
        t.n_names = 0;
        t.n_files = 0;
        t.in.wheel = .{ 0, 0 };
        t.in.scroll = .{ 0, 0 };
        t.n_text = 0;
        t.n_events = 0;
        return !t.closed;
    }
};

/// `INFINITE`: a wait with no timeout.
pub const infinite: u32 = 0xffff_ffff;

/// Milliseconds `wait` blocks for (`MsgWaitForMultipleObjectsEx`), for a wait of `seconds`
/// (`scheduler.wake`) at `pace` on a display refreshing `hz` times a second. Rounded up, so
/// a timer is not woken a millisecond early and then spun on. `.display` waits one refresh,
/// so an animation runs at the display's rate rather than as fast as the CPU allows.
pub fn waitMs(seconds: f32, pace: Pace, hz: u32) u32 {
    if (pace == .display) return (1000 + @max(hz, 1) - 1) / @max(hz, 1);
    if (!(seconds > 0)) return 0;
    // Past 4e6 s (46 days) the milliseconds would not fit below `infinite`.
    if (seconds >= 4e6) return infinite;
    return @intFromFloat(@ceil(seconds * 1000));
}

/// `GCS_COMPATTR` values of the clause being converted.
const attr_target_converted = 1;
const attr_target_notconverted = 3;

/// `r` (logical pixels) in physical pixels at `scale`, rounded out to whole pixels: left, top,
/// right, bottom, for the IME's candidate and composition windows.
pub fn physicalRect(r: Rect, scale: f32) [4]i32 {
    return .{
        @intFromFloat(@floor(r.x0 * scale)), @intFromFloat(@floor(r.y0 * scale)),
        @intFromFloat(@ceil(r.x1 * scale)),  @intFromFloat(@ceil(r.y1 * scale)),
    };
}

/// `utf8` as clipboard text (`CF_UNICODETEXT`): UTF-16 with `\r\n` line ends and a NUL, in
/// `out`, which needs `clipboardUnits(utf8.len)` units. Null if `utf8` is not valid UTF-8.
pub fn clipboardText(utf8: []const u8, out: []u16) ?[]u16 {
    if (!std.unicode.utf8ValidateSlice(utf8)) return null;
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, utf8, '\n');
    while (lines.next()) |line| {
        n += std.unicode.utf8ToUtf16Le(out[n..], line) catch unreachable;
        if (lines.index == null) break;
        out[n..][0..2].* = .{ '\r', '\n' };
        n += 2;
    }
    out[n] = 0;
    return out[0 .. n + 1];
}

/// UTF-16 units `clipboardText` may need for `len` bytes of UTF-8: one per byte at most, two
/// for a `\n`, and the NUL.
pub fn clipboardUnits(len: usize) usize {
    return 2 * len + 1;
}

/// Recorded window messages, replayed one frame per `next`, so tests drive the translator (and,
/// on Windows, a real window) with the messages a session produced. UTF-8 text, one line each:
///
///     # comment              blank lines and comments anywhere
///     frame                  starts a frame; the messages below it arrive before its poll
///     size 0 800:600         a message: its `Wm` name, wParam, lParam
///
/// wParam and lParam are integers (decimal, or hex with 0x; lParam may be negative) or `lo:hi`,
/// two signed 16-bit words packed as `MAKELPARAM` packs them.
pub const Replay = struct {
    src: []const u8,
    at: usize = 0,
    /// 1-based number of the last line read; on an error, the line at fault.
    line: u32 = 0,

    pub const Error = error{ Syntax, BufferFull };

    /// The messages of the next frame, in `buf`, or null after the last frame.
    pub fn next(r: *Replay, buf: []Msg) Error!?[]const Msg {
        while (true) {
            const l = r.take() orelse return null;
            if (blank(l)) continue;
            if (!std.mem.eql(u8, l, "frame")) return error.Syntax;
            break;
        }
        var n: usize = 0;
        while (r.peek()) |l| {
            if (std.mem.eql(u8, l, "frame")) break;
            _ = r.take();
            if (blank(l)) continue;
            var it = std.mem.tokenizeScalar(u8, l, ' ');
            const name = it.next().?;
            const wm = std.meta.stringToEnum(Wm, name) orelse return error.Syntax;
            const wp = try word(it.next() orelse return error.Syntax);
            const lp = try word(it.next() orelse return error.Syntax);
            if (it.next() != null) return error.Syntax;
            if (n == buf.len) return error.BufferFull;
            buf[n] = .{ .msg = @backingInt(wm), .wparam = @bitCast(truncated(wp)), .lparam = truncated(lp) };
            n += 1;
        }
        return buf[0..n];
    }

    fn truncated(v: i64) isize {
        return @truncate(v);
    }

    fn word(s: []const u8) Error!i64 {
        if (std.mem.indexOfScalar(u8, s, ':')) |c| {
            const lo = std.fmt.parseInt(i32, s[0..c], 0) catch return error.Syntax;
            const hi = std.fmt.parseInt(i32, s[c + 1 ..], 0) catch return error.Syntax;
            return lparam(lo, hi);
        }
        return std.fmt.parseInt(i64, s, 0) catch error.Syntax;
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
        const s = std.mem.trimStart(u8, l, " ");
        return s.len == 0 or s[0] == '#';
    }
};

const testing = std.testing;

test "lparam: packs and unpacks signed words" {
    try testing.expectEqual([2]i32{ 800, 600 }, words(lparam(800, 600)));
    // A pointer captured left of and above the window has negative client coordinates.
    try testing.expectEqual([2]i32{ -5, -32768 }, words(lparam(-5, -32768)));
    try testing.expectEqual(@as(isize, 0x0258_0320), lparam(800, 600));
}

test "translate: size and close from a recording" {
    var r: Replay = .{ .src =
        \\frame
        \\size 0 800:600
        \\frame
        \\# minimized: the size stays
        \\size 1 0:0
        \\frame
        \\size 2 1024:768
        \\close 0 0
    };
    var buf: [4]Msg = undefined;
    var t: Translator = .{};
    var ev: Events = .{};
    const want = [_][2]f32{ .{ 800, 600 }, .{ 800, 600 }, .{ 1024, 768 } };
    for (want, 0..) |vp, i| {
        for ((try r.next(&buf)).?) |m| t.feed(m);
        try testing.expectEqual(i < 2, t.frame(&ev));
        try testing.expectEqual(vp, ev.in.viewport);
    }
    try testing.expectEqual(null, try r.next(&buf));
}

test "replay: errors name the line, unknown messages are refused" {
    var buf: [1]Msg = undefined;
    var r: Replay = .{ .src = "frame\nsize 0\n" };
    try testing.expectError(error.Syntax, r.next(&buf));
    try testing.expectEqual(@as(u32, 2), r.line);
    r = .{ .src = "frame\npaint 0 0\n" };
    try testing.expectError(error.Syntax, r.next(&buf));
    r = .{ .src = "frame\nsize 0 0\nclose 0 0\n" };
    try testing.expectError(error.BufferFull, r.next(&buf));
}

const context = @import("../../runtime/context.zig");
const mem = @import("../../core/mem.zig");
const InputReplay = @import("../../core/input.zig").Replay;
const example = @import("../example.zig");

const example_limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
var example_buffer: [context.Context.requiredBytes(example_limits)]u8 align(mem.column_align) = undefined;

test "translate: the example's messages give the headless recording's input and run the example" {
    // The same session twice: as window messages (testdata/example.msgs) and as the Input the
    // headless shell replays (src/shell/testdata/example.replay). Frame by frame, the
    // translator must give what the recording holds.
    var msgs: Replay = .{ .src = @embedFile("testdata/example.msgs") };
    var want: InputReplay = .{ .src = @embedFile("../testdata/example.replay") };
    var text: [64]u8 = undefined;
    var events: [16]Input.Event = undefined;
    var want_text: [64]u8 = undefined;
    var want_events: [16]Input.Event = undefined;
    var contacts: [4]Input.Contact = undefined;
    var buf: [16]Msg = undefined;
    var t: Translator = .init(.{ .text = &text, .events = &events });
    var ctx = try context.Context.init(&example_buffer, example_limits);
    var app: example.App = .{};
    var ev: Events = .{};
    var frames: u32 = 0;
    // The system cursor shown after each poll: the last frame's, as the shell applies it.
    var shown: [15]u16 = undefined;
    var cursor: u16 = cursor_ids[@backingInt(Cursor.arrow)];
    while (try msgs.next(&buf)) |frame_msgs| : (frames += 1) {
        defer shown[frames] = cursor;
        for (frame_msgs) |m| t.feed(m);
        try testing.expect(t.frame(&ev));
        const in = (try want.next(.{ .text = &want_text, .events = &want_events, .contacts = &contacts })).?;
        try testing.expectEqual(in.stamp(), ev.in.stamp());
        try testing.expectEqual(in.pointer, ev.in.pointer);
        try testing.expectEqual(in.buttons, ev.in.buttons);
        if (!ctx.needsFrame(&ev.in)) continue;
        var f = ctx.begin(&ev.in);
        app.build(&f, &ev);
        cursor = cursor_ids[@backingInt(f.end(.{}).platform.cursor)];
    }
    // Over Reset, Add layer and the slider the hand shows; the headless shell's cursors.
    const a = 32512;
    const h = 32649;
    try testing.expectEqualSlices(u16, &.{ a, a, a, h, h, h, h, h, h, a, a, a, a, a, a }, &shown);
    try testing.expectEqual(null, try want.next(.{ .text = &want_text, .events = &want_events, .contacts = &contacts }));
    try testing.expectEqual(@as(u32, 15), frames);
    // The headless shell's results (src/shell/headless.zig).
    try testing.expectEqual(@as(u32, 13), app.builds);
    try testing.expectEqual(@as(u32, 1), app.resets);
    try testing.expectEqual(@as(u32, 4), app.layers);
    try testing.expectApproxEqAbs(@as(f32, 3), app.exposure, 0.01);
}

test "translate: keys, typed text, wheel and leaving the window" {
    var r: Replay = .{ .src =
        \\frame
        \\# Shift down, then A (scancode 0x1e) pressed, held (repeat) and typed twice.
        \\keydown 0x10 0x002a0001
        \\keydown 0x41 0x001e0001
        \\char 0x41 0x001e0001
        \\keydown 0x41 0x401e0001
        \\char 0x41 0x401e0001
        \\# e acute, then U+1F600 as a surrogate pair.
        \\char 0xe9 0
        \\char 0xd83d 0
        \\char 0xde00 0
        \\mousewheel 0xff100000 100:100
        \\mousehwheel 0x003c0000 100:100
        \\frame
        \\# Shift and A up; right Ctrl (extended 0x1d) + C: a press with ctrl, no text for 0x03.
        \\keyup 0x41 0xc01e0001
        \\keyup 0x10 0xc02a0001
        \\keydown 0x11 0x011d0001
        \\keydown 0x43 0x002e0001
        \\char 0x03 0x002e0001
        \\# Left arrow is extended 0x4b; without the flag it is keypad 4.
        \\keydown 0x25 0x014b0001
        \\keydown 0x64 0x004b0001
        \\mousemove 0 10:-3
        \\frame
        \\killfocus 0 0
        \\mouseleave 0 0
    };
    var text: [16]u8 = undefined;
    var events: [16]Input.Event = undefined;
    var buf: [16]Msg = undefined;
    var t: Translator = .init(.{ .text = &text, .events = &events });
    var ev: Events = .{};

    for ((try r.next(&buf)).?) |m| t.feed(m);
    _ = t.frame(&ev);
    const shift: Input.Mods = .{ .shift = true };
    try testing.expectEqualStrings("AA\u{e9}\u{1f600}", ev.in.text);
    try testing.expectEqualSlices(Input.Event, &.{
        .{ .kind = .press, .code = 0xe1, .mods = shift },
        .{ .kind = .press, .code = 0x04, .mods = shift },
        .{ .kind = .text, .at = 0, .len = 1, .mods = shift },
        .{ .kind = .repeat, .code = 0x04, .mods = shift },
        .{ .kind = .text, .at = 1, .len = 1, .mods = shift },
        .{ .kind = .text, .at = 2, .len = 2, .mods = shift },
        .{ .kind = .text, .at = 4, .len = 4, .mods = shift },
    }, ev.in.events);
    try testing.expect(ev.in.keys.down(0x04) and ev.in.keys.down(0xe1));
    try testing.expectEqual([2]f32{ -0.5, -2 }, ev.in.wheel);

    for ((try r.next(&buf)).?) |m| t.feed(m);
    _ = t.frame(&ev);
    const ctrl: Input.Mods = .{ .ctrl = true };
    try testing.expectEqualStrings("", ev.in.text);
    try testing.expectEqualSlices(Input.Event, &.{
        .{ .kind = .release, .code = 0x04, .mods = shift },
        .{ .kind = .release, .code = 0xe1 },
        .{ .kind = .press, .code = 0xe4, .mods = ctrl },
        .{ .kind = .press, .code = 0x06, .mods = ctrl },
        .{ .kind = .press, .code = 0x50, .mods = ctrl },
        .{ .kind = .press, .code = 0x5c, .mods = ctrl },
    }, ev.in.events);
    try testing.expectEqual([2]f32{ 0, 0 }, ev.in.wheel);
    try testing.expectEqual([2]f32{ 10, -3 }, ev.in.pointer);
    try testing.expectEqual(ctrl, ev.in.mods);

    // Focus lost: held keys are let go; the pointer left.
    for ((try r.next(&buf)).?) |m| t.feed(m);
    _ = t.frame(&ev);
    try testing.expectEqual(Input.Keys{}, ev.in.keys);
    try testing.expectEqual(Input.Mods{}, ev.in.mods);
    try testing.expectEqual([2]f32{ -1, -1 }, ev.in.pointer);
}

test "translate: per-monitor DPI scales the viewport and the pointer" {
    var r: Replay = .{ .src =
        \\frame
        \\# Opened on a 200% monitor: the 800 x 600 client is 1600 x 1200 physical pixels.
        \\dpichanged 192 0
        \\size 0 1600:1200
        \\mousemove 0 200:100
        \\frame
        \\# Dragged to a 150% monitor: the scale changes, then the suggested size arrives.
        \\dpichanged 144 0
        \\frame
        \\size 0 1200:900
        \\mousemove 0 300:150
    };
    var buf: [4]Msg = undefined;
    var t: Translator = .{};
    var ev: Events = .{};
    const want = [_]struct { scale: f32, viewport: [2]f32, pointer: [2]f32 }{
        .{ .scale = 2, .viewport = .{ 800, 600 }, .pointer = .{ 100, 50 } },
        // Between the two messages the old physical size is shown at the new scale.
        .{ .scale = 1.5, .viewport = .{ 1600.0 / 1.5, 1200.0 / 1.5 }, .pointer = .{ 100, 50 } },
        .{ .scale = 1.5, .viewport = .{ 800, 600 }, .pointer = .{ 200, 100 } },
    };
    for (want) |w| {
        for ((try r.next(&buf)).?) |m| t.feed(m);
        _ = t.frame(&ev);
        try testing.expectEqual(w.scale, ev.in.scale);
        try testing.expectEqual(w.viewport, ev.in.viewport);
        try testing.expectEqual(w.pointer, ev.in.pointer);
    }
}

test "clipboard: pasted text is typed in one event, copied text gets CRLF" {
    var text: [32]u8 = undefined;
    var events: [4]Input.Event = undefined;
    var t: Translator = .init(.{ .text = &text, .events = &events });
    var ev: Events = .{};
    t.feed(.{ .msg = @backingInt(Wm.char), .wparam = 'x' });
    t.paste(std.unicode.utf8ToUtf16LeStringLiteral("one\r\ntwo\t\u{1f600}\x07"));
    _ = t.frame(&ev);
    try testing.expectEqualStrings("xone\ntwo\t\u{1f600}", ev.in.text);
    try testing.expectEqual(@as(usize, 2), ev.in.events.len);
    try testing.expectEqualStrings("one\ntwo\t\u{1f600}", ev.in.typed(ev.in.events[1]));

    // Too long for what is left: nothing of it is typed.
    t.paste(std.unicode.utf8ToUtf16LeStringLiteral("0123456789012345678901234567890123456789"));
    _ = t.frame(&ev);
    try testing.expectEqualStrings("", ev.in.text);
    try testing.expectEqual(@as(u32, 1), t.dropped);

    var out: [clipboardUnits(8)]u16 = undefined;
    const want = std.unicode.utf8ToUtf16LeStringLiteral("a\r\n\u{e9}\u{1f600}");
    try testing.expectEqualSlices(u16, want[0 .. want.len + 1], clipboardText("a\n\u{e9}\u{1f600}", &out).?);
    try testing.expectEqual(null, clipboardText("\xff", &out));
}

test "ime: a composition is shown, converted, then committed as typed text" {
    var text: [32]u8 = undefined;
    var events: [4]Input.Event = undefined;
    var preedit: [32]u8 = undefined;
    var t: Translator = .init(.{ .text = &text, .events = &events, .preedit = &preedit });
    var ev: Events = .{};
    const u = std.unicode.utf8ToUtf16LeStringLiteral;

    // Typing "nihon": the reading so far, caret at its end, nothing converted.
    t.compose(u("\u{306b}\u{307b}\u{3093}"), &.{ 0, 0, 0 }, 3);
    _ = t.frame(&ev);
    try testing.expectEqualStrings("\u{306b}\u{307b}\u{3093}", ev.composition.text);
    try testing.expectEqual([2]u32{ 9, 9 }, ev.composition.range);
    try testing.expectEqualStrings("", ev.in.text);

    // Space converts: two clauses, the first ("nichi" -> U+65E5) the target.
    t.compose(u("\u{65e5}\u{672c}"), &.{ attr_target_converted, 2 }, 1);
    _ = t.frame(&ev);
    try testing.expectEqual([2]u32{ 0, 3 }, ev.composition.range);

    // A surrogate pair and a caret after it.
    t.compose(u("a\u{20bb7}b"), &.{ 0, 0, 0, 0 }, 3);
    _ = t.frame(&ev);
    try testing.expectEqualStrings("a\u{20bb7}b", ev.composition.text);
    try testing.expectEqual([2]u32{ 5, 5 }, ev.composition.range);

    // Enter commits: the result is typed, the composition ends.
    t.commit(u("\u{65e5}\u{672c}"));
    t.compose(&.{}, &.{}, 0);
    _ = t.frame(&ev);
    try testing.expectEqualStrings("\u{65e5}\u{672c}", ev.in.text);
    try testing.expectEqualStrings("", ev.composition.text);
    try testing.expectEqual(Input.Event.Kind.text, ev.in.events[0].kind);

    // A composition longer than the buffer is cut at a character.
    var small: [8]u8 = undefined;
    t = .init(.{ .text = &text, .events = &events, .preedit = &small });
    t.compose(u("\u{65e5}\u{672c}"), &.{}, 2);
    _ = t.frame(&ev);
    try testing.expectEqualStrings("\u{65e5}", ev.composition.text);

    try testing.expectEqual([4]i32{ 15, 30, 61, 91 }, physicalRect(.{ .x0 = 10.4, .y0 = 20, .x1 = 40.2, .y1 = 60.5 }, 1.5));
}

test "timers: the clock and the wait for each pace" {
    var t: Translator = .{};
    var ev: Events = .{};
    t.clock(0.5);
    t.clock(0.52);
    _ = t.frame(&ev);
    try testing.expectEqual(@as(f64, 0.52), ev.in.time);
    try testing.expectApproxEqAbs(@as(f32, 0.02), ev.in.dt, 1e-6);

    const inf = std.math.inf(f32);
    try testing.expectEqual(infinite, waitMs(inf, .idle, 60));
    try testing.expectEqual(@as(u32, 0), waitMs(0, .once, 60));
    try testing.expectEqual(@as(u32, 0), waitMs(std.math.nan(f32), .timer, 60));
    // A hover delay of 0.4 s, and a timer 1.5 ms away: never early.
    try testing.expectEqual(@as(u32, 400), waitMs(0.4, .timer, 60));
    try testing.expectEqual(@as(u32, 2), waitMs(0.0015, .timer, 60));
    // Animating: one refresh, whatever `scheduler.wake` said.
    try testing.expectEqual(@as(u32, 17), waitMs(0, .display, 60));
    try testing.expectEqual(@as(u32, 7), waitMs(0, .display, 144));
}

test "windows: two windows on one thread keep their frames apart" {
    // One thread, two windows. Each poll dispatches every window's messages, so window A's
    // keys can arrive during B's poll, after A's frame was handed out but before it is built.
    var a_text: [16]u8 = undefined;
    var a_events: [8]Input.Event = undefined;
    var b_text: [16]u8 = undefined;
    var b_events: [8]Input.Event = undefined;
    var a: Translator = .init(.{ .text = &a_text, .events = &a_events });
    var b: Translator = .init(.{ .text = &b_text, .events = &b_events });
    const char = @backingInt(Wm.char);
    var ev_a: Events = .{};
    var ev_b: Events = .{};

    a.feed(.{ .msg = @backingInt(Wm.size), .lparam = lparam(400, 300) });
    a.feed(.{ .msg = char, .wparam = 'a' });
    b.feed(.{ .msg = char, .wparam = 'b' });
    _ = a.frame(&ev_a); // poll A
    a.feed(.{ .msg = char, .wparam = 'x' }); // during poll B
    b.feed(.{ .msg = @backingInt(Wm.close) });
    try testing.expect(!b.frame(&ev_b)); // poll B: B was closed, A goes on
    // Build A, build B: each sees its own frame, unchanged.
    try testing.expectEqualStrings("a", ev_a.in.text);
    try testing.expectEqual([2]f32{ 400, 300 }, ev_a.in.viewport);
    try testing.expectEqualStrings("b", ev_b.in.text);
    try testing.expectEqual([2]f32{ 800, 600 }, ev_b.in.viewport);
    // A's late key is in its next frame.
    try testing.expect(a.frame(&ev_a));
    try testing.expectEqualStrings("x", ev_a.in.text);
}

test "drop: dropped paths reach one frame, at the drop point" {
    var text: [8]u8 = undefined;
    var events: [4]Input.Event = undefined;
    var names: [64]u8 = undefined;
    var ends: [4]u32 = undefined;
    var t: Translator = .init(.{ .text = &text, .events = &events, .names = &names, .ends = &ends });
    var ev: Events = .{};
    const u = std.unicode.utf8ToUtf16LeStringLiteral;
    t.setDpi(192);
    t.dropFile(u("C:\\a.txt"));
    t.dropFile(u("C:\\\u{65e5}.png"));
    // Too long for what is left of its 32 bytes: left out, the others kept.
    t.dropFile(u("C:\\0123456789012345678901234567890123456789"));
    t.drop(.{ 300, 200 });
    _ = t.frame(&ev);
    try testing.expectEqual(@as(usize, 2), ev.files.count());
    try testing.expectEqualStrings("C:\\a.txt", ev.files.path(0));
    try testing.expectEqualStrings("C:\\\u{65e5}.png", ev.files.path(1));
    try testing.expectEqual([2]f32{ 150, 100 }, ev.files.pos);
    try testing.expect(ev.files.drop and ev.files.hover);
    try testing.expectEqual(@as(u32, 1), t.dropped);
    // The next frame has no files.
    _ = t.frame(&ev);
    try testing.expectEqual(@as(usize, 0), ev.files.count());
    try testing.expect(!ev.files.drop and !ev.files.hover);
}

test "translate: a full frame drops what does not fit and counts it" {
    var text: [4]u8 = undefined;
    var events: [4]Input.Event = undefined;
    var t: Translator = .init(.{ .text = &text, .events = &events });
    var ev: Events = .{};
    for ("abc") |c| t.feed(.{ .msg = @backingInt(Wm.char), .wparam = c });
    _ = t.frame(&ev);
    try testing.expectEqualStrings("ab", ev.in.text);
    try testing.expectEqual(@as(u32, 1), t.dropped);
}
