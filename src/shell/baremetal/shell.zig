//! The bare-metal shell: the shell contract (src/shell/iface.zig) on a board with no OS, no
//! window system and no GPU. Its three parts follow LVGL's driver model (docs.lvgl.io 9.5,
//! "Requirements"): `flush.zig` (draw buffer and flush), `input.zig` (touch and encoder) and
//! `tick.zig` (the millisecond clock). It allocates nothing: every buffer comes from the caller.
//!
//! The board is any type with these declarations, bound at compile time (no vtable, no stored
//! callback, as for the render back ends):
//!
//!   fn read(*Board) ?input.Sample
//!        Reads the touch panel and the encoder for one frame. Null when the board has no more
//!        frames to give (a recording ended); real hardware never returns null.
//!   fn flush(*Board, flush.Area, pixels: []const u32, stride: u32) void
//!        Copies one area of the draw buffer to the panel (flush.zig).
//!   fn idle(*Board) bool
//!        Sleeps until the next interrupt (`wfi`), or returns at once. True when an input event
//!        arrived (the touch controller's interrupt line, an encoder edge), which ends a `wait`.
//!
//! The application's timer interrupt calls `tick.inc`; any interrupt or core may call `wake`.

const std = @import("std");
const types = @import("../../core/types.zig");
const Quad = @import("../../draw/draw_list.zig").Quad;
const Mono = @import("../../text/protocol.zig").Mono;
const sw = @import("../../render/sw/sw.zig");
const context = @import("../../runtime/context.zig");
const scheduler = @import("../../runtime/scheduler.zig");
const iface = @import("../iface.zig");
const flushing = @import("flush.zig");
const input = @import("input.zig");
const tick = @import("tick.zig");
const Events = iface.Events;
const Platform = context.Platform;
const Output = context.Output;
const Pace = scheduler.Pace;
const Color = types.Color;

/// Compile error unless `Board` declares what the shell calls.
pub fn checkBoard(comptime Board: type) void {
    for ([_][]const u8{ "read", "flush", "idle" }) |name| {
        if (!@hasDecl(Board, name)) @compileError(@typeName(Board) ++ " is not a board: missing `" ++ name ++ "` (src/shell/baremetal/shell.zig)");
    }
}

pub fn Baremetal(comptime Board: type) type {
    comptime checkBoard(Board);
    return struct {
        const Self = @This();

        board: *Board,
        tick: *const tick.Tick,
        display: flushing.Display,
        /// Physical pixels per logical pixel.
        scale: f32,
        gfx: sw.Software = .{},
        font: Mono = .{},
        glyphs: Buffers,
        reader: input.Reader = .{},
        clock: tick.Clock,
        /// What `present` clears to before drawing.
        background: Color = .rgb(0, 0, 0),
        /// The panel's refresh period: with `Pace.display`, a `wait` lasts until this many
        /// milliseconds have passed since the last `poll`. 16 is 60 Hz; set the panel's own.
        frame_ms: u32 = 16,
        /// The tick of the last `poll`.
        polled_at: u32,
        /// The effects of the last frame, as `apply` received them. A board shows what it can
        /// (an on-screen keyboard for `wants_text`); it has no cursor.
        applied: Platform = .{},
        /// Set by `wake` from any interrupt or core.
        woken: std.atomic.Value(bool) = .init(false),
        polls: u32 = 0,
        presents: u32 = 0,
        /// Areas flushed by every `present`.
        flushed: u32 = 0,

        /// Caller-owned storage. `pixels` holds `flush.Display.len(width, rows)` pixels; `glyphs`
        /// one quad per byte of text in a frame, `first` and `count` one row per text run.
        pub const Buffers = struct { pixels: []u32 = &.{}, glyphs: []Quad, first: []u32, count: []u32 };

        /// A shell on a `width` x `height` panel (physical pixels) drawn through a buffer of
        /// `rows` rows (`height` for a whole framebuffer).
        pub fn init(board: *Board, clock: *const tick.Tick, width: u32, height: u32, rows: u32, format: sw.Format, scale: f32, buf: Buffers) Self {
            const now = clock.now();
            return .{
                .board = board,
                .tick = clock,
                .display = .init(buf.pixels, width, height, rows, format),
                .scale = scale,
                .glyphs = buf,
                .clock = .init(now),
                .polled_at = now,
            };
        }

        /// One frame of the board's devices and the clock. False when the board has no more.
        pub fn poll(s: *Self, ev: *Events) bool {
            const sample = s.board.read() orelse return false;
            const now = s.tick.now();
            ev.in.scale = s.scale;
            ev.in.viewport = .{ @as(f32, @floatFromInt(s.display.width)) / s.scale, @as(f32, @floatFromInt(s.display.height)) / s.scale };
            s.reader.read(sample, &ev.in);
            s.clock.step(now, &ev.in);
            s.polled_at = now;
            s.polls += 1;
            return true;
        }

        pub fn apply(s: *Self, p: *const Platform) void {
            s.applied = p.*;
        }

        /// Draws the frame's damage through the draw buffer and flushes it to the board.
        pub fn present(s: *Self, out: *const Output) void {
            s.presents += 1;
            const g = s.glyphs;
            const n = s.font.quads(out.draw, g.glyphs, .{ .first = g.first, .count = g.count });
            s.gfx.prepare({}, out.draw, .{ .quads = g.glyphs[0..n], .first = g.first, .count = g.count }, .{ 0, 0 }, s.scale);
            s.flushed += flushing.flush(&s.display, &s.gfx, out.draw, s.background, s.board);
        }

        /// Idles the board until an input event, a `wake`, or `seconds` have passed (`inf`:
        /// no time limit). With `Pace.display`, at least until `frame_ms` after the last poll.
        pub fn wait(s: *Self, seconds: f32, pace: Pace) void {
            const start = s.tick.now();
            const frame_left = s.frame_ms -| (start -% s.polled_at);
            const limit = if (pace == .display) @max(tick.millis(seconds), frame_left) else tick.millis(seconds);
            while (!s.woken.load(.acquire) and s.tick.now() -% start < limit) {
                if (s.board.idle()) break;
            }
            // The frame that follows answers any wake so far.
            s.woken.store(false, .release);
        }

        /// Interrupt- and thread-safe: ends a `wait` in progress, or the next one at once.
        pub fn wake(s: *Self) void {
            s.woken.store(true, .release);
        }
    };
}

const testing = std.testing;
const mem = @import("../../core/mem.zig");
const example = @import("../example.zig");
const Frame = @import("../../runtime/frame.zig").Frame;
const base = @import("../../widgets/base.zig");
const button = @import("../../widgets/button.zig");

/// A board that replays samples, one per frame, 16 ms apart, onto a panel in memory. `idle`
/// stands for one 1 ms timer interrupt; `events` says whether input arrives meanwhile.
const Script = struct {
    samples: []const input.Sample,
    at: usize = 0,
    clock: *tick.Tick,
    panel: sw.Framebuffer,
    events: bool = true,
    idles: u32 = 0,

    pub fn read(b: *Script) ?input.Sample {
        if (b.at == b.samples.len) return null;
        b.clock.inc(16);
        b.at += 1;
        return b.samples[b.at - 1];
    }
    pub fn flush(b: *Script, a: flushing.Area, pixels: []const u32, stride: u32) void {
        for (0..a.h()) |y| @memcpy(b.panel.pixels[(a.y0 + y) * b.panel.stride + a.x0 ..][0..a.w()], pixels[y * stride ..][0..a.w()]);
    }
    pub fn idle(b: *Script) bool {
        b.idles += 1;
        b.clock.inc(1);
        return b.events;
    }
};

comptime {
    iface.check(Baremetal(Script));
}

const limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
const fb_w = 480;
const fb_h = 320;

const Fixture = struct {
    var ctx_buffer: [context.Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
    var panel: [sw.Framebuffer.len(fb_w, fb_h)]u32 = undefined;
    var lines: [flushing.Display.len(fb_w, 20)]u32 = undefined;
    var glyphs: [512]Quad = undefined;
    var first: [limits.texts]u32 = undefined;
    var count: [limits.texts]u32 = undefined;

    fn shell(board: *Script) Baremetal(Script) {
        return .init(board, board.clock, fb_w, fb_h, 20, .rgba8, 1, .{ .pixels = &lines, .glyphs = &glyphs, .first = &first, .count = &count });
    }
};

test "baremetal: the example runs from touch and encoder samples" {
    var ctx = try context.Context.init(&Fixture.ctx_buffer, limits);
    var app: example.App = .{};
    var clock: tick.Tick = .{};
    const reset: input.Touch = .{ .pos = .{ 37, 25 }, .down = true };
    const add: input.Touch = .{ .pos = .{ 54, 74 }, .down = true };
    const samples = [_]input.Sample{
        .{}, // the first frame, then its settle frame
        .{},
        .{ .touch = reset }, // tap Reset
        .{ .touch = .{ .pos = reset.pos } },
        .{},
        .{ .encoder = .{ .steps = 1, .down = true } }, // Tab and Enter: the example's buttons ignore keys
        .{ .encoder = .{} },
        .{ .touch = add }, // tap Add layer
        .{},
        .{},
    };
    var board: Script = .{ .samples = &samples, .clock = &clock, .panel = .init(&Fixture.panel, fb_w, fb_h, .rgba8) };
    var shell = Fixture.shell(&board);
    iface.run(&shell, &ctx, &app);

    try testing.expectEqual(@as(u32, samples.len), shell.polls);
    try testing.expectEqual(app.builds, shell.presents);
    try testing.expectEqual(@as(u32, 1), app.resets);
    try testing.expectEqual(@as(u32, 4), app.layers);
    // 16 bands of 20 rows per frame: the runtime front end does not track damage yet.
    try testing.expectEqual(16 * shell.presents, shell.flushed);
    // The clock: ten frames 16 ms apart, plus the idles between them.
    try testing.expect(clock.now() >= 160);
    try testing.expectApproxEqAbs(@as(f64, @floatFromInt(clock.now())) / 1000, shell.clock.time, 1e-5);
    // What reached the panel: the sidebar, a button face, and the custom viewport left clear.
    try testing.expectEqual(app.theme.panel, board.panel.at(80, 310));
    try testing.expectEqual(app.theme.control, board.panel.at(12, 74));
    try testing.expectEqual(shell.background, board.panel.at(400, 200));
}

/// One button from widgets/button.zig, which also fires on Enter while focused.
const Knob = struct {
    theme: base.Theme = .default,
    fired: u32 = 0,

    pub fn build(k: *Knob, f: *Frame, _: *const Events) void {
        if (button.button(f, &k.theme, .from("ok"), "OK").clicked) k.fired += 1;
    }
};

test "baremetal: the encoder's push fires the button a tap focused" {
    var ctx = try context.Context.init(&Fixture.ctx_buffer, limits);
    var app: Knob = .{};
    var clock: tick.Tick = .{};
    const ok: input.Touch = .{ .pos = .{ 12, 12 }, .down = true };
    const samples = [_]input.Sample{
        .{},
        .{ .touch = ok }, // tap: fires, and focuses the button
        .{ .touch = .{ .pos = ok.pos } },
        .{},
        .{ .encoder = .{ .down = true } }, // push: Enter
        .{ .encoder = .{} },
        .{},
    };
    var board: Script = .{ .samples = &samples, .clock = &clock, .panel = .init(&Fixture.panel, fb_w, fb_h, .rgba8) };
    var shell = Fixture.shell(&board);
    iface.run(&shell, &ctx, &app);
    try testing.expectEqual(@as(u32, 2), app.fired);
}

test "baremetal: wait idles until a timeout, an input event or a wake" {
    var clock: tick.Tick = .{};
    var board: Script = .{ .samples = &.{.{}}, .clock = &clock, .panel = .init(&Fixture.panel, fb_w, fb_h, .rgba8), .events = false };
    var shell = Fixture.shell(&board);
    var ev: Events = .{};
    try testing.expect(shell.poll(&ev));

    // A timer 50 ms away: fifty 1 ms ticks.
    shell.wait(0.05, .timer);
    try testing.expectEqual(@as(u32, 50), board.idles);
    // Nothing pending: returns at once.
    shell.wait(0, .once);
    try testing.expectEqual(@as(u32, 50), board.idles);
    // Animating: until 16 ms after the poll, which was 50 ms ago, so at once too.
    shell.wait(0, .display);
    try testing.expectEqual(@as(u32, 50), board.idles);
    // A wake before the wait: no time limit, yet it returns at once.
    shell.wake();
    shell.wait(types.inf, .idle);
    try testing.expectEqual(@as(u32, 50), board.idles);
    // An input event ends the wait after one idle.
    board.events = true;
    shell.wait(types.inf, .idle);
    try testing.expectEqual(@as(u32, 51), board.idles);
    // The recording has ended.
    try testing.expect(!shell.poll(&ev));
}

test "baremetal: display pace waits out the panel's frame period" {
    var clock: tick.Tick = .{};
    var board: Script = .{ .samples = &.{.{}}, .clock = &clock, .panel = .init(&Fixture.panel, fb_w, fb_h, .rgba8), .events = false };
    var shell = Fixture.shell(&board);
    var ev: Events = .{};
    try testing.expect(shell.poll(&ev));
    clock.inc(4); // the frame took 4 ms
    shell.wait(0, .display);
    try testing.expectEqual(@as(u32, 12), board.idles);
}
