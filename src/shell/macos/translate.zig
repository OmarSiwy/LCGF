//! AppKit events as `Events`: the part of the macOS shell (macos.zig) that touches no OS, so it
//! builds and is tested on any host. The shell's view and window-delegate methods read each
//! NSEvent or notification into plain values and hand them to the `Translator`; `poll` drains
//! AppKit's queue and calls `frame`. Everything the translator keeps is carved from the caller's
//! buffers; it allocates nothing.
//!
//! Coordinates are AppKit's: points (logical pixels; the backing scale is apart), window
//! coordinates with the origin at the bottom left. The translator flips them to the top-left
//! origin `Input` uses.

const std = @import("std");
const Input = @import("../../core/input.zig").Input;
const Events = @import("../iface.zig").Events;

/// One thing the window reported: what the view and window-delegate methods hand the translator.
/// `Replay` reads these from a recording.
pub const Record = union(enum) {
    /// windowDidResize: the content view's size, in points.
    resize: [2]f64,
    /// windowShouldClose: the user asked to close the window.
    close,
};

pub const Translator = struct {
    /// Held state, kept from event to event: viewport, scale, pointer, buttons, keys, mods.
    in: Input = .{},
    /// windowShouldClose: arrived.
    closed: bool = false,

    /// Reads one record.
    pub fn feed(t: *Translator, r: Record) void {
        switch (r) {
            .resize => |s| t.resize(s),
            .close => t.closed = true,
        }
    }

    /// The content view's size in points, which is the viewport in logical pixels.
    pub fn resize(t: *Translator, size: [2]f64) void {
        t.in.viewport = .{ @floatCast(size[0]), @floatCast(size[1]) };
    }

    /// This frame's events, in `ev` until the next call. False once the window was closed.
    pub fn frame(t: *Translator, ev: *Events) bool {
        ev.in = t.in;
        return !t.closed;
    }
};

/// Recorded AppKit events, replayed one frame per `next`, so tests drive the translator (and, on
/// macOS, a real window) with what a session produced. UTF-8 text, one record per line:
///
///     # comment              blank lines and comments anywhere
///     frame                  starts a frame; the records below it arrive before its poll
///     resize 800 600         a record: its `Record` name, then its values
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

    fn parse(l: []const u8) Error!Record {
        var it = std.mem.tokenizeScalar(u8, l, ' ');
        const tag = std.meta.stringToEnum(std.meta.Tag(Record), it.next().?) orelse return error.Syntax;
        const rec: Record = switch (tag) {
            .resize => .{ .resize = .{ try num(&it), try num(&it) } },
            .close => .close,
        };
        if (it.next() != null) return error.Syntax;
        return rec;
    }

    fn num(it: *std.mem.TokenIterator(u8, .scalar)) Error!f64 {
        return std.fmt.parseFloat(f64, it.next() orelse return error.Syntax) catch error.Syntax;
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
    r = .{ .src = "frame\nclose\nclose\n" };
    try testing.expectError(error.BufferFull, r.next(&buf));
}
