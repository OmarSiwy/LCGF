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
///     destroy                onDestroy
pub const Replay = struct {
    src: []const u8,
    at: usize = 0,
    /// 1-based number of the last line read; on an error, the line at fault.
    line: u32 = 0,

    pub const Error = error{Syntax};
    const Words = std.mem.TokenIterator(u8, .scalar);
    const Line = enum { window, destroy };

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
