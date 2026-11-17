//! The examples of docs/guide/porting.md, compiled and run by `zig build docs`. Every ```zig
//! block of the guide is a verbatim piece of this file (docs/guide/snippets.py checks that).

const std = @import("std");
const testing = std.testing;
const lcgf = @import("lcgf");
const shell = lcgf.shell_iface;
const sw = lcgf.render_sw;
const Context = lcgf.context.Context;

/// The pretend platform: what its event queue delivers. A real one is a window system's
/// messages (WM_*, xcb events, Wayland events, DOM events, a touch controller's registers).
const Native = union(enum) {
    resize: [2]u32,
    motion: [2]f32,
    press,
    release,
    /// End of one batch of events: what one `poll` drains.
    sync,
    close,
};

// -- shell
const ToyShell = struct {
    queue: []const Native,
    at: usize = 0,
    fb: sw.Framebuffer,
    gfx: sw.Software = .{},
    /// Room for one frame's glyph quads, and where each text run's start (Mono.quads).
    glyphs: []lcgf.draw_list.Quad,
    first: []u32,
    count: []u32,
    cursor: lcgf.context.Cursor = .arrow,
    presents: u32 = 0,

    /// Drains pending events without blocking. Held state (pointer, buttons, viewport) stays
    /// in `ev.in` from poll to poll; per-frame state would be cleared here.
    pub fn poll(s: *ToyShell, ev: *shell.Events) bool {
        while (s.at < s.queue.len) {
            const e = s.queue[s.at];
            s.at += 1;
            switch (e) {
                .resize => |size| ev.in.viewport = .{ @floatFromInt(size[0]), @floatFromInt(size[1]) },
                .motion => |p| ev.in.pointer = p,
                .press => ev.in.buttons.left = true,
                .release => ev.in.buttons.left = false,
                .sync => return true,
                .close => return false,
            }
        }
        return false;
    }

    /// The effects a frame asks for: here only the cursor shape.
    pub fn apply(s: *ToyShell, p: *const lcgf.context.Platform) void {
        s.cursor = p.cursor;
    }

    /// Draws the frame with the software back end: text as `Mono` glyph quads on the white
    /// texture (solid cells; a real shell rasterises glyphs, docs/guide/text.md). Custom
    /// commands are skipped: they are the host's.
    pub fn present(s: *ToyShell, out: *const lcgf.context.Output) void {
        s.presents += 1;
        const n = (lcgf.protocol.Mono{}).quads(out.draw, s.glyphs, .{ .first = s.first, .count = s.count });
        s.gfx.prepare({}, out.draw, .{ .quads = s.glyphs[0..n], .first = s.first, .count = s.count }, .{ 0, 0 }, 1);
        s.fb.clear(.rgb(0, 0, 0));
        lcgf.render_iface.render(&s.gfx, .{ .fb = &s.fb, .scissor = s.fb.all() }, out.draw);
    }

    /// Blocks until the next event or `seconds`; the queue is always ready, so it returns.
    pub fn wait(_: *ToyShell, seconds: f32, pace: lcgf.scheduler.Pace) void {
        _ = seconds;
        _ = pace;
    }

    /// Thread-safe in a real shell: makes a `wait` return and the next `poll` give a frame.
    pub fn wake(_: *ToyShell) void {}
};

comptime {
    shell.check(ToyShell);
}
// -- end

const limits: lcgf.context.Limits = .{ .nodes = 1024, .texts = 256 };
var ctx_buffer: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
var pixels: [sw.Framebuffer.len(320, 240)]u32 = undefined;
var glyphs: [512]lcgf.draw_list.Quad = undefined;
var first: [limits.texts]u32 = undefined;
var count: [limits.texts]u32 = undefined;

test "a new shell runs the shells' example application" {
    // A press and release over Reset (8,8 .. 66,42 in the example's layout), then the window closes.
    const queue = [_]Native{
        .{ .resize = .{ 320, 240 } }, .sync,
        .{ .motion = .{ 37, 25 } },   .sync,
        .press,                       .sync,
        .release,                     .sync,
        .close,
    };
    // -- run
    var ctx = try Context.init(&ctx_buffer, limits);
    var app: lcgf.shell_example.App = .{};
    var toy: ToyShell = .{ .queue = &queue, .fb = .init(&pixels, 320, 240, .rgba8), .glyphs = &glyphs, .first = &first, .count = &count };
    shell.run(&toy, &ctx, &app); // poll, build when needed, apply, present, wait; until poll is false
    // -- end
    try testing.expectEqual(1, app.resets);
    try testing.expectEqual(lcgf.context.Cursor.pointer, toy.cursor);
    try testing.expectEqual(4, toy.presents);
    // The toolbar's panel colour reached the framebuffer.
    try testing.expectEqual(app.theme.panel, toy.fb.at(300, 4));
}
