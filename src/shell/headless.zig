//! The headless shell: a shell with no window, for tests. Its events come from an `input.Replay`
//! recording, one frame per `poll`, and `present` draws each frame with the software back end
//! (src/render/sw/) into a framebuffer the test reads. Everything it uses is carved from the
//! buffers the caller passes to `init`; it allocates nothing.
//!
//! Text runs are drawn as glyph quads from `protocol.Mono.quads` sampling texture 0 (white), so
//! every glyph is a solid cell of the run's colour: enough to see where text landed, not what it
//! says. Custom commands are skipped, as `iface.render` does: the host draws those.

const std = @import("std");
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
const Color = types.Color;

pub const Headless = struct {
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
    pub fn init(recording: []const u8, width: u32, height: u32, buf: Buffers) Headless {
        return .{
            .replay = .{ .src = recording },
            .replay_buffers = buf.replay,
            .fb = .init(buf.pixels, width, height, .rgba8),
            .glyphs = .{ .quads = buf.glyphs, .first = buf.first, .count = buf.count },
        };
    }

    /// The next recorded frame; false after the last one or on a bad recording (`err`).
    pub fn poll(h: *Headless, ev: *Events) bool {
        const next = h.replay.next(h.replay_buffers) catch |e| {
            h.err = e;
            return false;
        };
        const in = next orelse return false;
        h.polls += 1;
        ev.in = in.*;
        h.scale = in.scale;
        return true;
    }

    pub fn apply(h: *Headless, p: *const Platform) void {
        h.applied = p.*;
    }

    /// Draws the frame into `fb`: clear, then every command but the custom ones.
    pub fn present(h: *Headless, out: *const Output) void {
        h.presents += 1;
        const g = h.glyphs;
        const n = h.font.quads(out.draw, g.quads, .{ .first = g.first, .count = g.count });
        h.gfx.prepare({}, out.draw, .{ .quads = g.quads[0..n], .first = g.first, .count = g.count }, .{ 0, 0 }, h.scale);
        h.fb.clear(h.background);
        render.render(&h.gfx, .{ .fb = &h.fb, .scissor = h.fb.all() }, out.draw);
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
        return .init(recording, fb_w, fb_h, .{
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

test "headless: a bad recording stops the shell and says where" {
    var shell = Fixture.shell("frame\nviewport 800\n");
    var ev: Events = .{};
    try testing.expect(!shell.poll(&ev));
    try testing.expectEqual(error.Syntax, shell.err.?);
    try testing.expectEqual(@as(u32, 2), shell.replay.line);
}
