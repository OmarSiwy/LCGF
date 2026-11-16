//! NativeActivity events as `Events`: the part of the Android shell (android.zig) that touches
//! no OS, so it builds and is tested on any host. The shell's activity callbacks and input queue
//! hand what Android reports (the window's size, motion and key events, typed text) to a
//! `Translator`; `poll` calls `frame`. It allocates nothing.
//!
//! The mobile event model (the first finger drives the pointer, typed text, the IME's
//! composition, the app's foreground state) is the iOS shell's translator, which this one
//! wraps: Android's events are converted to it, in Android's units (physical pixels) turned
//! into logical ones.

const std = @import("std");
const Input = @import("../../core/input.zig").Input;
const Events = @import("../iface.zig").Events;
const mobile = @import("../ios/translate.zig");

/// `AMOTION_EVENT_ACTION_*`, the low byte of `AMotionEvent_getAction`; the next byte is the
/// index of the pointer a `pointer_down` or `pointer_up` is about.
pub const Action = enum(u8) {
    down = 0,
    up = 1,
    move = 2,
    cancel = 3,
    outside = 4,
    pointer_down = 5,
    pointer_up = 6,
    hover_move = 7,
    scroll = 8,
    hover_enter = 9,
    hover_exit = 10,
    button_press = 11,
    button_release = 12,
    _,
};

/// `AMOTION_EVENT_TOOL_TYPE_*`.
pub const Tool = enum(u8) { unknown = 0, finger = 1, stylus = 2, mouse = 3, eraser = 4, _ };

/// One pointer of a motion event, as `AMotionEvent_getPointerId`, `_getToolType`, `_getX`,
/// `_getY`, `_getPressure` and the tilt and orientation axes give it. Positions in physical
/// pixels of the window.
pub const Pointer = struct {
    id: u32,
    tool: Tool = .finger,
    pos: [2]f32,
    pressure: f32 = 1,
    /// AXIS_TILT (radians from the screen's normal) and AXIS_ORIENTATION (radians clockwise
    /// from up), for a stylus.
    tilt: f32 = 0,
    orientation: f32 = 0,
};

/// One motion event: its action word, its pointers, the mouse buttons held
/// (`AMotionEvent_getButtonState`) and, for `scroll`, AXIS_HSCROLL and AXIS_VSCROLL.
pub const Motion = struct {
    action: u32,
    pointers: []const Pointer,
    buttons: u32 = 0,
    scroll: [2]f32 = .{ 0, 0 },
};

/// `AKEY_EVENT_ACTION_*`.
pub const KeyAction = enum(u8) { down = 0, up = 1, multiple = 2, _ };

/// `AMETA_*` bits of a key event's meta state.
const meta_shift = 0x1;
const meta_alt = 0x2;
const meta_ctrl = 0x1000;
const meta_meta = 0x10000;
/// `AMOTION_EVENT_BUTTON_*`.
const button_primary = 1;
const button_secondary = 2;
const button_tertiary = 4;

/// USB HID usage (the scancodes of `Input.Keys`) of each Android keycode
/// (`AKEYCODE_*`, android/keycodes.h), 0 for keys with none.
pub const hid: [256]u8 = table: {
    var t: [256]u8 = @splat(0);
    for (0..26) |i| t[29 + i] = 0x04 + i; // A..Z
    t[7] = 0x27; // 0
    for (1..10) |i| t[7 + i] = 0x1e + i - 1; // 1..9
    for (0..12) |i| t[131 + i] = 0x3a + i; // F1..F12
    const pairs = [_][2]u8{
        .{ 19, 0x52 }, .{ 20, 0x51 }, .{ 21, 0x50 }, .{ 22, 0x4f }, // DPAD up, down, left, right
        .{ 55, 0x36 }, .{ 56, 0x37 }, .{ 57, 0xe2 }, .{ 58, 0xe6 }, // , . left Alt, right Alt
        .{ 59, 0xe1 }, .{ 60, 0xe5 }, .{ 61, 0x2b }, .{ 62, 0x2c }, // left Shift, right Shift, Tab, Space
        .{ 66, 0x28 }, .{ 67, 0x2a }, .{ 68, 0x35 }, .{ 69, 0x2d }, // Enter, Del (Backspace), ` -
        .{ 70, 0x2e }, .{ 71, 0x2f }, .{ 72, 0x30 }, .{ 73, 0x31 }, // = [ ] \
        .{ 74, 0x33 }, .{ 75, 0x34 }, .{ 76, 0x38 }, .{ 92, 0x4b }, // ; ' / PageUp
        .{ 93, 0x4e }, .{ 111, 0x29 }, .{ 112, 0x4c }, .{ 113, 0xe0 }, // PageDown, Escape, ForwardDel, left Ctrl
        .{ 114, 0xe4 }, .{ 115, 0x39 }, .{ 117, 0xe3 }, .{ 118, 0xe7 }, // right Ctrl, CapsLock, left Meta, right Meta
        .{ 122, 0x4a }, .{ 123, 0x4d }, .{ 124, 0x49 }, // Home, End, Insert
    };
    for (pairs) |p| t[p[0]] = p[1];
    break :table t;
};

pub const Translator = struct {
    /// The event model and its held state; `m.in` is the next frame's Input.
    m: mobile.Translator = .{},
    /// The window's size in physical pixels (`ANativeWindow_getWidth` / `_getHeight`).
    window: [2]f32 = .{ 800, 600 },

    pub const Buffers = mobile.Translator.Buffers;

    pub fn init(buf: Buffers) Translator {
        return .{ .m = .init(buf) };
    }

    /// The native window was created or resized (`onNativeWindowCreated`,
    /// `onNativeWindowResized`): `w` x `h` physical pixels.
    pub fn resize(t: *Translator, w: f32, h: f32) void {
        t.window = .{ w, h };
        t.m.resize(w / t.m.in.scale, h / t.m.in.scale);
    }

    /// A motion event. Fingers, styluses and erasers are touches in the mobile model (the
    /// first finger also drives the pointer); a mouse is the pointer, its buttons and wheel.
    pub fn motion(t: *Translator, m: Motion) void {
        const action: Action = @fromBackingInt(@intCast(@as(u8, @truncate(m.action))));
        const index: usize = (m.action >> 8) & 0xff;
        const scale = t.m.in.scale;
        for (m.pointers, 0..) |p, i| {
            const pos: [2]f32 = .{ p.pos[0] / scale, p.pos[1] / scale };
            if (p.tool == .mouse) {
                t.mouse(action, pos, m);
                continue;
            }
            const phase: mobile.Phase = switch (action) {
                .down => .began,
                .pointer_down => if (i == index) .began else .moved,
                .up => .ended,
                .pointer_up => if (i == index) .ended else .moved,
                .move => .moved,
                .cancel => .cancelled,
                // ponytail: a stylus hovering is not a contact yet (Contact.down = false needs
                // the mobile model to list hovering pens); widgets see it only once it touches.
                else => continue,
            };
            const kind: mobile.Kind = switch (p.tool) {
                .stylus => .pencil,
                .eraser => .eraser,
                else => .direct,
            };
            const lean: [2]f32 = .{ p.tilt * @sin(p.orientation), -p.tilt * @cos(p.orientation) };
            t.m.touch(.{ .id = p.id, .phase = phase, .pos = pos, .kind = kind, .pressure = p.pressure, .tilt = if (kind == .direct) .{ 0, 0 } else lean });
        }
    }

    fn mouse(t: *Translator, action: Action, pos: [2]f32, m: Motion) void {
        const in = &t.m.in;
        switch (action) {
            .hover_exit => in.pointer = .{ -1, -1 },
            // AXIS_VSCROLL is positive away from the user, as `Input.wheel`; AXIS_HSCROLL is
            // positive to the right, which scrolls toward the end, so it is negated.
            .scroll => {
                in.pointer = pos;
                in.wheel = .{ in.wheel[0] - m.scroll[0], in.wheel[1] + m.scroll[1] };
            },
            else => {
                in.pointer = pos;
                // Some mice report a primary press without a button state.
                const held = if (action == .down and m.buttons == 0) button_primary else m.buttons;
                in.buttons = .{
                    .left = held & button_primary != 0 and action != .up,
                    .right = held & button_secondary != 0,
                    .middle = held & button_tertiary != 0,
                };
            },
        }
    }

    /// A key event: Android keycode `code`, `AKeyEvent_getMetaState`'s `meta`, and the repeat
    /// count. True when the key is one the UI reads; the shell hands the others (Back, volume)
    /// back to the system.
    pub fn key(t: *Translator, action: KeyAction, code: u32, meta: u32, repeat: u32) bool {
        const usage = if (code < hid.len) hid[code] else 0;
        if (usage == 0) return false;
        const mods: Input.Mods = .{
            .shift = meta & meta_shift != 0,
            .alt = meta & meta_alt != 0,
            .ctrl = meta & meta_ctrl != 0,
            .cmd = meta & meta_meta != 0,
        };
        switch (action) {
            .down => t.m.keyEvent(usage, if (repeat > 0) .repeat else .press, mods),
            .up => t.m.keyEvent(usage, .release, mods),
            else => return false,
        }
        return true;
    }

    /// The activity is being destroyed for good (`onDestroy`): no more frames.
    pub fn destroy(t: *Translator) void {
        t.m.terminate();
    }

    /// This frame's events, in `ev` until the next call. False once the activity is destroyed.
    pub fn frame(t: *Translator, ev: *Events) bool {
        return t.m.frame(ev);
    }
};

/// Recorded NativeActivity events, replayed one frame per `next` into a translator, so tests
/// drive it with what a session produced. UTF-8 text, one line each:
///
///     # comment              blank lines and comments anywhere
///     frame                  starts a frame; the events below it arrive before its poll
///     window 1080 2400       the native window's size, physical pixels
///     motion down 0 1,finger,37,25
///                            a motion event: its action (`pointer_down/1`: about pointer 1),
///                            the button state, then each pointer as id,tool,x,y[,pressure]
///     wheel 0 -1             a mouse wheel: AXIS_HSCROLL, AXIS_VSCROLL
///     key down 29 0 0        a key event: action, keycode, meta state, repeat count
///     destroy                onDestroy
pub const Replay = struct {
    src: []const u8,
    at: usize = 0,
    /// 1-based number of the last line read; on an error, the line at fault.
    line: u32 = 0,

    pub const Error = error{Syntax};
    const Words = std.mem.TokenIterator(u8, .scalar);
    const Line = enum { window, motion, wheel, key, destroy };

    /// Feeds the next frame's events to `t`. False after the last frame.
    pub fn next(r: *Replay, t: *Translator) Error!bool {
        while (true) {
            const l = r.take() orelse return false;
            if (blank(l)) continue;
            if (!std.mem.eql(u8, l, "frame")) return error.Syntax;
            break;
        }
        while (r.peek()) |l| {
            if (std.mem.eql(u8, l, "frame")) break;
            _ = r.take();
            if (blank(l)) continue;
            var w = std.mem.tokenizeScalar(u8, l, ' ');
            switch (std.meta.stringToEnum(Line, w.next().?) orelse return error.Syntax) {
                .window => t.resize(try num(&w), try num(&w)),
                .destroy => t.destroy(),
                .motion => {
                    var a = std.mem.splitScalar(u8, w.next() orelse return error.Syntax, '/');
                    const action = std.meta.stringToEnum(Action, a.first()) orelse return error.Syntax;
                    const index = if (a.next()) |i| try int(i) else 0;
                    const buttons = try int(w.next() orelse return error.Syntax);
                    var ptrs: [16]Pointer = undefined;
                    var n: usize = 0;
                    while (w.next()) |p| : (n += 1) {
                        if (n == ptrs.len) return error.Syntax;
                        var f = std.mem.splitScalar(u8, p, ',');
                        ptrs[n] = .{ .id = try int(f.first()), .pos = undefined };
                        ptrs[n].tool = std.meta.stringToEnum(Tool, f.next() orelse return error.Syntax) orelse return error.Syntax;
                        ptrs[n].pos = .{ try float(f.next()), try float(f.next()) };
                        if (f.next()) |pr| ptrs[n].pressure = try float(pr);
                    }
                    t.motion(.{ .action = @backingInt(action) | (index << 8), .pointers = ptrs[0..n], .buttons = buttons });
                },
                .wheel => {
                    const at: Pointer = .{ .id = 0, .tool = .mouse, .pos = .{ t.m.in.pointer[0] * t.m.in.scale, t.m.in.pointer[1] * t.m.in.scale } };
                    t.motion(.{ .action = @backingInt(Action.scroll), .pointers = &.{at}, .scroll = .{ try num(&w), try num(&w) } });
                },
                .key => {
                    const action = std.meta.stringToEnum(KeyAction, w.next() orelse return error.Syntax) orelse return error.Syntax;
                    _ = t.key(action, try int(w.next() orelse return error.Syntax), try int(w.next() orelse return error.Syntax), try int(w.next() orelse return error.Syntax));
                },
            }
            if (w.next() != null) return error.Syntax;
        }
        return true;
    }

    fn int(s: []const u8) Error!u32 {
        return std.fmt.parseInt(u32, s, 0) catch error.Syntax;
    }

    fn float(s: ?[]const u8) Error!f32 {
        return std.fmt.parseFloat(f32, s orelse return error.Syntax) catch error.Syntax;
    }

    fn num(w: *Words) Error!f32 {
        return std.fmt.parseFloat(f32, w.next() orelse return error.Syntax) catch error.Syntax;
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
const context = @import("../../runtime/context.zig");
const mem = @import("../../core/mem.zig");
const types = @import("../../core/types.zig");
const example = @import("../example.zig");

const example_limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
var example_buffer: [context.Context.requiredBytes(example_limits)]u8 align(mem.column_align) = undefined;

test "replay: errors name the line, unknown events are refused" {
    var t: Translator = .{};
    var r: Replay = .{ .src = "frame\nwindow 1080\n" };
    try testing.expectError(error.Syntax, r.next(&t));
    try testing.expectEqual(@as(u32, 2), r.line);
    r = .{ .src = "frame\nvibrate\n" };
    try testing.expectError(error.Syntax, r.next(&t));
    r = .{ .src = "window 1 2\n" };
    try testing.expectError(error.Syntax, r.next(&t));
}

test "translate: the window's size lays out the example, and destruction ends it" {
    // A phone's window in portrait, then rotated, then the activity is finished.
    var r: Replay = .{ .src =
        \\frame
        \\window 1080 2400
        \\frame
        \\frame
        \\window 2400 1080
        \\frame
        \\destroy
    };
    var t: Translator = .{};
    var ctx = try context.Context.init(&example_buffer, example_limits);
    var app: example.App = .{};
    var ev: Events = .{};
    const sizes = [_][2]f32{ .{ 1080, 2400 }, .{ 1080, 2400 }, .{ 2400, 1080 } };
    for (sizes) |vp| {
        try testing.expect(try r.next(&t));
        try testing.expect(t.frame(&ev));
        try testing.expectEqual(vp, ev.in.viewport);
        if (!ctx.needsFrame(&ev.in)) continue;
        var f = ctx.begin(&ev.in);
        app.build(&f, &ev);
        const out = f.end(.{});
        try testing.expect(out.status.ok());
        try testing.expectEqual(types.Rect{ .x0 = 160, .y0 = 50, .x1 = vp[0], .y1 = vp[1] }, out.tree.rect(out.tree.find(example.id_viewport)));
    }
    try testing.expect(try r.next(&t));
    try testing.expect(!t.frame(&ev));
    try testing.expect(!try r.next(&t));
    try testing.expectEqual(@as(u32, 3), app.builds);
}

const InputReplay = @import("../../core/input.zig").Replay;

test "translate: the example's motion events give the recorded input and run the example" {
    // The iOS shell's session (src/shell/ios/testdata/example.uikit) as Android reports it
    // (testdata/example.events): motion events with all their pointers. Frame by frame it must
    // give the iOS shell's Input but for the cancel, which on Android takes the whole gesture
    // (testdata/example.replay), and the same results.
    var r: Replay = .{ .src = @embedFile("testdata/example.events") };
    var want: InputReplay = .{ .src = @embedFile("testdata/example.replay") };
    var want_text: [16]u8 = undefined;
    var want_events: [16]Input.Event = undefined;
    var want_contacts: [mobile.max_contacts]Input.Contact = undefined;
    const buf: InputReplay.Buffers = .{ .text = &want_text, .events = &want_events, .contacts = &want_contacts };
    var t: Translator = .{};
    var ctx = try context.Context.init(&example_buffer, example_limits);
    var app: example.App = .{};
    var ev: Events = .{};
    var frames: u32 = 0;
    while (try r.next(&t)) : (frames += 1) {
        try testing.expect(t.frame(&ev));
        const in = (try want.next(buf)) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(in.pointer, ev.in.pointer);
        try testing.expectEqual(in.buttons, ev.in.buttons);
        try testing.expectEqualSlices(Input.Contact, in.contacts, ev.in.contacts);
        try testing.expectEqual(in.stamp(), ev.in.stamp());
        if (!ctx.needsFrame(&ev.in)) continue;
        var f = ctx.begin(&ev.in);
        app.build(&f, &ev);
        _ = f.end(.{});
    }
    try testing.expectEqual(null, try want.next(buf));
    try testing.expectEqual(@as(u32, 14), frames);
    try testing.expectEqual(@as(u32, 1), app.resets);
    try testing.expectEqual(@as(u32, 4), app.layers);
    try testing.expectApproxEqAbs(@as(f32, 3), app.exposure, 0.01);
}

test "translate: keys, a mouse with its wheel, a stylus and its eraser" {
    var r: Replay = .{ .src =
        \\frame
        \\# Shift down, A pressed then repeated (keycodes 59 and 29); Back is the system's.
        \\key down 59 1 0
        \\key down 29 1 0
        \\key down 29 1 1
        \\key down 4 0 0
        \\frame
        \\key up 29 1 0
        \\key up 59 0 0
        \\# A mouse: moved, right button, wheel one notch away and one to the right.
        \\motion hover_move 0 0,mouse,100,50
        \\motion down 2 0,mouse,100,50
        \\wheel 1 1
        \\frame
        \\motion up 0 0,mouse,100,50
        \\motion hover_exit 0 0,mouse,100,50
        \\# A stylus at half pressure, its eraser end elsewhere.
        \\motion down 0 3,stylus,10,10,0.5
        \\motion pointer_down/1 0 3,stylus,10,10,0.5 4,eraser,20,20
    };
    var text: [16]u8 = undefined;
    var events: [16]Input.Event = undefined;
    var t: Translator = .init(.{ .text = &text, .events = &events });
    var ev: Events = .{};
    try testing.expect(try r.next(&t));
    _ = t.frame(&ev);
    const shift: Input.Mods = .{ .shift = true };
    try testing.expectEqualSlices(Input.Event, &.{
        .{ .kind = .press, .code = 0xe1, .mods = shift },
        .{ .kind = .press, .code = 0x04, .mods = shift },
        .{ .kind = .repeat, .code = 0x04, .mods = shift },
    }, ev.in.events);
    try testing.expect(ev.in.keys.down(0x04) and ev.in.keys.down(0xe1));
    try testing.expect(!t.key(.down, 4, 0, 0));

    try testing.expect(try r.next(&t));
    _ = t.frame(&ev);
    try testing.expectEqual(Input.Keys{}, ev.in.keys);
    try testing.expectEqual([2]f32{ 100, 50 }, ev.in.pointer);
    try testing.expectEqual(Input.Buttons{ .right = true }, ev.in.buttons);
    try testing.expectEqual([2]f32{ -1, 1 }, ev.in.wheel);
    try testing.expectEqual(@as(usize, 0), ev.in.contacts.len);

    try testing.expect(try r.next(&t));
    _ = t.frame(&ev);
    try testing.expectEqual([2]f32{ 0, 0 }, ev.in.wheel);
    try testing.expectEqual(Input.Contact{ .id = 3, .kind = .pen, .pos = .{ 10, 10 }, .pressure = 0.5 }, ev.in.contacts[0]);
    try testing.expectEqual(Input.Contact.Kind.eraser, ev.in.contacts[1].kind);
    // The stylus is the first contact down, so it drives the pointer; the mouse left.
    try testing.expectEqual([2]f32{ 10, 10 }, ev.in.pointer);
    try testing.expect(ev.in.buttons.left);
}
