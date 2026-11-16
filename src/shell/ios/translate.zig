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

pub const Translator = struct {
    /// Held state, kept from event to event: viewport, scale, pointer, buttons, keys, mods.
    in: Input = .{},
    /// The application is terminating (`applicationWillTerminate:`): no more frames.
    closed: bool = false,

    /// The view's bounds changed (`layoutSubviews`): `w` x `h` points.
    pub fn resize(t: *Translator, w: f32, h: f32) void {
        t.in.viewport = .{ w, h };
    }

    pub fn terminate(t: *Translator) void {
        t.closed = true;
    }

    /// This frame's events, in `ev` until the next call. False once the app is terminating.
    pub fn frame(t: *Translator, ev: *Events) bool {
        ev.in = t.in;
        return !t.closed;
    }
};

/// Recorded UIKit events, replayed one frame per `next` into a translator, so tests drive it
/// (and, on iOS, the real view) with what a session produced. UTF-8 text, one line each:
///
///     # comment              blank lines and comments anywhere
///     frame                  starts a frame; the events below it arrive before its poll
///     bounds 390 844         the view's bounds, points
///     terminate              applicationWillTerminate:
pub const Replay = struct {
    src: []const u8,
    at: usize = 0,
    /// 1-based number of the last line read; on an error, the line at fault.
    line: u32 = 0,

    pub const Error = error{Syntax};
    const Words = std.mem.TokenIterator(u8, .scalar);
    const Line = enum { bounds, terminate };

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
                .terminate => t.terminate(),
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
