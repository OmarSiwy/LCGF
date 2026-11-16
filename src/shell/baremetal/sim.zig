//! The simulator board: runs a bare-metal application on the desktop, as LVGL's desktop
//! simulators do, with the board's devices replaced by a recording and its panel by memory.
//!
//! - Input: an `input.Replay` recording, one frame per `read`, mapped onto the touch panel and
//!   the encoder by `input.sample` (the left button or a finger touches, wheel notches turn the
//!   encoder, the middle button pushes it).
//! - Clock: each frame advances the board's `Tick` by the recording's `dt`, so a run gives the
//!   same frames on any machine and at any speed.
//! - Panel: `flush` copies each area into a whole framebuffer, the picture a window would show,
//!   and counts the pixels it would have sent over the panel's bus.
//!
//! It uses no OS either, so the same board also runs on the target (firmware.zig).

const std = @import("std");
const Replay = @import("../../core/input.zig").Replay;
const sw = @import("../../render/sw/sw.zig");
const flushing = @import("flush.zig");
const input = @import("input.zig");
const tick = @import("tick.zig");

pub const Sim = struct {
    replay: Replay,
    replay_buffers: Replay.Buffers,
    clock: tick.Tick = .{},
    panel: sw.Framebuffer,
    /// Pixels flushed, over every frame: what the panel's bus carried.
    sent: u64 = 0,
    /// Why `read` returned null early: the recording has a bad line (`replay.line`) or a frame
    /// that does not fit the buffers.
    err: ?Replay.Error = null,

    /// A simulator replaying `recording` onto `panel`, which has the panel's size.
    pub fn init(recording: []const u8, buffers: Replay.Buffers, panel: sw.Framebuffer) Sim {
        return .{ .replay = .{ .src = recording }, .replay_buffers = buffers, .panel = panel };
    }

    pub fn read(b: *Sim) ?input.Sample {
        const in = (b.replay.next(b.replay_buffers) catch |e| {
            b.err = e;
            return null;
        }) orelse return null;
        b.clock.inc(tick.millis(in.dt));
        return input.sample(in);
    }

    pub fn flush(b: *Sim, a: flushing.Area, pixels: []const u32, stride: u32) void {
        for (0..a.h()) |y| @memcpy(b.panel.pixels[(a.y0 + y) * b.panel.stride + a.x0 ..][0..a.w()], pixels[y * stride ..][0..a.w()]);
        b.sent += @as(u64, a.w()) * a.h();
    }

    /// The next recorded frame is already here: an input event, at once.
    pub fn idle(_: *Sim) bool {
        return true;
    }
};

const testing = std.testing;
const mem = @import("../../core/mem.zig");
const Input = @import("../../core/input.zig").Input;
const Quad = @import("../../draw/draw_list.zig").Quad;
const context = @import("../../runtime/context.zig");
const iface = @import("../iface.zig");
const Baremetal = @import("shell.zig").Baremetal;
const example = @import("../example.zig");

comptime {
    iface.check(Baremetal(Sim));
}

const limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
const fb_w = 800;
const fb_h = 600;

const Fixture = struct {
    var ctx_buffer: [context.Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
    var panel: [sw.Framebuffer.len(fb_w, fb_h)]u32 = undefined;
    var lines: [flushing.Display.len(fb_w, 40)]u32 = undefined;
    var glyphs: [512]Quad = undefined;
    var first: [limits.texts]u32 = undefined;
    var count: [limits.texts]u32 = undefined;
    var text: [64]u8 = undefined;
    var events: [16]Input.Event = undefined;
    var contacts: [4]Input.Contact = undefined;
};

test "sim: the headless shell's recording runs the example on the simulated board" {
    var ctx = try context.Context.init(&Fixture.ctx_buffer, limits);
    var app: example.App = .{};
    var sim: Sim = .init(@embedFile("../testdata/example.replay"), .{ .text = &Fixture.text, .events = &Fixture.events, .contacts = &Fixture.contacts }, .init(&Fixture.panel, fb_w, fb_h, .rgba8));
    var shell: Baremetal(Sim) = .init(&sim, &sim.clock, fb_w, fb_h, 40, .rgba8, 1, .{ .pixels = &Fixture.lines, .glyphs = &Fixture.glyphs, .first = &Fixture.first, .count = &Fixture.count });
    iface.run(&shell, &ctx, &app);

    try testing.expectEqual(null, sim.err);
    try testing.expectEqual(@as(u32, 15), shell.polls);
    // What the recording did, as on the headless shell (src/shell/headless.zig).
    try testing.expectEqual(@as(u32, 1), app.resets);
    try testing.expectEqual(@as(u32, 4), app.layers);
    try testing.expectApproxEqAbs(@as(f32, 3), app.exposure, 0.01);
    // Every presented frame sent the whole panel: no damage tracking in the runtime front end.
    try testing.expectEqual(app.builds, shell.presents);
    try testing.expectEqual(@as(u64, shell.presents) * fb_w * fb_h, sim.sent);
    // Fifteen frames at the recording's default dt of 1/60 s, 17 ms each when rounded up.
    try testing.expectEqual(@as(u32, 15 * 17), sim.clock.now());
    // The picture, as on the headless shell.
    const th = app.theme;
    try testing.expectEqual(th.panel, sim.panel.at(80, 590));
    try testing.expectEqual(th.control, sim.panel.at(12, 74));
    try testing.expectEqual(shell.background, sim.panel.at(400, 300));
    try testing.expectEqual(th.text, sim.panel.at(20, 70));
}

test "sim: a bad recording stops the board and says where" {
    var sim: Sim = .init("frame\nviewport 800\n", .{ .text = &Fixture.text, .events = &Fixture.events, .contacts = &Fixture.contacts }, .init(&Fixture.panel, fb_w, fb_h, .rgba8));
    try testing.expectEqual(null, sim.read());
    try testing.expectEqual(error.Syntax, sim.err.?);
    try testing.expectEqual(@as(u32, 2), sim.replay.line);
}
