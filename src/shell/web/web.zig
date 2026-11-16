//! The web shell: a `<canvas>` in a browser page. The page's JavaScript (shell.js) turns DOM
//! events into calls on this struct through the wasm module's exports, and drives frames with
//! `requestAnimationFrame`; this struct turns those calls into `Events` and the frame's effects
//! back into calls on `host`, the module's imports.
//!
//! A browser never lets wasm block, so the loop is the host page's and each animation frame runs
//! one turn of `iface.run`'s body (route 2 of src/shell/iface.zig, "Embedding"):
//!
//!     export fn lcgr_frame(ms: f64) void {           // shell.js calls it from requestAnimationFrame
//!         shell.time(ms / 1000);
//!         if (!shell.poll(&ev)) return;
//!         if (ctx.needsFrame(&ev.in)) { ...build; shell.apply(&out.platform); shell.present(&out); }
//!         shell.wait(scheduler.wake(&ctx, &ev.in), scheduler.pace(&ctx));
//!     }
//!
//! `wait` cannot block either: it asks the page for the next animation frame, or for none
//! until the next event, and returns.
//!
//! Generic over `host`, a namespace of the functions below, so this file is plain Zig: the wasm
//! example passes its imports (main.zig), the tests a recording stand-in.
//!
//!   fn present(*const Output) void          draw the frame (WebGPU or the 2D canvas)
//!   fn schedule(seconds: f32, pace: Pace) void
//!        when the next animation frame is wanted: in `seconds`, never for inf (only after an
//!        event)
const std = @import("std");
const types = @import("../../core/types.zig");
const Input = @import("../../core/input.zig").Input;
const context = @import("../../runtime/context.zig");
const scheduler = @import("../../runtime/scheduler.zig");
const iface = @import("../iface.zig");
const Events = iface.Events;
const Platform = context.Platform;
const Output = context.Output;
const Pace = scheduler.Pace;

pub fn Web(comptime host: type) type {
    return struct {
        const Self = @This();

        /// Held state and what arrived since the last `poll`.
        in: Input = .{},
        /// Time of the previous frame, seconds; `time` sets `in.dt` from it.
        last: f64 = -1,
        /// False after `close` (the page is going away): `poll` gives no more frames.
        open: bool = true,
        /// Set by `wake`; the next `poll` reports it in `wakes`.
        woken: std.atomic.Value(bool) = .init(false),
        polls: u32 = 0,
        wakes: u32 = 0,

        /// The canvas's size in CSS pixels (logical) and the device pixel ratio.
        pub fn resize(s: *Self, css_w: f32, css_h: f32, dpr: f32) void {
            s.in.viewport = .{ css_w, css_h };
            s.in.scale = dpr;
        }

        /// The pointer moved to (x, y), CSS pixels from the canvas's top left.
        pub fn pointer(s: *Self, x: f32, y: f32) void {
            s.in.pointer = .{ x, y };
        }

        /// The pointer left the canvas.
        pub fn leave(s: *Self) void {
            s.in.pointer = .{ -1, -1 };
        }

        /// Mouse button `button` (DOM numbering: 0 left, 1 middle, 2 right) went down or up.
        pub fn button(s: *Self, b: u32, down: bool) void {
            const bit: u8 = switch (b) {
                0 => 1, // left
                1 => 4, // middle
                2 => 2, // right
                else => 0,
            };
            const held: u8 = @bitCast(s.in.buttons);
            s.in.buttons = @bitCast(if (down) held | bit else held & ~bit);
        }

        /// The animation frame's timestamp, seconds. Call before `poll`.
        pub fn time(s: *Self, seconds: f64) void {
            s.in.dt = if (s.last < 0) 1.0 / 60.0 else @floatCast(@max(seconds - s.last, 0));
            s.in.time = seconds;
            s.last = seconds;
        }

        pub fn close(s: *Self) void {
            s.open = false;
        }

        /// What arrived since the last poll. Never blocks; false after `close`.
        pub fn poll(s: *Self, ev: *Events) bool {
            if (!s.open) return false;
            s.wakes += @intFromBool(s.woken.swap(false, .acq_rel));
            s.polls += 1;
            ev.in = s.in;
            return true;
        }

        pub fn apply(_: *Self, _: *const Platform) void {}

        pub fn present(_: *Self, out: *const Output) void {
            host.present(out);
        }

        /// Asks the page for the next animation frame, unless `seconds` is inf (idle: the next
        /// event asks for one). Never blocks: a page's script may not.
        pub fn wait(_: *Self, seconds: f32, pace: Pace) void {
            host.schedule(seconds, pace);
        }

        /// The next `poll` gives a frame even with no event, and the page runs one soon.
        pub fn wake(s: *Self) void {
            s.woken.store(true, .release);
            host.schedule(0, .once);
        }
    };
}

const testing = std.testing;
const mem = @import("../../core/mem.zig");
const Replay = @import("../../core/input.zig").Replay;
const example = @import("../example.zig");

/// The page, recorded: what the shell asked of it.
const Page = struct {
    var presents: u32 = 0;
    var scheduled: f32 = -1;
    var pace: Pace = .idle;

    pub fn present(_: *const Output) void {
        presents += 1;
    }
    pub fn schedule(seconds: f32, p: Pace) void {
        scheduled = seconds;
        pace = p;
    }
};

comptime {
    iface.check(Web(Page));
}

const example_limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
var example_buffer: [context.Context.requiredBytes(example_limits)]u8 align(mem.column_align) = undefined;

/// One animation frame of the example, as lcgr_frame runs it.
fn animationFrame(shell: anytype, ctx: *context.Context, app: *example.App, ms: f64) void {
    var ev: Events = .{};
    shell.time(ms / 1000);
    if (!shell.poll(&ev)) return;
    if (ctx.needsFrame(&ev.in)) {
        var f = ctx.begin(&ev.in);
        app.build(&f, &ev);
        const out = f.end(.{});
        shell.apply(&out.platform);
        shell.present(&out);
    }
    shell.wait(scheduler.wake(ctx, &ev.in), scheduler.pace(ctx));
}

/// Plays a recording (src/core/input.zig `Replay`) into the shell the way shell.js forwards DOM
/// events: what changed since the previous frame becomes one call each, then one animation frame.
pub fn replay(shell: anytype, ctx: *context.Context, app: *example.App, recording: []const u8) !u32 {
    var r: Replay = .{ .src = recording };
    var text: [64]u8 = undefined;
    var events: [16]Input.Event = undefined;
    var contacts: [4]Input.Contact = undefined;
    var prev: Input = .{};
    var frames: u32 = 0;
    while (try r.next(.{ .text = &text, .events = &events, .contacts = &contacts })) |in| : (frames += 1) {
        if (!std.meta.eql(in.viewport, prev.viewport) or in.scale != prev.scale) shell.resize(in.viewport[0], in.viewport[1], in.scale);
        if (!std.meta.eql(in.pointer, prev.pointer)) shell.pointer(in.pointer[0], in.pointer[1]);
        const dom = [_]u32{ 0, 2, 1 }; // left, right, middle
        inline for (.{ "left", "right", "middle" }, dom) |name, b| {
            if (@field(in.buttons, name) != @field(prev.buttons, name)) shell.button(b, @field(in.buttons, name));
        }
        prev = in.*;
        animationFrame(shell, ctx, app, in.time * 1000);
    }
    return frames;
}

test "web: the example replays through the shell's calls with the headless shell's results" {
    var ctx = try context.Context.init(&example_buffer, example_limits);
    var app: example.App = .{};
    var shell: Web(Page) = .{};
    Page.presents = 0;
    const frames = try replay(&shell, &ctx, &app, @embedFile("../testdata/example.replay"));
    // The same results as src/shell/headless.zig "headless: runs the example from a recording".
    try testing.expectEqual(@as(u32, 15), frames);
    try testing.expectEqual(@as(u32, 15), shell.polls);
    try testing.expectEqual(@as(u32, 13), app.builds);
    try testing.expectEqual(app.builds, Page.presents);
    try testing.expectEqual(@as(u32, 1), app.resets);
    try testing.expectEqual(@as(u32, 4), app.layers);
    try testing.expectApproxEqAbs(@as(f32, 3), app.exposure, 0.01);
    // Idle at the end: no frame until the next event.
    try testing.expectEqual(types.inf, Page.scheduled);
    try testing.expectEqual(Pace.idle, Page.pace);
}

test "web: buttons follow DOM numbering; time sets dt; close ends the frames" {
    var shell: Web(Page) = .{};
    shell.button(2, true);
    shell.button(1, true);
    try testing.expect(shell.in.buttons.right and shell.in.buttons.middle and !shell.in.buttons.left);
    shell.button(2, false);
    try testing.expect(!shell.in.buttons.right and shell.in.buttons.middle);
    shell.time(1);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 60.0), shell.in.dt, 1e-6);
    shell.time(1.25);
    try testing.expectApproxEqAbs(@as(f32, 0.25), shell.in.dt, 1e-6);
    var ev: Events = .{};
    try testing.expect(shell.poll(&ev));
    shell.close();
    try testing.expect(!shell.poll(&ev));
}
