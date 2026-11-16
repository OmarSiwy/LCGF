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

/// The window messages the translator reads, by their winuser.h values.
pub const Wm = enum(u32) {
    size = 0x0005,
    close = 0x0010,
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

pub const Translator = struct {
    /// Held state, kept from message to message: viewport, pointer, buttons, keys.
    in: Input = .{},
    /// `WM_CLOSE` arrived: the user asked to close the window.
    closed: bool = false,

    /// Clears the per-frame state, before the messages of the next frame.
    pub fn begin(t: *Translator) void {
        t.in.wheel = .{ 0, 0 };
        t.in.scroll = .{ 0, 0 };
        t.in.text = "";
        t.in.events = &.{};
        t.in.contacts = &.{};
    }

    /// Reads one message. Messages the translator does not know are ignored.
    pub fn feed(t: *Translator, m: Msg) void {
        switch (@as(Wm, @fromBackingInt(@intCast(m.msg)))) {
            .size => {
                // A minimized window keeps the size it had, so the UI does not lay out for 0 x 0.
                if (m.wparam == size_minimized) return;
                const s = words(m.lparam);
                t.in.viewport = .{ @floatFromInt(s[0]), @floatFromInt(s[1]) };
            },
            .close => t.closed = true,
            _ => {},
        }
    }

    /// This frame's events. False once the window was closed.
    pub fn frame(t: *const Translator, ev: *Events) bool {
        ev.in = t.in;
        return !t.closed;
    }
};

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
        t.begin();
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
