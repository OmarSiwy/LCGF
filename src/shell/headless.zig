//! The headless shell: a shell with no window, for tests. Its events come from an `input.Replay`
//! recording, one frame per `poll`, and `present` draws each frame with the software back end
//! (src/render/sw/) into a framebuffer the test reads. Everything it uses is carved from the
//! buffers the caller passes to `init`; it allocates nothing.
//!
//! Text runs are drawn as glyph quads from `protocol.Mono.quads` sampling texture 0 (white), so
//! every glyph is a solid cell of the run's colour: enough to see where text landed, not what it
//! says. Custom commands are skipped, as `iface.render` does: the host draws those.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../core/types.zig");
const Replay = @import("../core/input.zig").Replay;
const Quad = @import("../draw/draw_list.zig").Quad;
const Mono = @import("../text/protocol.zig").Mono;
const render = @import("../render/iface.zig");
const sw = @import("../render/sw/sw.zig");
const context = @import("../runtime/context.zig");
const iface = @import("iface.zig");
const Events = iface.Events;
const Platform = context.Platform;
const Output = context.Output;
const scheduler = @import("../runtime/scheduler.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Pace = scheduler.Pace;
const Color = types.Color;

pub const Headless = struct {
    /// For `wait` and `wake`, the only calls that block or signal.
    io: std.Io,
    replay: Replay,
    replay_buffers: Replay.Buffers,
    fb: sw.Framebuffer,
    gfx: sw.Software = .{},
    font: Mono = .{},
    glyphs: GlyphBuffers,
    /// What `present` clears to before drawing.
    background: Color = .rgb(0, 0, 0),
    /// Physical pixels per logical pixel of the frame being presented, from the last poll.
    scale: f32 = 1,
    /// The effects of the last frame, as `apply` received them.
    applied: Platform = .{},
    polls: u32 = 0,
    presents: u32 = 0,
    waits: u32 = 0,
    /// What the last `wait` was asked for.
    waited: struct { seconds: f32, pace: Pace } = .{ .seconds = 0, .pace = .idle },
    /// Set by `wake` from any thread.
    woken: std.Io.Event = .unset,
    /// Frames `poll` gave for a `wake` after the recording ended.
    wakes: u32 = 0,
    /// Once the recording has ended, the longest a `wait` blocks for a `wake`, in seconds. 0 (the
    /// default) returns at once, so `run` ends with the recording.
    linger: f32 = 0,
    /// Why `poll` returned false early: the recording has a bad line (`replay.line`) or a frame
    /// that does not fit the buffers.
    err: ?Replay.Error = null,

    /// Caller-owned storage. `pixels` holds `sw.Framebuffer.len(fb_w, fb_h)` pixels; `glyphs`
    /// one quad per byte of text in a frame, `first` and `count` one row per text run.
    pub const Buffers = struct {
        replay: Replay.Buffers,
        pixels: []u32,
        glyphs: []Quad,
        first: []u32,
        count: []u32,
    };
    const GlyphBuffers = struct { quads: []Quad, first: []u32, count: []u32 };

    /// A shell replaying `recording` into a `width` x `height` framebuffer (physical pixels).
    pub fn init(io: std.Io, recording: []const u8, width: u32, height: u32, buf: Buffers) Headless {
        return .{
            .io = io,
            .replay = .{ .src = recording },
            .replay_buffers = buf.replay,
            .fb = .init(buf.pixels, width, height, .rgba8),
            .glyphs = .{ .quads = buf.glyphs, .first = buf.first, .count = buf.count },
        };
    }

    /// The next recorded frame. After the last one, a frame only for a pending `wake`: the held
    /// input stays as it was, the per-frame input is empty. False when neither is left, or on a
    /// bad recording (`err`).
    pub fn poll(h: *Headless, ev: *Events) bool {
        // Any frame answers a wake; a wake posted after this line is seen by the next poll.
        const woken = h.woken.isSet();
        if (woken) h.woken.reset();
        const next = h.replay.next(h.replay_buffers) catch |e| {
            h.err = e;
            return false;
        };
        if (next) |in| {
            ev.in = in.*;
        } else {
            if (!woken) return false;
            h.wakes += 1;
            ev.in = h.replay.in;
            ev.in.wheel = .{ 0, 0 };
            ev.in.scroll = .{ 0, 0 };
            ev.in.text = "";
            ev.in.events = &.{};
            ev.in.contacts = &.{};
        }
        h.polls += 1;
        h.scale = ev.in.scale;
        return true;
    }

    pub fn apply(h: *Headless, p: *const Platform) void {
        h.applied = p.*;
    }

    /// Draws the frame into `fb`: clear, then every command but the custom ones. With a context
    /// that tracks damage (`Context.trackDamage`), only the rects that changed; `fb` keeps the rest.
    pub fn present(h: *Headless, out: *const Output) void {
        h.presents += 1;
        const g = h.glyphs;
        const n = h.font.quads(out.draw, g.quads, .{ .first = g.first, .count = g.count });
        h.gfx.prepare({}, out.draw, .{ .quads = g.quads[0..n], .first = g.first, .count = g.count }, .{ 0, 0 }, h.scale);
        h.gfx.redraw(&h.fb, h.fb.all(), out.draw, h.background);
    }

    /// While recorded frames remain, returns at once: the next one is the next event, and it is
    /// already here. After the last, blocks until `wake`, at most `linger` seconds.
    pub fn wait(h: *Headless, seconds: f32, pace: Pace) void {
        h.waits += 1;
        h.waited = .{ .seconds = seconds, .pace = pace };
        if (h.replay.at < h.replay.src.len) return;
        const s = @min(seconds, h.linger);
        if (!(s > 0)) return;
        const ns: i96 = @intFromFloat(s * std.time.ns_per_s);
        h.woken.waitTimeout(h.io, .{ .duration = .{ .raw = .fromNanoseconds(ns), .clock = .awake } }) catch {};
    }

    /// Thread-safe: ends a `wait` in progress, and has the next `poll` give a frame.
    pub fn wake(h: *Headless) void {
        h.woken.set(h.io);
    }
};

comptime {
    iface.check(Headless);
}

const testing = std.testing;
const mem = @import("../core/mem.zig");
const Input = @import("../core/input.zig").Input;
const example = @import("example.zig");

const example_limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
const fb_w = 800;
const fb_h = 600;

/// Everything the example and the shell need, static: the frame buffer alone is 1.9 MB.
const Fixture = struct {
    var ctx_buffer: [context.Context.requiredBytes(example_limits)]u8 align(mem.column_align) = undefined;
    var pixels: [sw.Framebuffer.len(fb_w, fb_h)]u32 = undefined;
    var glyphs: [512]Quad = undefined;
    var first: [example_limits.texts]u32 = undefined;
    var count: [example_limits.texts]u32 = undefined;
    var text: [64]u8 = undefined;
    var events: [16]Input.Event = undefined;
    var contacts: [4]Input.Contact = undefined;

    fn shell(recording: []const u8) Headless {
        return .init(testing.io, recording, fb_w, fb_h, .{
            .replay = .{ .text = &text, .events = &events, .contacts = &contacts },
            .pixels = &pixels,
            .glyphs = &glyphs,
            .first = &first,
            .count = &count,
        });
    }
};

test "headless: runs the example from a recording and draws it" {
    var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var app: example.App = .{};
    var shell = Fixture.shell(@embedFile("testdata/example.replay"));
    var ev: Events = .{};
    var cursors: [16]context.Cursor = undefined;
    var last: ?Output = null;
    while (shell.poll(&ev)) {
        cursors[shell.polls - 1] = shell.applied.cursor;
        if (!ctx.needsFrame(&ev.in)) continue;
        var f = ctx.begin(&ev.in);
        app.build(&f, &ev);
        const out = f.end(.{});
        shell.apply(&out.platform);
        shell.present(&out);
        cursors[shell.polls - 1] = shell.applied.cursor;
        last = out;
    }
    try testing.expectEqual(null, shell.err);
    try testing.expectEqual(@as(u32, 15), shell.polls);
    // The two idle frames (3 and 15) built and presented nothing.
    try testing.expectEqual(@as(u32, 13), app.builds);
    try testing.expectEqual(app.builds, shell.presents);

    // What the recording did to the application.
    try testing.expectEqual(@as(u32, 1), app.resets);
    try testing.expectEqual(@as(u32, 4), app.layers);
    try testing.expectApproxEqAbs(@as(f32, 3), app.exposure, 0.01);
    const C = context.Cursor;
    try testing.expectEqualSlices(C, &.{ .arrow, .arrow, .arrow, .pointer, .pointer, .pointer, .pointer, .pointer, .pointer, .arrow, .arrow, .arrow, .arrow, .arrow, .arrow }, cursors[0..15]);

    // What it drew: Reset, Wireframe, Add layer, Layer 0..3.
    const out = last.?;
    try testing.expectEqual(@as(u32, 7), out.draw.run_len);
    const th = app.theme;
    // The sidebar's panel, a button face at rest, and the custom viewport left to the host.
    try testing.expectEqual(th.panel, shell.fb.at(80, 590));
    try testing.expectEqual(th.control, shell.fb.at(12, 74));
    try testing.expectEqual(shell.background, shell.fb.at(400, 300));
    // A glyph cell of "Add layer" is the text colour.
    try testing.expectEqual(th.text, shell.fb.at(20, 70));
}

test "damage: redrawing only what changed gives every frame's full picture" {
    const limits: context.Limits = .{ .nodes = example_limits.nodes, .texts = example_limits.texts, .damage = true };
    const Store = struct {
        var ctx_buffer: [context.Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
        var pixels: [sw.Framebuffer.len(fb_w, fb_h)]u32 = undefined;
        var glyphs: [512]Quad = undefined;
        var first: [limits.texts]u32 = undefined;
        var count: [limits.texts]u32 = undefined;
        var text: [64]u8 = undefined;
        var events: [16]Input.Event = undefined;
        var contacts: [4]Input.Contact = undefined;
    };
    const recording = @embedFile("testdata/example.replay");
    var full_ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var part_ctx = try context.Context.init(&Store.ctx_buffer, limits);
    part_ctx.trackDamage();
    var full_app: example.App = .{};
    var part_app: example.App = .{};
    var full = Fixture.shell(recording);
    var part: Headless = .init(testing.io, recording, fb_w, fb_h, .{
        .replay = .{ .text = &Store.text, .events = &Store.events, .contacts = &Store.contacts },
        .pixels = &Store.pixels,
        .glyphs = &Store.glyphs,
        .first = &Store.first,
        .count = &Store.count,
    });
    var full_ev: Events = .{};
    var part_ev: Events = .{};
    var partial: u32 = 0;
    while (full.poll(&full_ev)) {
        try testing.expect(part.poll(&part_ev));
        if (!full_ctx.needsFrame(&full_ev.in)) {
            try testing.expect(!part_ctx.needsFrame(&part_ev.in));
            continue;
        }
        try testing.expect(part_ctx.needsFrame(&part_ev.in));
        var f = full_ctx.begin(&full_ev.in);
        full_app.build(&f, &full_ev);
        const full_out = f.end(.{});
        full.present(&full_out);
        var g = part_ctx.begin(&part_ev.in);
        part_app.build(&g, &part_ev);
        const part_out = g.end(.{});
        part.present(&part_out);
        partial += @intFromBool(part_out.draw.damage.pixels() < fb_w * fb_h);
        try testing.expectEqualSlices(u32, full.fb.pixels, part.fb.pixels);
    }
    // Some frames really were partial.
    try testing.expect(partial > 0);
}

test "run: the headless shell runs the example in one call" {
    var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var app: example.App = .{};
    var shell = Fixture.shell(@embedFile("testdata/example.replay"));
    iface.run(&shell, &ctx, &app);
    // The same results as the loop written out above.
    try testing.expectEqual(null, shell.err);
    try testing.expectEqual(@as(u32, 15), shell.polls);
    try testing.expectEqual(@as(u32, 13), app.builds);
    try testing.expectEqual(app.builds, shell.presents);
    try testing.expectEqual(@as(u32, 1), app.resets);
    try testing.expectEqual(@as(u32, 4), app.layers);
    try testing.expectApproxEqAbs(@as(f32, 3), app.exposure, 0.01);
    try testing.expectEqual(context.Cursor.arrow, shell.applied.cursor);
    try testing.expectEqual(app.theme.panel, shell.fb.at(80, 590));
    // One wait per poll, and the last one sleeps until the next event.
    try testing.expectEqual(shell.polls, shell.waits);
    try testing.expectEqual(types.inf, shell.waited.seconds);
    try testing.expectEqual(Pace.idle, shell.waited.pace);
}

test "embed: an engine's own loop runs the example" {
    // The engine owns the loop, its events (here a recording), its framebuffer and its tick.
    // The UI is one step per tick; no shell is involved.
    var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var app: example.App = .{};
    var replay: Replay = .{ .src = @embedFile("testdata/example.replay") };
    const buf: Replay.Buffers = .{ .text = &Fixture.text, .events = &Fixture.events, .contacts = &Fixture.contacts };
    var fb: sw.Framebuffer = .init(&Fixture.pixels, fb_w, fb_h, .rgba8);
    var gfx: sw.Software = .{};
    const font: Mono = .{};
    const scene: Color = .rgb(10, 80, 40);

    var ev: Events = .{};
    var out: ?Output = null;
    var ticks: u32 = 0;
    var simulated: u32 = 0;
    while (try replay.next(buf)) |in| : (ticks += 1) {
        ev.in = in.*;
        simulated += 1; // the engine's own work, every tick
        if (ctx.needsFrame(&ev.in)) {
            var f = ctx.begin(&ev.in);
            app.build(&f, &ev);
            out = f.end(.{});
        }
        // The engine draws every tick: its clear, then the UI, then its scene into the custom rect.
        const o = &out.?;
        fb.clear(.rgb(0, 0, 0));
        const n = font.quads(o.draw, &Fixture.glyphs, .{ .first = &Fixture.first, .count = &Fixture.count });
        gfx.prepare({}, o.draw, .{ .quads = Fixture.glyphs[0..n], .first = &Fixture.first, .count = &Fixture.count }, .{ 0, 0 }, 1);
        const pass: sw.Target = .{ .fb = &fb, .scissor = fb.all() };
        var i = render.drawUntilCustom(&gfx, pass, o.draw, 0);
        while (i < o.draw.cmd_len) : (i = render.drawUntilCustom(&gfx, pass, o.draw, i + 1)) {
            const r = o.draw.customs[o.draw.command(i).custom].rect;
            fb.fill(.{ @intFromFloat(r[0]), @intFromFloat(r[1]), @intFromFloat(r[2]), @intFromFloat(r[3]) }, scene);
        }
    }
    try testing.expectEqual(@as(u32, 15), ticks);
    try testing.expectEqual(ticks, simulated);
    // The UI built only the frames that changed; the results match the shell's.
    try testing.expectEqual(@as(u32, 13), app.builds);
    try testing.expectEqual(@as(u32, 1), app.resets);
    try testing.expectEqual(@as(u32, 4), app.layers);
    try testing.expectApproxEqAbs(@as(f32, 3), app.exposure, 0.01);
    try testing.expectEqual(app.theme.panel, fb.at(80, 590));
    try testing.expectEqual(scene, fb.at(400, 300));
}

/// The example with a background job: the app drains the job's results in `build`.
const WithJob = struct {
    app: example.App = .{},
    mailbox: *scheduler.Mailbox(u32),
    result: u32 = 0,

    pub fn build(j: *WithJob, f: *Frame, ev: *const Events) void {
        while (j.mailbox.pop()) |r| j.result = r;
        j.app.build(f, ev);
    }
};

fn job(mailbox: *scheduler.Mailbox(u32), ctx: *context.Context, shell: *Headless) void {
    // Long enough that the UI thread is asleep in `wait` first.
    std.Io.sleep(shell.io, .fromMilliseconds(50), .awake) catch {};
    _ = mailbox.push(42);
    ctx.waker.post();
    shell.wake();
}

test "wake: a worker thread wakes the sleeping shell and its result reaches the next frame" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var slots: [4]u32 = undefined;
    var mailbox: scheduler.Mailbox(u32) = .init(&slots);
    var app: WithJob = .{ .mailbox = &mailbox };
    var shell = Fixture.shell(@embedFile("testdata/example.replay"));
    iface.run(&shell, &ctx, &app);
    try testing.expectEqual(@as(u32, 13), app.app.builds);
    // Idle: nothing to do until something wakes the UI.
    var ev: Events = .{};
    try testing.expect(!shell.poll(&ev));

    const worker = try std.Thread.spawn(.{}, job, .{ &mailbox, &ctx, &shell });
    shell.linger = 10; // a missed wake fails the test after 10 s instead of hanging it
    const t0 = std.Io.Timestamp.now(shell.io, .awake);
    shell.wait(types.inf, .idle);
    const slept = t0.durationTo(std.Io.Timestamp.now(shell.io, .awake)).toNanoseconds();
    worker.join();
    try testing.expect(slept < 5 * std.time.ns_per_s);

    // The woken frame: same input, needed because of the posted wake, carrying the result.
    try testing.expect(shell.poll(&ev));
    try testing.expectEqual(@as(u32, 1), shell.wakes);
    try testing.expectEqual([2]f32{ 400, 400 }, ev.in.pointer);
    try testing.expect(ctx.needsFrame(&ev.in));
    var f = ctx.begin(&ev.in);
    app.build(&f, &ev);
    _ = f.end(.{});
    try testing.expectEqual(@as(u32, 42), app.result);
    try testing.expectEqual(@as(u32, 14), app.app.builds);
    // One wake, one frame.
    try testing.expect(!shell.poll(&ev));
}

test "headless: a bad recording stops the shell and says where" {
    var shell = Fixture.shell("frame\nviewport 800\n");
    var ev: Events = .{};
    try testing.expect(!shell.poll(&ev));
    try testing.expectEqual(error.Syntax, shell.err.?);
    try testing.expectEqual(@as(u32, 2), shell.replay.line);
}
