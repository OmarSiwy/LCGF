//! Session recording: each frame's `Input` written as the text `input.Replay` reads (its format
//! is documented there), so a session recorded in any shell replays in the headless shell
//! (src/shell/headless.zig) or through `Replay` directly. Held state is written when it changes,
//! per-frame state (wheel, scroll, key and text events, contacts) every frame it is there, and
//! `time` every frame, so a replay sees the recorded clock exactly. Floats are written in their
//! shortest round-trip form. The text goes into a caller-owned buffer; nothing is allocated.
//!
//! What the format cannot say is not recorded: a touch lifted but still listed (`down` false),
//! and typed text containing a newline (cut at the newline).

const std = @import("std");
const Input = @import("lcgf").input.Input;

pub const Recorder = struct {
    buf: []u8,
    len: usize = 0,
    frames: u32 = 0,
    /// A frame did not fit; recording stopped at the last whole frame.
    full: bool = false,
    /// Held state as last written (the `Replay` defaults to start).
    last: Input = .{},

    pub fn init(buf: []u8) Recorder {
        return .{ .buf = buf };
    }

    /// The recording so far.
    pub fn text(r: *const Recorder) []const u8 {
        return r.buf[0..r.len];
    }

    /// Appends one frame. Once a frame does not fit, nothing more is written.
    pub fn frame(r: *Recorder, in: *const Input) void {
        if (r.full) return;
        var w = std.Io.Writer.fixed(r.buf[r.len..]);
        r.write(&w, in) catch {
            r.full = true;
            return;
        };
        r.len += w.end;
        r.frames += 1;
        r.last = in.*;
    }

    fn write(r: *const Recorder, w: *std.Io.Writer, in: *const Input) std.Io.Writer.Error!void {
        const was = &r.last;
        try w.print("frame\ntime {d}\n", .{in.time});
        if (in.dt != was.dt) try w.print("dt {d}\n", .{in.dt});
        if (in.scale != was.scale) try w.print("scale {d}\n", .{in.scale});
        if (!std.meta.eql(in.viewport, was.viewport)) try w.print("viewport {d} {d}\n", .{ in.viewport[0], in.viewport[1] });
        if (!std.meta.eql(in.pointer, was.pointer)) try w.print("pointer {d} {d}\n", .{ in.pointer[0], in.pointer[1] });
        if (in.buttons != was.buttons) try flags(w, "buttons", in.buttons);
        if (in.mods != was.mods) try flags(w, "mods", in.mods);
        if (!std.meta.eql(in.keys.bits, was.keys.bits)) {
            try w.writeAll("keys");
            for (0..256) |code| if (in.keys.down(@intCast(code))) try w.print(" {d}", .{code});
            try w.writeAll("\n");
        }
        if (in.wheel[0] != 0 or in.wheel[1] != 0) try w.print("wheel {d} {d}\n", .{ in.wheel[0], in.wheel[1] });
        if (in.scroll[0] != 0 or in.scroll[1] != 0) try w.print("scroll {d} {d}\n", .{ in.scroll[0], in.scroll[1] });
        for (in.events) |e| switch (e.kind) {
            .text => {
                const t = in.typed(e);
                try w.print("text {s}\n", .{t[0 .. std.mem.indexOfScalar(u8, t, '\n') orelse t.len]});
            },
            else => {
                try w.print("{s} {d}", .{ @tagName(e.kind), e.code });
                try names(w, e.mods);
                try w.writeAll("\n");
            },
        };
        for (in.contacts) |c| switch (c.kind) {
            .touch => try w.print("touch {d} {d} {d} {d}\n", .{ c.id, c.pos[0], c.pos[1], c.pressure }),
            else => try w.print("{s} {d} {d} {d} {d} {d} {d}\n", .{ @tagName(c.kind), c.id, c.pos[0], c.pos[1], c.pressure, c.tilt[0], c.tilt[1] }),
        };
    }

    fn flags(w: *std.Io.Writer, setting: []const u8, v: anytype) !void {
        try w.writeAll(setting);
        try names(w, v);
        try w.writeAll("\n");
    }

    /// " name" for each set field of a bit set.
    fn names(w: *std.Io.Writer, v: anytype) !void {
        inline for (@typeInfo(@TypeOf(v)).@"struct".field_names) |name| {
            if (comptime name[0] == '_') continue;
            if (@field(v, name)) try w.print(" {s}", .{name});
        }
    }
};

const Replay = @import("lcgf").input.Replay;

test "Recorder: every kind of input comes back from Replay as it went in" {
    const ev = [_]Input.Event{
        .{ .kind = .press, .code = 30, .mods = .{ .ctrl = true, .shift = true } },
        .{ .kind = .text, .at = 0, .len = 5 },
        .{ .kind = .release, .code = 30 },
    };
    const touches = [_]Input.Contact{
        .{ .id = 7, .pos = .{ 10.5, 20 }, .pressure = 0.8 },
        .{ .id = 3, .kind = .pen, .pos = .{ 30, 40 }, .pressure = 0.5, .tilt = .{ 0.1, -0.2 } },
    };
    var keys: Input.Keys = .{};
    keys.press(30);
    keys.press(200);
    const frames = [_]Input{
        .{ .viewport = .{ 1024, 768 }, .scale = 2, .pointer = .{ 1.25, 3 } },
        .{ .time = 1.0 / 60.0, .viewport = .{ 1024, 768 }, .scale = 2, .pointer = .{ 1.25, 3 }, .buttons = .{ .left = true }, .mods = .{ .ctrl = true }, .keys = keys, .text = "héllo"[0..5], .events = &ev, .wheel = .{ 0, -0.25 }, .scroll = .{ 3.5, 0 } },
        .{ .time = 0.1, .dt = 0.05, .viewport = .{ 1024, 768 }, .scale = 2, .pointer = .{ -1, -1 }, .contacts = &touches },
    };
    var buf: [1024]u8 = undefined;
    var rec: Recorder = .init(&buf);
    for (&frames) |*in| rec.frame(in);
    try std.testing.expect(!rec.full);
    try std.testing.expectEqual(@as(u32, 3), rec.frames);

    var text: [64]u8 = undefined;
    var events: [8]Input.Event = undefined;
    var contacts: [4]Input.Contact = undefined;
    var replay: Replay = .{ .src = rec.text() };
    for (&frames) |*want| {
        const got = (try replay.next(.{ .text = &text, .events = &events, .contacts = &contacts })).?;
        try std.testing.expectEqual(want.stamp(), got.stamp());
        try std.testing.expectEqual(want.time, got.time);
        try std.testing.expectEqual(want.dt, got.dt);
    }
    try std.testing.expectEqual(null, try replay.next(.{ .text = &text, .events = &events, .contacts = &contacts }));
}

test "Recorder: a frame that does not fit stops the recording at the last whole frame" {
    var buf: [40]u8 = undefined;
    var rec: Recorder = .init(&buf);
    const in: Input = .{};
    rec.frame(&in);
    const one = rec.len;
    rec.frame(&.{ .pointer = .{ 123456, 654321 } });
    try std.testing.expect(rec.full);
    try std.testing.expectEqual(@as(u32, 1), rec.frames);
    try std.testing.expectEqual(one, rec.len);
}
