//! AppKit events as `Events`: the part of the macOS shell (macos.zig) that touches no OS, so it
//! builds and is tested on any host. The shell's view and window-delegate methods read each
//! NSEvent or notification into plain values and hand them to the `Translator`; `poll` drains
//! AppKit's queue and calls `frame`. Everything the translator keeps is carved from the caller's
//! buffers; it allocates nothing.
//!
//! Coordinates are AppKit's: points (logical pixels; the backing scale is apart), window
//! coordinates with the origin at the bottom left. The translator flips them to the top-left
//! origin `Input` uses. Values are the AppKit headers' (NSEvent.h, Events.h).

const std = @import("std");
const Input = @import("../../core/input.zig").Input;
const Events = @import("../iface.zig").Events;
const Cursor = @import("../../runtime/context.zig").Cursor;
const Rect = @import("../../core/types.zig").Rect;

/// The NSEvent types the translator reads, by their `NSEventType` values.
pub const Kind = enum(u32) {
    left_down = 1,
    left_up = 2,
    right_down = 3,
    right_up = 4,
    moved = 5,
    left_dragged = 6,
    right_dragged = 7,
    entered = 8,
    exited = 9,
    key_down = 10,
    key_up = 11,
    flags_changed = 12,
    scroll = 22,
    other_down = 25,
    other_up = 26,
    other_dragged = 27,
    _,
};

/// The fields of one NSEvent the translator reads. Only those its kind has are read: AppKit
/// raises for `keyCode` on a mouse event, so the view fills them by kind.
pub const Event = struct {
    kind: Kind,
    /// `locationInWindow`: points, origin at the bottom left.
    at: [2]f64 = .{ 0, 0 },
    /// `modifierFlags`.
    flags: u64 = 0,
    /// `keyCode` (a virtual key, kVK_*) for key events; `buttonNumber` for other-mouse events.
    code: u16 = 0,
    /// `isARepeat`, for key-down events.
    repeat: bool = false,
    /// `scrollingDeltaX`, `scrollingDeltaY`: lines, or points when `precise`
    /// (`hasPreciseScrollingDeltas`, trackpads and Magic Mouse).
    delta: [2]f64 = .{ 0, 0 },
    precise: bool = false,
};

/// One thing the window reported: what the view and window-delegate methods hand the translator.
/// `Replay` reads these from a recording.
pub const Record = union(enum) {
    /// An NSEvent the view received.
    event: Event,
    /// `insertText:`: text typed, after the key's events, or what an input method committed.
    insert: []const u8,
    /// `setMarkedText:selectedRange:replacementRange:`: the input method's composition, and the
    /// selected range in it in UTF-16 units (location, length). Empty text ends it.
    mark: Mark,
    /// windowDidResize: the content view's size, in points.
    resize: [2]f64,
    /// viewDidChangeBackingProperties: the window's `backingScaleFactor`, physical pixels per
    /// point (2 on Retina displays). It changes when the window moves to another display.
    scale: f64,
    /// windowDidResignKey: the window lost the keyboard.
    resign,
    /// windowShouldClose: the user asked to close the window.
    close,
};

pub const Mark = struct { text: []const u8, selected: [2]u32 = .{ 0, 0 } };

/// `NSEventModifierFlags`: the device-independent modifiers.
pub const flag_caps_lock: u64 = 1 << 16;
pub const flag_shift: u64 = 1 << 17;
pub const flag_control: u64 = 1 << 18;
pub const flag_option: u64 = 1 << 19;
pub const flag_command: u64 = 1 << 20;

/// USB HID usage (the scancodes of `Input.Keys`, src/interact/keyboard.zig) of each macOS
/// virtual key code (`kVK_*`, HIToolbox Events.h), which names a key by its place on an ANSI
/// keyboard. 0: no key (Fn, and codes Apple does not assign).
pub const hid: [128]u8 = .{
    0x04, 0x16, 0x07, 0x09, 0x0b, 0x0a, 0x1d, 0x1b, 0x06, 0x19, 0x64, 0x05, 0x14, 0x1a, 0x08, 0x15, // A S D F H G Z X C V ISO§ B Q W E R
    0x1c, 0x17, 0x1e, 0x1f, 0x20, 0x21, 0x23, 0x22, 0x2e, 0x26, 0x24, 0x2d, 0x25, 0x27, 0x30, 0x12, // Y T 1 2 3 4 6 5 = 9 7 - 8 0 ] O
    0x18, 0x2f, 0x0c, 0x13, 0x28, 0x0f, 0x0d, 0x34, 0x0e, 0x33, 0x31, 0x36, 0x38, 0x11, 0x10, 0x37, // U [ I P Return L J ' K ; \ , / N M .
    0x2b, 0x2c, 0x35, 0x2a, 0x00, 0x29, 0xe7, 0xe3, 0xe1, 0x39, 0xe2, 0xe0, 0xe5, 0xe6, 0xe4, 0x00, // Tab Space ` Backspace - Esc RCmd LCmd LShift Caps LOpt LCtrl RShift ROpt RCtrl Fn
    0x6c, 0x63, 0x00, 0x55, 0x00, 0x57, 0x00, 0x53, 0x80, 0x81, 0x7f, 0x54, 0x58, 0x00, 0x56, 0x6d, // F17 KP. - KP* - KP+ - Clear VolUp VolDown Mute KP/ KPEnter - KP- F18
    0x6e, 0x67, 0x62, 0x59, 0x5a, 0x5b, 0x5c, 0x5d, 0x5e, 0x5f, 0x6f, 0x60, 0x61, 0x89, 0x87, 0x85, // F19 KP= KP0..KP7 F20 KP8 KP9 Yen Ro KPComma
    0x3e, 0x3f, 0x40, 0x3c, 0x41, 0x42, 0x91, 0x44, 0x90, 0x68, 0x6b, 0x69, 0x00, 0x43, 0x65, 0x45, // F5 F6 F7 F3 F8 F9 Eisu F11 Kana F13 F16 F14 - F10 Menu F12
    0x00, 0x6a, 0x49, 0x4a, 0x4b, 0x4c, 0x3d, 0x4d, 0x3b, 0x4e, 0x3a, 0x50, 0x4f, 0x51, 0x52, 0x00, // - F15 Help(Insert) Home PgUp FwdDel F4 End F2 PgDn F1 Left Right Down Up
};

/// The `modifierFlags` bit that says whether the modifier key with this virtual key code is
/// down: the device-dependent bits (IOLLEvent.h NX_DEVICE*KEYMASK) tell left from right; Caps
/// Lock has only its lock state. 0 for keys that are not modifiers.
fn modifierBit(code: u16) u64 {
    return switch (code) {
        0x3b => 0x0001, // left Control
        0x38 => 0x0002, // left Shift
        0x3c => 0x0004, // right Shift
        0x37 => 0x0008, // left Command
        0x36 => 0x0010, // right Command
        0x3a => 0x0020, // left Option
        0x3d => 0x0040, // right Option
        0x3e => 0x2000, // right Control
        0x39 => flag_caps_lock,
        else => 0,
    };
}

/// The NSCursor class method giving the system cursor of each `Platform.cursor`. `grab` is the
/// open hand, as AppKit shows over something that can be dragged.
pub const cursor_names = names: {
    var a: [@typeInfo(Cursor).@"enum".field_names.len][:0]const u8 = undefined;
    a[@backingInt(Cursor.arrow)] = "arrowCursor";
    a[@backingInt(Cursor.pointer)] = "pointingHandCursor";
    a[@backingInt(Cursor.text)] = "IBeamCursor";
    a[@backingInt(Cursor.grab)] = "openHandCursor";
    a[@backingInt(Cursor.resize_h)] = "resizeLeftRightCursor";
    a[@backingInt(Cursor.resize_v)] = "resizeUpDownCursor";
    break :names a;
};

pub const Translator = struct {
    /// Held state, kept from event to event: viewport, scale, pointer, buttons, keys, mods.
    /// The per-frame part (wheel, scroll, text, events) collects the events since the last `frame`.
    in: Input = .{},
    /// windowShouldClose: arrived.
    closed: bool = false,
    /// Caller-owned storage for the frame's typed text and key events.
    text: []u8 = &.{},
    events: []Input.Event = &.{},
    n_text: u32 = 0,
    n_events: u32 = 0,
    /// Key events and text that did not fit the buffers, since `init`.
    dropped: u32 = 0,
    /// The input method's composition as UTF-8, held until it changes or ends (`mark`).
    preedit: []u8 = &.{},
    composition: struct { len: u32 = 0, range: [2]u32 = .{ 0, 0 }, units: u32 = 0 } = .{},

    /// `preedit` holds the longest composition shown; a longer one is cut at a character.
    pub const Buffers = struct { text: []u8, events: []Input.Event, preedit: []u8 = &.{} };

    pub fn init(buf: Buffers) Translator {
        return .{ .text = buf.text, .events = buf.events, .preedit = buf.preedit };
    }

    /// Reads one record.
    pub fn feed(t: *Translator, r: Record) void {
        switch (r) {
            .event => |e| t.event(e),
            .insert => |s| t.commit(s),
            .mark => |k| t.mark(k.text, k.selected),
            .resize => |s| t.resize(s),
            .scale => |s| t.setScale(s),
            // Keys released while another window had the keyboard never send keyUp.
            .resign => {
                t.in.keys = .{};
                t.in.mods = .{};
            },
            .close => t.closed = true,
        }
    }

    /// The content view's size in points, which is the viewport in logical pixels.
    pub fn resize(t: *Translator, size: [2]f64) void {
        t.in.viewport = .{ @floatCast(size[0]), @floatCast(size[1]) };
    }

    /// Physical pixels per logical pixel. Points are logical pixels, so the viewport and the
    /// pointer keep their values: only the drawable's pixels change (device.zig `drawableSize`).
    pub fn setScale(t: *Translator, s: f64) void {
        t.in.scale = @floatCast(@max(s, 0.25));
    }

    /// Reads one NSEvent.
    pub fn event(t: *Translator, e: Event) void {
        t.in.mods = .{
            .shift = e.flags & flag_shift != 0,
            .ctrl = e.flags & flag_control != 0,
            .alt = e.flags & flag_option != 0,
            .cmd = e.flags & flag_command != 0,
        };
        const b = &t.in.buttons;
        switch (e.kind) {
            .left_down, .left_up, .right_down, .right_up, .moved, .left_dragged, .right_dragged, .other_down, .other_up, .other_dragged, .entered => {
                t.in.pointer = .{ @floatCast(e.at[0]), @floatCast(@as(f64, t.in.viewport[1]) - e.at[1]) };
                switch (e.kind) {
                    .left_down, .left_up => b.left = e.kind == .left_down,
                    .right_down, .right_up => b.right = e.kind == .right_down,
                    // buttonNumber 2 is the middle button; the others have no `Buttons` bit.
                    .other_down, .other_up => if (e.code == 2) {
                        b.middle = e.kind == .other_down;
                    },
                    else => {},
                }
            },
            .exited => t.in.pointer = .{ -1, -1 },
            // Positive deltas scroll toward the start (up, left), as `Input.wheel` counts; AppKit
            // has already applied the user's natural-scrolling setting.
            .scroll => {
                const d: [2]f32 = .{ @floatCast(e.delta[0]), @floatCast(e.delta[1]) };
                if (e.precise) {
                    t.in.scroll[0] += d[0];
                    t.in.scroll[1] += d[1];
                } else {
                    t.in.wheel[0] += d[0];
                    t.in.wheel[1] += d[1];
                }
            },
            .key_down => t.key(e.code, if (e.repeat) .repeat else .press),
            .key_up => t.key(e.code, .release),
            // A modifier went down or up: which one is the key code, which way its own bit.
            .flags_changed => {
                const bit = modifierBit(e.code);
                const code = hid[e.code & 0x7f];
                if (bit == 0 or code == 0) return;
                const down = e.flags & bit != 0;
                if (down == t.in.keys.down(code)) return;
                t.key(e.code, if (down) .press else .release);
            },
            _ => {},
        }
    }

    fn key(t: *Translator, vk: u16, kind: Input.Event.Kind) void {
        const code = if (vk < hid.len) hid[vk] else 0;
        if (code == 0) return;
        const k = &t.in.keys.bits[code >> 6];
        const bit = @as(u64, 1) << @as(u6, @truncate(code));
        k.* = if (kind == .release) k.* & ~bit else k.* | bit;
        t.push(.{ .kind = kind, .mods = t.in.mods, .code = code });
    }

    /// The composition (`setMarkedText:...`) as `Events.composition`: UTF-8, with the selected
    /// range (UTF-16 units, as NSRange counts) as a byte range. Empty `text` ends it.
    pub fn mark(t: *Translator, text: []const u8, selected: [2]u32) void {
        var n: u32 = 0;
        var units: u32 = 0;
        var range: [2]u32 = .{ 0, 0 };
        const lo = selected[0];
        const hi = selected[0] +| selected[1];
        var it = (std.unicode.Utf8View.init(text) catch return t.mark("", .{ 0, 0 })).iterator();
        while (it.nextCodepointSlice()) |s| {
            if (units <= lo) range[0] = n;
            if (units <= hi) range[1] = n;
            if (t.preedit.len - n < s.len) break;
            @memcpy(t.preedit[n..][0..s.len], s);
            n += @intCast(s.len);
            units += @as(u32, if (s.len == 4) 2 else 1);
        }
        if (units <= lo) range[0] = n;
        if (units <= hi) range[1] = n;
        t.composition = .{ .len = n, .range = range, .units = units };
    }

    /// The composition is being shown (`hasMarkedText`).
    pub fn marked(t: *const Translator) bool {
        return t.composition.len > 0;
    }

    /// Text an input method committed (`insertText:replacementRange:`), or a key typed: typed,
    /// and any composition ends.
    pub fn commit(t: *Translator, utf8: []const u8) void {
        t.insert(utf8);
        t.composition = .{};
    }

    /// Text typed (`insertText:`) as one `.text` event. Control characters are not text (their
    /// key events carry them); line ends become `\n`, tabs stay. Text that does not fit is
    /// dropped whole.
    pub fn insert(t: *Translator, utf8: []const u8) void {
        const at = t.n_text;
        var it = (std.unicode.Utf8View.init(utf8) catch {
            t.dropped += 1;
            return;
        }).iterator();
        var cr = false;
        while (it.nextCodepointSlice()) |s| {
            const cp = std.unicode.utf8Decode(s) catch unreachable;
            // "\r\n" is one line end.
            const was_cr = cr;
            cr = cp == '\r';
            if (cp == '\n' and was_cr) continue;
            const out: []const u8 = if (cp == '\r') "\n" else s;
            if ((cp < 0x20 and cp != '\n' and cp != '\r' and cp != '\t') or cp == 0x7f) continue;
            // AppKit's function-key characters (NSUpArrowFunctionKey and the rest), from
            // `characters` when no input method is asked for.
            if (cp >= 0xf700 and cp <= 0xf8ff) continue;
            if (t.text.len - t.n_text < out.len) {
                t.n_text = at;
                t.dropped += 1;
                return;
            }
            @memcpy(t.text[t.n_text..][0..out.len], out);
            t.n_text += @intCast(out.len);
        }
        if (t.n_text == at) return;
        if (t.n_events == t.events.len) {
            t.n_text = at;
            t.dropped += 1;
            return;
        }
        t.push(.{ .kind = .text, .mods = t.in.mods, .at = at, .len = t.n_text - at });
    }

    /// The pasteboard's text delivered as typed text, the way `keyboard.Clipboard` asks a host
    /// to answer a paste: as `insert`, one `.text` event with `\n` line ends.
    pub fn paste(t: *Translator, utf8: []const u8) void {
        t.insert(utf8);
    }

    fn push(t: *Translator, e: Input.Event) void {
        if (t.n_events == t.events.len) {
            t.dropped += 1;
            return;
        }
        t.events[t.n_events] = e;
        t.n_events += 1;
    }

    /// This frame's events, in `ev` until the next call; the next frame starts empty. False
    /// once the window was closed.
    pub fn frame(t: *Translator, ev: *Events) bool {
        ev.in = t.in;
        ev.in.text = t.text[0..t.n_text];
        ev.in.events = t.events[0..t.n_events];
        ev.composition = .{ .text = t.preedit[0..t.composition.len], .range = t.composition.range };
        t.in.wheel = .{ 0, 0 };
        t.in.scroll = .{ 0, 0 };
        t.n_text = 0;
        t.n_events = 0;
        return !t.closed;
    }
};

/// Recorded AppKit events, replayed one frame per `next`, so tests drive the translator (and, on
/// macOS, a real window) with what a session produced. UTF-8 text, one record per line:
///
///     # comment              blank lines and comments anywhere
///     frame                  starts a frame; the records below it arrive before its poll
///     resize 800 600         content size in points
///     scale 2                backing scale factor
///     resign                 the window lost the keyboard
///     close                  the close button
///     insert héllo           insertText:, the rest of the line
///     mark 1 0 にほ           setMarkedText: selected location and length, then the text
///     left_down 37 575       an NSEvent, by its `Kind` name. Mouse kinds: x y (window
///                            coordinates, origin bottom left); key_down, key_up, flags_changed:
///                            the virtual key code; scroll: dx dy.
///
/// After an NSEvent's values, optional words: `flags=N` (modifierFlags), `button=N`
/// (buttonNumber), `repeat`, `precise`. Integers are decimal or hex with 0x.
pub const Replay = struct {
    src: []const u8,
    at: usize = 0,
    /// 1-based number of the last line read; on an error, the line at fault.
    line: u32 = 0,

    pub const Error = error{ Syntax, BufferFull };

    /// The records of the next frame, in `buf`, or null after the last frame. Text a record
    /// carries points into `src`.
    pub fn next(r: *Replay, buf: []Record) Error!?[]const Record {
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
            if (n == buf.len) return error.BufferFull;
            buf[n] = try parse(l);
            n += 1;
        }
        return buf[0..n];
    }

    const Words = std.mem.TokenIterator(u8, .scalar);

    fn parse(l: []const u8) Error!Record {
        var it = std.mem.tokenizeScalar(u8, l, ' ');
        const name = it.next().?;
        const rec: Record = if (std.meta.stringToEnum(std.meta.Tag(Record), name)) |tag| switch (tag) {
            .resize => .{ .resize = .{ try num(&it), try num(&it) } },
            .scale => .{ .scale = try num(&it) },
            .resign => .resign,
            .close => .close,
            .insert => return .{ .insert = l[@min(l.len, "insert ".len)..] },
            .mark => {
                const sel: [2]u32 = .{ try int(u32, it.next() orelse return error.Syntax), try int(u32, it.next() orelse return error.Syntax) };
                return .{ .mark = .{ .text = it.rest(), .selected = sel } };
            },
            .event => return error.Syntax,
        } else .{ .event = try event(std.meta.stringToEnum(Kind, name) orelse return error.Syntax, &it) };
        if (it.next() != null) return error.Syntax;
        return rec;
    }

    fn event(kind: Kind, it: *Words) Error!Event {
        var e: Event = .{ .kind = kind };
        switch (kind) {
            .key_down, .key_up, .flags_changed => e.code = try int(u16, it.next() orelse return error.Syntax),
            .scroll => e.delta = .{ try num(it), try num(it) },
            else => e.at = .{ try num(it), try num(it) },
        }
        while (it.next()) |w| {
            if (std.mem.eql(u8, w, "repeat")) {
                e.repeat = true;
            } else if (std.mem.eql(u8, w, "precise")) {
                e.precise = true;
            } else if (std.mem.startsWith(u8, w, "flags=")) {
                e.flags = try int(u64, w["flags=".len..]);
            } else if (std.mem.startsWith(u8, w, "button=")) {
                e.code = try int(u16, w["button=".len..]);
            } else return error.Syntax;
        }
        return e;
    }

    fn num(it: *Words) Error!f64 {
        return std.fmt.parseFloat(f64, it.next() orelse return error.Syntax) catch error.Syntax;
    }

    fn int(comptime T: type, s: []const u8) Error!T {
        return std.fmt.parseInt(T, s, 0) catch error.Syntax;
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

test "translate: size and close from a recording" {
    var r: Replay = .{ .src =
        \\frame
        \\resize 800 600
        \\frame
        \\frame
        \\# A live resize reports every size; the frame shows the last.
        \\resize 900 650.5
        \\resize 1024 768
        \\close
    };
    var buf: [4]Record = undefined;
    var t: Translator = .{};
    var ev: Events = .{};
    const want = [_][2]f32{ .{ 800, 600 }, .{ 800, 600 }, .{ 1024, 768 } };
    for (want, 0..) |vp, i| {
        for ((try r.next(&buf)).?) |rec| t.feed(rec);
        try testing.expectEqual(i < 2, t.frame(&ev));
        try testing.expectEqual(vp, ev.in.viewport);
    }
    try testing.expectEqual(null, try r.next(&buf));
}

test "replay: errors name the line, unknown records are refused" {
    var buf: [1]Record = undefined;
    var r: Replay = .{ .src = "frame\nresize 1\n" };
    try testing.expectError(error.Syntax, r.next(&buf));
    try testing.expectEqual(@as(u32, 2), r.line);
    r = .{ .src = "frame\npaint\n" };
    try testing.expectError(error.Syntax, r.next(&buf));
    r = .{ .src = "frame\nclose now\n" };
    try testing.expectError(error.Syntax, r.next(&buf));
    r = .{ .src = "frame\nkey_down 0 sideways\n" };
    try testing.expectError(error.Syntax, r.next(&buf));
    r = .{ .src = "frame\nevent 0\n" };
    try testing.expectError(error.Syntax, r.next(&buf));
    r = .{ .src = "frame\nclose\nclose\n" };
    try testing.expectError(error.BufferFull, r.next(&buf));
}

const context = @import("../../runtime/context.zig");
const mem = @import("../../core/mem.zig");
const InputReplay = @import("../../core/input.zig").Replay;
const example = @import("../example.zig");

const example_limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
var example_buffer: [context.Context.requiredBytes(example_limits)]u8 align(mem.column_align) = undefined;

test "translate: the example's events give the headless recording's input and run the example" {
    // The same session twice: as AppKit events (testdata/example.events) and as the Input the
    // headless shell replays (src/shell/testdata/example.replay). Frame by frame, the
    // translator must give what the recording holds.
    var rec: Replay = .{ .src = @embedFile("testdata/example.events") };
    var want: InputReplay = .{ .src = @embedFile("../testdata/example.replay") };
    var text: [64]u8 = undefined;
    var events: [16]Input.Event = undefined;
    var want_text: [64]u8 = undefined;
    var want_events: [16]Input.Event = undefined;
    var contacts: [4]Input.Contact = undefined;
    var buf: [16]Record = undefined;
    var t: Translator = .init(.{ .text = &text, .events = &events });
    var ctx = try context.Context.init(&example_buffer, example_limits);
    var app: example.App = .{};
    var ev: Events = .{};
    var frames: u32 = 0;
    // The cursor shown after each poll: the last frame's, as the shell applies it.
    var shown: [15]Cursor = undefined;
    var cursor: Cursor = .arrow;
    while (try rec.next(&buf)) |records| : (frames += 1) {
        defer shown[frames] = cursor;
        for (records) |r| t.feed(r);
        try testing.expect(t.frame(&ev));
        const in = (try want.next(.{ .text = &want_text, .events = &want_events, .contacts = &contacts })).?;
        try testing.expectEqual(in.stamp(), ev.in.stamp());
        try testing.expectEqual(in.pointer, ev.in.pointer);
        try testing.expectEqual(in.buttons, ev.in.buttons);
        if (!ctx.needsFrame(&ev.in)) continue;
        var f = ctx.begin(&ev.in);
        app.build(&f, &ev);
        cursor = f.end(.{}).platform.cursor;
    }
    // Over Reset, Add layer and the slider the hand shows; the headless shell's cursors.
    const a = Cursor.arrow;
    const h = Cursor.pointer;
    try testing.expectEqualSlices(Cursor, &.{ a, a, a, h, h, h, h, h, h, a, a, a, a, a, a }, &shown);
    try testing.expectEqualStrings("pointingHandCursor", cursor_names[@backingInt(h)]);
    try testing.expectEqual(null, try want.next(.{ .text = &want_text, .events = &want_events, .contacts = &contacts }));
    try testing.expectEqual(@as(u32, 15), frames);
    // The headless shell's results (src/shell/headless.zig).
    try testing.expectEqual(@as(u32, 13), app.builds);
    try testing.expectEqual(@as(u32, 1), app.resets);
    try testing.expectEqual(@as(u32, 4), app.layers);
    try testing.expectApproxEqAbs(@as(f32, 3), app.exposure, 0.01);
}

test "translate: keys, modifiers, typed text, wheel and leaving the window" {
    var r: Replay = .{ .src =
        \\frame
        \\resize 800 600
        \\# Left Shift down (device bit 0x2), then A (kVK 0) pressed, held and typed twice.
        \\flags_changed 0x38 flags=0x20002
        \\key_down 0 flags=0x20002
        \\insert A
        \\key_down 0 flags=0x20002 repeat
        \\insert A
        \\insert é😀
        \\scroll 0.5 -2
        \\scroll 0 12 precise
        \\frame
        \\# Shift and A up; right Command (0x36, device bit 0x10) + C: a press with cmd, no text.
        \\key_up 0 flags=0x20002
        \\flags_changed 0x38 flags=0
        \\flags_changed 0x36 flags=0x100010
        \\key_down 8 flags=0x100010
        \\key_down 0x7b flags=0x100010
        \\key_down 0x56 flags=0x100010
        \\moved 10 603 flags=0x100010
        \\frame
        \\other_down 30 500 button=2
        \\insert two\r\nlines\x07
        \\frame
        \\other_up 30 500 button=2
        \\other_down 30 500 button=3
        \\resign
        \\exited 30 500
    };
    var text: [32]u8 = undefined;
    var events: [16]Input.Event = undefined;
    var buf: [16]Record = undefined;
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
        .{ .kind = .text, .at = 2, .len = 6, .mods = shift },
    }, ev.in.events);
    try testing.expect(ev.in.keys.down(0x04) and ev.in.keys.down(0xe1));
    try testing.expectEqual([2]f32{ 0.5, -2 }, ev.in.wheel);
    try testing.expectEqual([2]f32{ 0, 12 }, ev.in.scroll);

    for ((try r.next(&buf)).?) |m| t.feed(m);
    _ = t.frame(&ev);
    const cmd: Input.Mods = .{ .cmd = true };
    try testing.expectEqualStrings("", ev.in.text);
    try testing.expectEqualSlices(Input.Event, &.{
        .{ .kind = .release, .code = 0x04, .mods = shift },
        .{ .kind = .release, .code = 0xe1 },
        .{ .kind = .press, .code = 0xe7, .mods = cmd },
        .{ .kind = .press, .code = 0x06, .mods = cmd },
        .{ .kind = .press, .code = 0x50, .mods = cmd },
        .{ .kind = .press, .code = 0x5c, .mods = cmd },
    }, ev.in.events);
    try testing.expectEqual([2]f32{ 0, 0 }, ev.in.wheel);
    // Above the content's top edge (y 603 of 600): -3, as a captured drag reports it.
    try testing.expectEqual([2]f32{ 10, -3 }, ev.in.pointer);
    try testing.expectEqual(cmd, ev.in.mods);

    // The middle button; pasted-looking text keeps its line end, loses the bell.
    for ((try r.next(&buf)).?) |m| t.feed(m);
    _ = t.frame(&ev);
    try testing.expect(ev.in.buttons.middle);
    try testing.expectEqualStrings("two\\r\\nlines\\x07", ev.in.text);

    // Focus lost: held keys are let go; the pointer left. Button 3 has no bit.
    for ((try r.next(&buf)).?) |m| t.feed(m);
    _ = t.frame(&ev);
    try testing.expectEqual(Input.Keys{}, ev.in.keys);
    try testing.expectEqual(Input.Mods{}, ev.in.mods);
    try testing.expectEqual([2]f32{ -1, -1 }, ev.in.pointer);
    try testing.expectEqual(Input.Buttons{}, ev.in.buttons);

    // Real line ends and control characters, as `insertText:` can deliver them.
    t.insert("two\r\nlines\x07\rend\t");
    _ = t.frame(&ev);
    try testing.expectEqualStrings("two\nlines\nend\t", ev.in.text);
}

test "translate: a full frame drops what does not fit and counts it" {
    var text: [4]u8 = undefined;
    var events: [2]Input.Event = undefined;
    var t: Translator = .init(.{ .text = &text, .events = &events });
    var ev: Events = .{};
    t.insert("ab");
    t.insert("cde"); // too long for what is left: none of it
    t.insert("c");
    t.insert("d"); // no event left
    _ = t.frame(&ev);
    try testing.expectEqualStrings("abc", ev.in.text);
    try testing.expectEqual(@as(u32, 2), t.dropped);
    t.insert("\xff");
    try testing.expectEqual(@as(u32, 3), t.dropped);
}

test "keys: every virtual key code names a distinct key" {
    var seen: [256]bool = @splat(false);
    for (hid) |u| {
        if (u == 0) continue;
        try testing.expect(!seen[u]);
        seen[u] = true;
    }
    // Spot checks against the HID tables: A, Return, Escape, left Command, Up.
    try testing.expectEqual(@as(u8, 0x04), hid[0x00]);
    try testing.expectEqual(@as(u8, 0x28), hid[0x24]);
    try testing.expectEqual(@as(u8, 0x29), hid[0x35]);
    try testing.expectEqual(@as(u8, 0xe3), hid[0x37]);
    try testing.expectEqual(@as(u8, 0x52), hid[0x7e]);
}

test "scale: a move to a Retina display changes the scale, not the viewport or the pointer" {
    var r: Replay = .{ .src =
        \\frame
        \\resize 800 600
        \\scale 2
        \\moved 100 550
        \\frame
        \\# Dragged to a 1x display: same points, half the pixels.
        \\scale 1
        \\frame
        \\# A scaled display mode of 1.5 and a resize there.
        \\scale 1.5
        \\resize 640 480
        \\moved 100 430
    };
    var buf: [4]Record = undefined;
    var t: Translator = .{};
    var ev: Events = .{};
    const want = [_]struct { scale: f32, viewport: [2]f32 }{
        .{ .scale = 2, .viewport = .{ 800, 600 } },
        .{ .scale = 1, .viewport = .{ 800, 600 } },
        .{ .scale = 1.5, .viewport = .{ 640, 480 } },
    };
    for (want) |w| {
        for ((try r.next(&buf)).?) |m| t.feed(m);
        _ = t.frame(&ev);
        try testing.expectEqual(w.scale, ev.in.scale);
        try testing.expectEqual(w.viewport, ev.in.viewport);
        try testing.expectEqual([2]f32{ 100, 50 }, ev.in.pointer);
    }
    // A stamp sees the change, so the frame is rebuilt at the new scale.
    var a: Translator = .{};
    var b: Translator = .{};
    b.setScale(2);
    try testing.expect(a.in.stamp() != b.in.stamp());
}

test "cursors: every Platform cursor has its own system cursor" {
    for (cursor_names, 0..) |a, i| for (cursor_names[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expectEqualStrings("IBeamCursor", cursor_names[@backingInt(Cursor.text)]);
}

test "clipboard: pasted text is typed in one event, with its line ends" {
    var text: [32]u8 = undefined;
    var events: [4]Input.Event = undefined;
    var t: Translator = .init(.{ .text = &text, .events = &events });
    var ev: Events = .{};
    t.insert("x");
    t.paste("one\r\ntwo\t\u{1f600}\x07");
    _ = t.frame(&ev);
    try testing.expectEqualStrings("xone\ntwo\t\u{1f600}", ev.in.text);
    try testing.expectEqual(@as(usize, 2), ev.in.events.len);
    try testing.expectEqualStrings("one\ntwo\t\u{1f600}", ev.in.typed(ev.in.events[1]));
    // Too long for what is left: nothing of it is typed.
    t.paste("0123456789012345678901234567890123456789");
    _ = t.frame(&ev);
    try testing.expectEqualStrings("", ev.in.text);
    try testing.expectEqual(@as(u32, 1), t.dropped);
}

/// `r` (logical pixels, origin top left) as an NSRect in window coordinates (origin bottom
/// left) of content `height` points tall: x, y, width, height. The input method puts its
/// candidate window below it (`firstRectForCharacterRange:actualRange:`).
pub fn windowRect(r: Rect, height: f32) [4]f64 {
    return .{ r.x0, height - r.y1, r.x1 - r.x0, r.y1 - r.y0 };
}

test "ime: a composition is shown, converted, then committed as typed text" {
    var text: [32]u8 = undefined;
    var events: [4]Input.Event = undefined;
    var preedit: [32]u8 = undefined;
    var t: Translator = .init(.{ .text = &text, .events = &events, .preedit = &preedit });
    var ev: Events = .{};
    // Typing "nihon": the reading so far, caret at its end (3 units), nothing selected.
    t.mark("\u{306b}\u{307b}\u{3093}", .{ 3, 0 });
    _ = t.frame(&ev);
    try testing.expect(t.marked());
    try testing.expectEqualStrings("\u{306b}\u{307b}\u{3093}", ev.composition.text);
    try testing.expectEqual([2]u32{ 9, 9 }, ev.composition.range);
    try testing.expectEqualStrings("", ev.in.text);

    // Space converts: two clauses, the first (U+65E5) selected.
    t.mark("\u{65e5}\u{672c}", .{ 0, 1 });
    _ = t.frame(&ev);
    try testing.expectEqual([2]u32{ 0, 3 }, ev.composition.range);
    // Held: the next frame shows it again.
    _ = t.frame(&ev);
    try testing.expectEqualStrings("\u{65e5}\u{672c}", ev.composition.text);

    // A surrogate pair counts two UTF-16 units: the caret after it is at unit 3, byte 5.
    t.mark("a\u{20bb7}b", .{ 3, 0 });
    _ = t.frame(&ev);
    try testing.expectEqual([2]u32{ 5, 5 }, ev.composition.range);
    try testing.expectEqual(@as(u32, 4), t.composition.units);

    // Return commits: the result is typed, the composition ends.
    t.commit("\u{65e5}\u{672c}");
    _ = t.frame(&ev);
    try testing.expectEqualStrings("\u{65e5}\u{672c}", ev.in.text);
    try testing.expectEqualStrings("", ev.composition.text);
    try testing.expect(!t.marked());

    // A range past the end is clamped to it; a composition longer than the buffer is cut at a
    // character.
    var small: [4]u8 = undefined;
    t = .init(.{ .text = &text, .events = &events, .preedit = &small });
    t.mark("\u{65e5}\u{672c}", .{ 1, 9 });
    _ = t.frame(&ev);
    try testing.expectEqualStrings("\u{65e5}", ev.composition.text);
    try testing.expectEqual([2]u32{ 3, 3 }, ev.composition.range);

    // Function-key characters are not text.
    t.insert("\u{f700}x");
    _ = t.frame(&ev);
    try testing.expectEqualStrings("x", ev.in.text);

    try testing.expectEqual([4]f64{ 10, 540, 30, 40 }, windowRect(.{ .x0 = 10, .y0 = 20, .x1 = 40, .y1 = 60 }, 600));
}

test "ime: compositions replay from a recording" {
    var preedit: [32]u8 = undefined;
    var text: [32]u8 = undefined;
    var events: [4]Input.Event = undefined;
    var t: Translator = .init(.{ .text = &text, .events = &events, .preedit = &preedit });
    var ev: Events = .{};
    var buf: [4]Record = undefined;
    var r: Replay = .{ .src = "frame\nmark 0 1 \u{65e5}\u{672c}\nframe\nmark 0 0\ninsert \u{65e5}\u{672c}\n" };
    for ((try r.next(&buf)).?) |m| t.feed(m);
    _ = t.frame(&ev);
    try testing.expectEqualStrings("\u{65e5}\u{672c}", ev.composition.text);
    try testing.expectEqual([2]u32{ 0, 3 }, ev.composition.range);
    for ((try r.next(&buf)).?) |m| t.feed(m);
    _ = t.frame(&ev);
    try testing.expectEqualStrings("", ev.composition.text);
    try testing.expectEqualStrings("\u{65e5}\u{672c}", ev.in.text);
}
