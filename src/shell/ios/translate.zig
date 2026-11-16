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

/// Most fingers and pencils followed at once; iOS reports at most 10 fingers on a screen.
pub const max_contacts = 16;

pub const Translator = struct {
    /// Held state, kept from event to event: viewport, scale, pointer, buttons, keys, mods.
    in: Input = .{},
    /// The application is terminating (`applicationWillTerminate:`): no more frames.
    closed: bool = false,
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
    /// Touches beyond `max_contacts`, since `init`.
    dropped: u32 = 0,

    /// The view's bounds changed (`layoutSubviews`): `w` x `h` points.
    pub fn resize(t: *Translator, w: f32, h: f32) void {
        t.in.viewport = .{ w, h };
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

    /// A frame is owed without a new event: a release, a pointer leaving or a lift that the
    /// last frame deferred. The shell does not sleep while this holds.
    pub fn pending(t: *const Translator) bool {
        return t.release_next or t.leave_next or std.mem.indexOfScalar(bool, t.lift[0..t.n_rows], true) != null;
    }

    /// This frame's events, in `ev` until the next call. False once the app is terminating.
    pub fn frame(t: *Translator, ev: *Events) bool {
        const n = t.n_rows;
        @memcpy(t.out_rows[0..n], t.rows[0..n]);
        ev.in = t.in;
        ev.in.contacts = t.out_rows[0..n];
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
///     touch began 1 37 25    a touch: phase, id, x, y, then optionally its `Kind` and pressure
///     terminate              applicationWillTerminate:
pub const Replay = struct {
    src: []const u8,
    at: usize = 0,
    /// 1-based number of the last line read; on an error, the line at fault.
    line: u32 = 0,

    pub const Error = error{Syntax};
    const Words = std.mem.TokenIterator(u8, .scalar);
    const Line = enum { bounds, touch, terminate };

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
                .touch => {
                    const phase = std.meta.stringToEnum(Phase, w.next() orelse return error.Syntax) orelse return error.Syntax;
                    const id = std.fmt.parseInt(u32, w.next() orelse return error.Syntax, 10) catch return error.Syntax;
                    var c: Touch = .{ .id = id, .phase = phase, .pos = .{ try num(&w), try num(&w) } };
                    if (w.next()) |k| c.kind = std.meta.stringToEnum(Kind, k) orelse return error.Syntax;
                    if (w.peek() != null) c.pressure = try num(&w);
                    t.touch(c);
                },
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
