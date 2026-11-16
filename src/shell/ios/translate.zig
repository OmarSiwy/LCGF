//! UIKit events as `Events`: the part of the iOS shell (ios.zig) that touches no OS, so it
//! builds and is tested on any host. The shell's view and application delegate hand what UIKit
//! tells them (the view's bounds, touches, typed text) to a `Translator`; `poll` calls `frame`.
//! Everything the translator keeps is its own or carved from the caller's buffers; it
//! allocates nothing.
//!
//! Units are UIKit's: positions and sizes in points, which are the core's logical pixels.

const std = @import("std");
const Input = @import("../../core/input.zig").Input;
const Events = @import("../iface.zig").Events;
const none = @import("../../core/types.zig").none;

/// `UITouchPhase`, by value.
pub const Phase = enum(u8) { began, moved, stationary, ended, cancelled };
/// `UITouchType`, by value: a finger on the screen, a finger on a remote surface, an Apple
/// Pencil, and a trackpad or mouse click on iPad.
pub const Kind = enum(u8) { direct, indirect, pencil, pointer };

/// One UITouch as `touchesBegan:withEvent:` and the others report it.
pub const Touch = struct {
    /// Stable from began to ended (the shell numbers the UITouch objects).
    id: u32,
    phase: Phase,
    /// `locationInView:`, points.
    pos: [2]f32,
    kind: Kind = .direct,
    /// `force / maximumPossibleForce`; 1 where the screen has no force sensing.
    pressure: f32 = 1,
    /// Pencil tilt from the screen's normal along x and y, radians (`altitudeAngle`,
    /// `azimuthAngleInView:`); 0 for fingers.
    tilt: [2]f32 = .{ 0, 0 },
};

/// `UIKeyModifierFlags` bits.
const mod_shift = 1 << 17;
const mod_control = 1 << 18;
const mod_alternate = 1 << 19;
const mod_command = 1 << 20;
/// HID usages of the keys the soft keyboard has besides text.
const key_return = 0x28;
const key_backspace = 0x2a;

/// Most fingers and pencils followed at once; iOS reports at most 10 fingers on a screen.
pub const max_contacts = 16;

pub const Translator = struct {
    /// Held state, kept from event to event: viewport, scale, pointer, buttons, keys, mods.
    in: Input = .{},
    /// The application is terminating (`applicationWillTerminate:`): no more frames.
    closed: bool = false,
    /// The view's safe area as padding, logical pixels, in `Style.pad`'s order (left, top,
    /// right, bottom): what the notch, the Dynamic Island, the home indicator and the status
    /// bar cover. The host pads its root node with it (example.zig) so nothing lands under them;
    /// a full-bleed background still fills the whole viewport.
    safe: [4]f32 = .{ 0, 0, 0, 0 },
    /// Fingers and pencils on the screen, in the order they touched down. `fresh`: touched
    /// down since the last frame, so not reported yet; `lift`: ended, removed once reported.
    rows: [max_contacts]Input.Contact = undefined,
    fresh: [max_contacts]bool = @splat(false),
    lift: [max_contacts]bool = @splat(false),
    n_rows: u32 = 0,
    /// The frame's copy of `rows`, which `ev.in.contacts` points into until the next `frame`.
    out_rows: [max_contacts]Input.Contact = undefined,
    /// The touch that drives `pointer` and the left button, so widgets made for the mouse
    /// work under a finger: the first to touch down while none does. `none` when none does.
    primary: u32 = none,
    primary_mouse: bool = false,
    /// The primary touch began since the last frame (its press is not reported yet).
    primary_fresh: bool = false,
    /// It ended within the frame it began: release the button after this frame.
    release_next: bool = false,
    /// It ended: the pointer leaves after this frame, as a finger lifted from glass hovers
    /// nothing. A trackpad's pointer stays.
    leave_next: bool = false,
    /// Touches beyond `max_contacts`, and text that did not fit the buffers, since `init`.
    dropped: u32 = 0,
    /// Caller-owned storage for the typed text and text events arriving (`frame` copies them
    /// to `out`, which `ev` points into until the next `frame`).
    text: []u8 = &.{},
    events: []Input.Event = &.{},
    n_text: u32 = 0,
    n_events: u32 = 0,
    out: Buffers = .{ .text = &.{}, .events = &.{} },
    /// The IME's marked text (UTF-8) and the byte range it selects in it, held until it
    /// changes or ends, and the frame's copy of it.
    preedit: [max_preedit]u8 = undefined,
    composition: struct { len: u32 = 0, range: [2]u32 = .{ 0, 0 } } = .{},
    out_preedit: [max_preedit]u8 = undefined,

    /// Longest marked text shown; a longer one is cut at a character.
    pub const max_preedit = 256;

    /// Each buffer is split in two halves: what arrives, and the frame handed out.
    pub const Buffers = struct { text: []u8, events: []Input.Event };

    pub fn init(buf: Buffers) Translator {
        const t = buf.text.len / 2;
        const e = buf.events.len / 2;
        return .{
            .text = buf.text[0..t],
            .events = buf.events[0..e],
            .out = .{ .text = buf.text[t..][0..t], .events = buf.events[e..][0..e] },
        };
    }

    /// The view's bounds changed (`layoutSubviews`): `w` x `h` points.
    pub fn resize(t: *Translator, w: f32, h: f32) void {
        t.in.viewport = .{ w, h };
    }

    /// Physical pixels per point: the view's `contentScaleFactor`, which the shell sets to the
    /// screen's `nativeScale` (2 or 3 on iPhones; 2.608 on a display-zoomed Plus or Max).
    /// Points stay points: the viewport and every position are unchanged.
    pub fn setScale(t: *Translator, scale: f32) void {
        t.in.scale = if (scale > 0) scale else 1;
    }

    /// The view's `safeAreaInsets` (top, left, bottom, right in points, UIEdgeInsets' order).
    pub fn setInsets(t: *Translator, top: f32, left: f32, bottom: f32, right: f32) void {
        t.safe = .{ left, top, right, bottom };
    }

    pub fn terminate(t: *Translator) void {
        t.closed = true;
    }

    /// A touch began, moved, ended or was cancelled. Fingers and pencils are `Input.contacts`;
    /// the primary one also moves the pointer and holds the left button. A press and a release
    /// in one frame are reported in two, so a quick tap still clicks. A cancelled touch (the
    /// system took it for a gesture) is moved off the view before it lifts, so it clicks nothing.
    pub fn touch(t: *Translator, c: Touch) void {
        if (c.kind != .pointer) t.contact(c);
        if (c.phase == .began and t.primary == none) {
            t.primary = c.id;
            t.primary_mouse = c.kind == .pointer;
            t.primary_fresh = true;
            t.leave_next = false;
            t.in.buttons.left = true;
        }
        if (c.id != t.primary) return;
        switch (c.phase) {
            .began, .moved, .stationary => t.in.pointer = c.pos,
            .ended => {
                t.in.pointer = c.pos;
                if (t.primary_fresh) {
                    t.release_next = true;
                } else {
                    t.in.buttons.left = false;
                    t.leave_next = !t.primary_mouse;
                    t.primary = none;
                }
            },
            .cancelled => {
                t.in.pointer = .{ -1, -1 };
                t.in.buttons.left = false;
                t.primary = none;
                t.release_next = false;
            },
        }
    }

    fn contact(t: *Translator, c: Touch) void {
        const at = t.find(c.id);
        if (at == none) {
            if (c.phase != .began) return;
            if (t.n_rows == max_contacts) {
                t.dropped += 1;
                return;
            }
            t.fresh[t.n_rows] = true;
            t.lift[t.n_rows] = false;
            t.n_rows += 1;
        }
        const row = if (at == none) t.n_rows - 1 else at;
        const kind: Input.Contact.Kind = if (c.kind == .pencil) .pen else .touch;
        t.rows[row] = .{ .id = c.id, .kind = kind, .pos = c.pos, .pressure = c.pressure, .tilt = c.tilt };
        switch (c.phase) {
            .began, .moved, .stationary => {},
            // Reported down once if it never was, then gone: a lifted contact is one no longer listed.
            .ended => if (t.fresh[row]) {
                t.lift[row] = true;
            } else t.remove(row),
            .cancelled => {
                t.rows[row].pos = .{ -1, -1 };
                t.lift[row] = true;
            },
        }
    }

    fn find(t: *const Translator, id: u32) u32 {
        for (t.rows[0..t.n_rows], 0..) |r, i| if (r.id == id) return @intCast(i);
        return none;
    }

    fn remove(t: *Translator, row: u32) void {
        const n = t.n_rows;
        std.mem.copyForwards(Input.Contact, t.rows[row .. n - 1], t.rows[row + 1 .. n]);
        std.mem.copyForwards(bool, t.fresh[row .. n - 1], t.fresh[row + 1 .. n]);
        std.mem.copyForwards(bool, t.lift[row .. n - 1], t.lift[row + 1 .. n]);
        t.n_rows = n - 1;
    }

    /// A hardware key went down or up (`pressesBegan:` / `pressesEnded:`). `code` is the
    /// UIKey's `keyCode`, a USB HID usage, which is what `Input.keys` holds; `flags` its
    /// `modifierFlags` (UIKeyModifierFlags).
    pub fn key(t: *Translator, code: u32, down: bool, flags: u64) void {
        if (code == 0 or code > 0xff) return;
        t.in.mods = .{
            .shift = flags & mod_shift != 0,
            .ctrl = flags & mod_control != 0,
            .alt = flags & mod_alternate != 0,
            .cmd = flags & mod_command != 0,
        };
        const c: u8 = @intCast(code);
        const k = &t.in.keys.bits[c >> 6];
        const bit = @as(u64, 1) << @as(u6, @truncate(c));
        k.* = if (down) k.* | bit else k.* & ~bit;
        t.push(.{ .kind = if (down) .press else .release, .mods = t.in.mods, .code = c }, t.n_text);
    }

    /// Text the keyboard typed or the IME committed (`insertText:`): one `.text` event. It
    /// ends a composition. A line end is the Return key, as a press and a release, unless a
    /// hardware Return is held (its own events said so already).
    pub fn insert(t: *Translator, utf8: []const u8) void {
        t.composition = .{};
        if (std.mem.eql(u8, utf8, "\n")) return t.tap(key_return);
        if (!std.unicode.utf8ValidateSlice(utf8) or t.text.len - t.n_text < utf8.len) {
            t.dropped += 1;
            return;
        }
        const at = t.n_text;
        @memcpy(t.text[at..][0..utf8.len], utf8);
        t.n_text += @intCast(utf8.len);
        t.push(.{ .kind = .text, .mods = t.in.mods, .at = at, .len = @intCast(utf8.len) }, at);
    }

    /// The keyboard's delete key (`deleteBackward`): Backspace, as a press and a release,
    /// unless a hardware Backspace is held.
    pub fn deleteBackward(t: *Translator) void {
        t.tap(key_backspace);
    }

    fn tap(t: *Translator, code: u8) void {
        if (t.in.keys.down(code)) return;
        t.push(.{ .kind = .press, .mods = t.in.mods, .code = code }, t.n_text);
        t.push(.{ .kind = .release, .mods = t.in.mods, .code = code }, t.n_text);
    }

    /// The IME's marked text changed (`setMarkedText:selectedRange:`): `utf8`, with the byte
    /// range it selects (the clause being converted, or the caret). Empty ends the composition.
    pub fn mark(t: *Translator, utf8: []const u8, range: [2]u32) void {
        var n: usize = @min(utf8.len, max_preedit);
        while (n > 0 and n < utf8.len and utf8[n] & 0xc0 == 0x80) n -= 1;
        @memcpy(t.preedit[0..n], utf8[0..n]);
        const len: u32 = @intCast(n);
        t.composition = .{ .len = len, .range = .{ @min(range[0], len), @min(range[1], len) } };
    }

    /// The IME let go of its marked text without replacing it (`unmarkText`): it stays as
    /// typed text.
    pub fn unmark(t: *Translator) void {
        const c = t.composition;
        if (c.len == 0) return;
        var buf: [max_preedit]u8 = undefined;
        @memcpy(buf[0..c.len], t.preedit[0..c.len]);
        t.insert(buf[0..c.len]);
    }

    /// Pasteboard text (`UIPasteboard.string`, UTF-8) delivered as typed text, the way
    /// `keyboard.Clipboard` asks a host to answer a paste: one `.text` event, line ends as
    /// `\n`, other control characters but tabs left out. Invalid UTF-8, or a paste that does
    /// not fit, is dropped whole.
    pub fn paste(t: *Translator, utf8: []const u8) void {
        if (!std.unicode.utf8ValidateSlice(utf8)) {
            t.dropped += 1;
            return;
        }
        const at = t.n_text;
        var i: usize = 0;
        while (i < utf8.len) : (i += 1) {
            var ch = utf8[i];
            if (ch == '\r') {
                // \r\n and a lone \r are both one line end.
                if (i + 1 < utf8.len and utf8[i + 1] == '\n') i += 1;
                ch = '\n';
            }
            if ((ch < 0x20 and ch != '\n' and ch != '\t') or ch == 0x7f) continue;
            if (t.n_text == t.text.len) {
                t.n_text = at;
                t.dropped += 1;
                return;
            }
            t.text[t.n_text] = ch;
            t.n_text += 1;
        }
        if (t.n_text == at) return;
        t.push(.{ .kind = .text, .mods = t.in.mods, .at = at, .len = t.n_text - at }, at);
    }

    /// Appends `e`; if the events are full, takes back the text from `at` and counts it.
    fn push(t: *Translator, e: Input.Event, at: u32) void {
        if (t.n_events == t.events.len) {
            t.n_text = at;
            t.dropped += 1;
            return;
        }
        t.events[t.n_events] = e;
        t.n_events += 1;
    }

    /// A frame is owed without a new event: a release, a pointer leaving or a lift that the
    /// last frame deferred. The shell does not sleep while this holds.
    pub fn pending(t: *const Translator) bool {
        return t.release_next or t.leave_next or std.mem.indexOfScalar(bool, t.lift[0..t.n_rows], true) != null;
    }

    /// This frame's events, in `ev` until the next call. False once the app is terminating.
    pub fn frame(t: *Translator, ev: *Events) bool {
        const n = t.n_rows;
        @memcpy(t.out_rows[0..n], t.rows[0..n]);
        const o = t.out;
        @memcpy(o.text[0..t.n_text], t.text[0..t.n_text]);
        @memcpy(o.events[0..t.n_events], t.events[0..t.n_events]);
        ev.in = t.in;
        ev.in.contacts = t.out_rows[0..n];
        ev.in.text = o.text[0..t.n_text];
        ev.in.events = o.events[0..t.n_events];
        const c = t.composition;
        @memcpy(t.out_preedit[0..c.len], t.preedit[0..c.len]);
        ev.composition = .{ .text = t.out_preedit[0..c.len], .range = c.range };
        t.n_text = 0;
        t.n_events = 0;
        // What this frame reported is settled: lifted rows go, the deferred release follows.
        var row: u32 = n;
        while (row > 0) {
            row -= 1;
            if (t.lift[row]) t.remove(row);
        }
        @memset(t.fresh[0..t.n_rows], false);
        if (t.release_next) {
            t.release_next = false;
            t.in.buttons.left = false;
            t.leave_next = !t.primary_mouse;
            t.primary = none;
        } else if (t.leave_next) {
            t.leave_next = false;
            t.in.pointer = .{ -1, -1 };
        }
        t.primary_fresh = false;
        return !t.closed;
    }
};

/// Recorded UIKit events, replayed one frame per `next` into a translator, so tests drive it
/// (and, on iOS, the real view) with what a session produced. UTF-8 text, one line each:
///
///     # comment              blank lines and comments anywhere
///     frame                  starts a frame; the events below it arrive before its poll
///     bounds 390 844         the view's bounds, points
///     scale 3                its contentScaleFactor
///     insets 47 0 34 0       its safeAreaInsets: top, left, bottom, right
///     key down 4 shift       a hardware key (HID usage) down or up, with the modifiers held
///     insert hi              insertText: (the rest of the line; `\n` is Return)
///     delete                 deleteBackward
///     mark 0 3 にほ          setMarkedText: its selected byte range, then the text; no text ends it
///     unmark                 unmarkText
///     paste two words        the pasteboard's text, the rest of the line (`\n` for a line end)
///     touch began 1 37 25    a touch: phase, id, x, y, then optionally its `Kind` and pressure
///     terminate              applicationWillTerminate:
pub const Replay = struct {
    src: []const u8,
    at: usize = 0,
    /// 1-based number of the last line read; on an error, the line at fault.
    line: u32 = 0,

    pub const Error = error{Syntax};
    const Words = std.mem.TokenIterator(u8, .scalar);
    const Line = enum { bounds, scale, insets, touch, key, insert, delete, mark, unmark, paste, terminate };

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
                .bounds => t.resize(try num(&w), try num(&w)),
                .scale => t.setScale(try num(&w)),
                .insets => t.setInsets(try num(&w), try num(&w), try num(&w), try num(&w)),
                .touch => {
                    const phase = std.meta.stringToEnum(Phase, w.next() orelse return error.Syntax) orelse return error.Syntax;
                    const id = std.fmt.parseInt(u32, w.next() orelse return error.Syntax, 10) catch return error.Syntax;
                    var c: Touch = .{ .id = id, .phase = phase, .pos = .{ try num(&w), try num(&w) } };
                    if (w.next()) |k| c.kind = std.meta.stringToEnum(Kind, k) orelse return error.Syntax;
                    if (w.peek() != null) c.pressure = try num(&w);
                    t.touch(c);
                },
                .terminate => t.terminate(),
                .key => {
                    const down = std.mem.eql(u8, w.next() orelse return error.Syntax, "down");
                    const code = std.fmt.parseInt(u32, w.next() orelse return error.Syntax, 0) catch return error.Syntax;
                    var flags: u64 = 0;
                    while (w.next()) |m| flags |= @as(u64, switch (std.meta.stringToEnum(enum { shift, ctrl, alt, cmd }, m) orelse return error.Syntax) {
                        .shift => mod_shift,
                        .ctrl => mod_control,
                        .alt => mod_alternate,
                        .cmd => mod_command,
                    });
                    t.key(code, down, flags);
                },
                .delete => t.deleteBackward(),
                .unmark => t.unmark(),
                .mark => {
                    const a = std.fmt.parseInt(u32, w.next() orelse return error.Syntax, 10) catch return error.Syntax;
                    const b = std.fmt.parseInt(u32, w.next() orelse return error.Syntax, 10) catch return error.Syntax;
                    t.mark(w.rest(), .{ a, b });
                    continue;
                },
                .insert, .paste => |which| {
                    // The rest of the line, with `\n` for a line end, through a line-sized buffer.
                    var line: [256]u8 = undefined;
                    const rest = w.rest();
                    const n = std.mem.replace(u8, rest[0..@min(rest.len, line.len)], "\\n", "\n", &line);
                    const text = line[0 .. @min(rest.len, line.len) - n];
                    if (which == .insert) t.insert(text) else t.paste(text);
                    continue;
                },
            }
            if (w.next() != null) return error.Syntax;
        }
        return true;
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
    var r: Replay = .{ .src = "frame\nbounds 390\n" };
    try testing.expectError(error.Syntax, r.next(&t));
    try testing.expectEqual(@as(u32, 2), r.line);
    r = .{ .src = "frame\nshake\n" };
    try testing.expectError(error.Syntax, r.next(&t));
    r = .{ .src = "bounds 1 2\n" };
    try testing.expectError(error.Syntax, r.next(&t));
}

test "translate: the view's bounds lay out the example, and termination ends it" {
    // An iPhone in portrait, then rotated to landscape, then the app is terminated.
    var r: Replay = .{ .src =
        \\frame
        \\bounds 390 844
        \\frame
        \\frame
        \\bounds 844 390
        \\frame
        \\terminate
    };
    var t: Translator = .{};
    var ctx = try context.Context.init(&example_buffer, example_limits);
    var app: example.App = .{};
    var ev: Events = .{};
    const sizes = [_][2]f32{ .{ 390, 844 }, .{ 390, 844 }, .{ 844, 390 } };
    for (sizes) |vp| {
        try testing.expect(try r.next(&t));
        try testing.expect(t.frame(&ev));
        try testing.expectEqual(vp, ev.in.viewport);
        if (!ctx.needsFrame(&ev.in)) continue;
        var f = ctx.begin(&ev.in);
        app.build(&f, &ev);
        const out = f.end(.{});
        try testing.expect(out.status.ok());
        // The viewport fills what the sidebar leaves, whatever the orientation.
        try testing.expectEqual(types.Rect{ .x0 = 160, .y0 = 50, .x1 = vp[0], .y1 = vp[1] }, out.tree.rect(out.tree.find(example.id_viewport)));
    }
    try testing.expect(try r.next(&t));
    try testing.expect(!t.frame(&ev));
    try testing.expect(!try r.next(&t));
    // The second frame was unchanged: built once to settle, then the rotation.
    try testing.expectEqual(@as(u32, 3), app.builds);
}

const InputReplay = @import("../../core/input.zig").Replay;

test "translate: the example's touches give the recorded input and run the example" {
    // The same session twice: as UIKit events (testdata/example.uikit) and as the Input they
    // must become (testdata/example.replay). Frame by frame, the translator must give what the
    // recording holds; then the example must have done what the taps asked.
    var r: Replay = .{ .src = @embedFile("testdata/example.uikit") };
    var want: InputReplay = .{ .src = @embedFile("testdata/example.replay") };
    var want_text: [16]u8 = undefined;
    var want_events: [16]Input.Event = undefined;
    var want_contacts: [max_contacts]Input.Contact = undefined;
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
    try testing.expect(!t.pending());
    // The headless shell's results (src/shell/headless.zig): one reset, one layer added, the
    // exposure left at 3 by the cancelled finger.
    try testing.expectEqual(@as(u32, 1), app.resets);
    try testing.expectEqual(@as(u32, 4), app.layers);
    try testing.expectApproxEqAbs(@as(f32, 3), app.exposure, 0.01);
}

test "translate: pencils are pens, trackpad clicks are the mouse, extra fingers are dropped" {
    var t: Translator = .{};
    var ev: Events = .{};
    t.touch(.{ .id = 1, .phase = .began, .pos = .{ 10, 10 }, .kind = .pencil, .pressure = 0.5, .tilt = .{ 0.25, 0 } });
    _ = t.frame(&ev);
    try testing.expectEqual(Input.Contact{ .id = 1, .kind = .pen, .pos = .{ 10, 10 }, .pressure = 0.5, .tilt = .{ 0.25, 0 } }, ev.in.contacts[0]);
    t.touch(.{ .id = 1, .phase = .ended, .pos = .{ 10, 10 }, .kind = .pencil });
    _ = t.frame(&ev);
    _ = t.frame(&ev);
    try testing.expectEqual([2]f32{ -1, -1 }, ev.in.pointer);

    // A trackpad click on iPad: the mouse, no contact, and the pointer stays where it was.
    t.touch(.{ .id = 2, .phase = .began, .pos = .{ 20, 30 }, .kind = .pointer });
    _ = t.frame(&ev);
    try testing.expect(ev.in.buttons.left);
    try testing.expectEqual(@as(usize, 0), ev.in.contacts.len);
    t.touch(.{ .id = 2, .phase = .ended, .pos = .{ 25, 30 }, .kind = .pointer });
    _ = t.frame(&ev);
    _ = t.frame(&ev);
    try testing.expect(!ev.in.buttons.left);
    try testing.expectEqual([2]f32{ 25, 30 }, ev.in.pointer);

    for (0..max_contacts + 2) |i| t.touch(.{ .id = @intCast(10 + i), .phase = .began, .pos = .{ 1, 1 } });
    _ = t.frame(&ev);
    try testing.expectEqual(@as(usize, max_contacts), ev.in.contacts.len);
    try testing.expectEqual(@as(u32, 2), t.dropped);
    // A move of a dropped touch is ignored.
    t.touch(.{ .id = 10 + max_contacts, .phase = .moved, .pos = .{ 2, 2 } });
    _ = t.frame(&ev);
    try testing.expectEqual(none, ev.in.contact(10 + max_contacts));
}

test "translate: scale and safe area, portrait then landscape" {
    // An iPhone 15: 393 x 852 points at 3x; the Dynamic Island above, the home indicator below.
    // Rotated, the island's side and the opposite one are inset alike, the bottom less.
    var r: Replay = .{ .src =
        \\frame
        \\bounds 393 852
        \\scale 3
        \\insets 59 0 34 0
        \\touch began 1 100 70
        \\frame
        \\touch ended 1 100 70
        \\bounds 852 393
        \\insets 0 59 21 59
    };
    var t: Translator = .{};
    var ctx = try context.Context.init(&example_buffer, example_limits);
    var app: example.App = .{};
    var ev: Events = .{};
    const want = [_]struct { vp: [2]f32, safe: [4]f32, sidebar: types.Rect }{
        .{ .vp = .{ 393, 852 }, .safe = .{ 0, 59, 0, 34 }, .sidebar = .{ .x0 = 0, .y0 = 59 + 50, .x1 = 160, .y1 = 852 - 34 } },
        .{ .vp = .{ 852, 393 }, .safe = .{ 59, 0, 59, 21 }, .sidebar = .{ .x0 = 59, .y0 = 50, .x1 = 59 + 160, .y1 = 393 - 21 } },
    };
    for (want) |w| {
        try testing.expect(try r.next(&t));
        try testing.expect(t.frame(&ev));
        try testing.expectEqual(@as(f32, 3), ev.in.scale);
        try testing.expectEqual(w.vp, ev.in.viewport);
        try testing.expectEqual(w.safe, t.safe);
        // Touches stay in points whatever the scale.
        try testing.expectEqual([2]f32{ 100, 70 }, ev.in.pointer);
        // The host pads its root with the safe area: the example stays clear of the island
        // and the home indicator.
        var f = ctx.begin(&ev.in);
        _ = f.open(.from("safe-area"), .{ .size = .{ .fill, .fill }, .pad = t.safe });
        app.build(&f, &ev);
        f.close();
        const out = f.end(.{});
        try testing.expect(out.status.ok());
        try testing.expectEqual(w.sidebar, out.tree.rect(out.tree.find(example.id_sidebar)));
    }
}

test "translate: pasted text is typed in one event, line ends as \\n, control characters out" {
    var r: Replay = .{ .src =
        \\frame
        \\paste two\nlines é
        \\frame
    };
    var text: [64]u8 = undefined;
    var events: [8]Input.Event = undefined;
    var t: Translator = .init(.{ .text = &text, .events = &events });
    var ev: Events = .{};
    try testing.expect(try r.next(&t));
    t.paste("a\r\nb\rc\x07\td");
    _ = t.frame(&ev);
    try testing.expectEqualStrings("two\nlines \u{e9}a\nb\nc\td", ev.in.text);
    try testing.expectEqualSlices(Input.Event, &.{
        .{ .kind = .text, .at = 0, .len = 12 },
        .{ .kind = .text, .at = 12, .len = 7 },
    }, ev.in.events);
    // The next frame starts empty; a paste that does not fit (32 bytes a half), or that is not
    // UTF-8, is dropped whole.
    try testing.expect(try r.next(&t));
    const long: [33]u8 = @splat('x');
    t.paste(&long);
    t.paste("\xff");
    _ = t.frame(&ev);
    try testing.expectEqualStrings("", ev.in.text);
    try testing.expectEqual(@as(usize, 0), ev.in.events.len);
    try testing.expectEqual(@as(u32, 2), t.dropped);
}

test "translate: the soft keyboard types, Return and delete are keys, hardware keys are held" {
    var r: Replay = .{ .src =
        \\frame
        \\insert hi
        \\insert \n
        \\delete
        \\frame
        \\# A hardware keyboard: Shift then A down (HID 0xe1, 0x04); UIKit also inserts the text.
        \\key down 0xe1 shift
        \\key down 0x04 shift
        \\insert A
        \\# Its Return: the key events say it, the inserted line end adds nothing.
        \\key down 0x28 shift
        \\insert \n
        \\frame
        \\key up 0x28 shift
        \\key up 0x04 shift
        \\key up 0xe1
    };
    var text: [64]u8 = undefined;
    var events: [16]Input.Event = undefined;
    var t: Translator = .init(.{ .text = &text, .events = &events });
    var ev: Events = .{};
    try testing.expect(try r.next(&t));
    _ = t.frame(&ev);
    try testing.expectEqualStrings("hi", ev.in.text);
    try testing.expectEqualSlices(Input.Event, &.{
        .{ .kind = .text, .at = 0, .len = 2 },
        .{ .kind = .press, .code = 0x28 },
        .{ .kind = .release, .code = 0x28 },
        .{ .kind = .press, .code = 0x2a },
        .{ .kind = .release, .code = 0x2a },
    }, ev.in.events);

    try testing.expect(try r.next(&t));
    _ = t.frame(&ev);
    const shift: Input.Mods = .{ .shift = true };
    try testing.expectEqualStrings("A", ev.in.text);
    try testing.expectEqualSlices(Input.Event, &.{
        .{ .kind = .press, .code = 0xe1, .mods = shift },
        .{ .kind = .press, .code = 0x04, .mods = shift },
        .{ .kind = .text, .at = 0, .len = 1, .mods = shift },
        .{ .kind = .press, .code = 0x28, .mods = shift },
    }, ev.in.events);
    try testing.expect(ev.in.keys.down(0x04) and ev.in.keys.down(0xe1) and ev.in.keys.down(0x28));
    try testing.expectEqual(shift, ev.in.mods);

    try testing.expect(try r.next(&t));
    _ = t.frame(&ev);
    try testing.expectEqual(Input.Keys{}, ev.in.keys);
    try testing.expectEqual(Input.Mods{}, ev.in.mods);
}

test "ime: marked text is shown, converted, then committed as typed text" {
    // Japanese romaji: n-i-h-o-n marks にほん with the caret at its end, the space bar converts
    // it to 日本 (the whole clause selected), Return commits it; then a composition let go of.
    var r: Replay = .{ .src =
        \\frame
        \\mark 9 9 にほん
        \\frame
        \\mark 0 6 日本
        \\frame
        \\insert 日本
        \\frame
        \\mark 3 3 か
        \\unmark
    };
    var text: [64]u8 = undefined;
    var events: [16]Input.Event = undefined;
    var t: Translator = .init(.{ .text = &text, .events = &events });
    var ev: Events = .{};
    const want = [_]struct { text: []const u8, range: [2]u32, typed: []const u8 }{
        .{ .text = "にほん", .range = .{ 9, 9 }, .typed = "" },
        .{ .text = "日本", .range = .{ 0, 6 }, .typed = "" },
        .{ .text = "", .range = .{ 0, 0 }, .typed = "日本" },
        .{ .text = "", .range = .{ 0, 0 }, .typed = "か" },
    };
    for (want) |w| {
        try testing.expect(try r.next(&t));
        _ = t.frame(&ev);
        try testing.expectEqualStrings(w.text, ev.composition.text);
        try testing.expectEqual(w.range, ev.composition.range);
        try testing.expectEqualStrings(w.typed, ev.in.text);
    }
    // Marked text longer than the buffer is cut at a character, its range clamped.
    const long: [Translator.max_preedit / 3 + 1][3]u8 = @splat("あ".*);
    t.mark(std.mem.asBytes(&long), .{ 0, 1000 });
    _ = t.frame(&ev);
    try testing.expectEqual(@as(usize, Translator.max_preedit / 3 * 3), ev.composition.text.len);
    try testing.expectEqual([2]u32{ 0, Translator.max_preedit / 3 * 3 }, ev.composition.range);
}
