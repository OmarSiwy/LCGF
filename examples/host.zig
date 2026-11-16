//! What every example's host does, shared by the window runner (window.zig) and the smoke
//! tests: draw a frame in software, letting the application draw under the UI and into its
//! custom rects (src/shell/iface.zig, "embedding": a host that renders itself skips `present`).
//!
//! An application is a type with `pub fn build(*App, *Frame, *const Events) void` (the shells'
//! contract), and optionally
//!
//!   pub fn under(*App, *sw.Framebuffer) void                      drawn before the UI
//!   pub fn drawCustom(*App, *sw.Framebuffer, *const CustomDraw) void   at each custom command
//!   pub const images: fn (*App) []const sw.Image                  textures 0.. for the UI
//!
//! This file is the root of the `host` module (build.zig), shared by every example.

const std = @import("std");
const lcgr = @import("lcgr");
const context = lcgr.context;
const sw = lcgr.render_sw;
const render = lcgr.render_iface;
const Quad = lcgr.draw_list.Quad;
const Replay = lcgr.input.Replay;
const Input = lcgr.input.Input;
const Color = lcgr.types.Color;
const Mono = lcgr.protocol.Mono;
pub const Events = lcgr.shell_iface.Events;
pub const CustomDraw = lcgr.draw_list.CustomDraw;

/// Caller-owned rows for the glyph quads of one frame.
pub const Glyphs = struct { quads: []Quad, first: []u32, count: []u32 };

/// Draws `out` into `fb`: clear, the application's `under`, then the UI, stopping at each custom
/// command for the application's `drawCustom`.
pub fn draw(app: anytype, gfx: *sw.Software, fb: *sw.Framebuffer, g: Glyphs, out: *const context.Output, scale: f32, background: Color) void {
    const App = @TypeOf(app.*);
    const font: Mono = .{};
    const n = font.quads(out.draw, g.quads, .{ .first = g.first, .count = g.count });
    if (@hasDecl(App, "images")) gfx.images = app.images();
    gfx.prepare({}, out.draw, .{ .quads = g.quads[0..n], .first = g.first, .count = g.count }, .{ 0, 0 }, scale);
    fb.clear(background);
    if (@hasDecl(App, "under")) app.under(fb);
    const pass: sw.Target = .{ .fb = fb, .scissor = fb.all() };
    var i = render.drawUntilCustom(gfx, pass, out.draw, 0);
    while (i < out.draw.cmd_len) : (i = render.drawUntilCustom(gfx, pass, out.draw, i + 1)) {
        if (@hasDecl(App, "drawCustom")) app.drawCustom(fb, &out.draw.customs[out.draw.command(i).custom]);
    }
}

/// Pixel box of a logical rect at `scale`, clamped at 0.
pub fn box(r: [4]f32, scale: f32) [4]u32 {
    var b: [4]u32 = undefined;
    for (&b, r) |*o, v| o.* = @intFromFloat(@max(v * scale, 0));
    return b;
}

pub const smoke_w = 800;
pub const smoke_h = 600;
pub const smoke_limits: context.Limits = .{ .nodes = 1024, .texts = 256 };

/// A smoke run: an application driven by a recording at 800 x 600, every built frame drawn.
pub const Smoke = struct {
    var ctx_buffer: [context.Context.requiredBytes(smoke_limits)]u8 align(lcgr.mem.column_align) = undefined;
    var pixels: [sw.Framebuffer.len(smoke_w, smoke_h)]u32 = undefined;
    var quads: [4096]Quad = undefined;
    var first: [smoke_limits.texts]u32 = undefined;
    var count: [smoke_limits.texts]u32 = undefined;
    var text: [64]u8 = undefined;
    var events: [16]Input.Event = undefined;
    var contacts: [4]Input.Contact = undefined;

    ctx: context.Context,
    fb: sw.Framebuffer,
    gfx: sw.Software = .{},
    /// Recorded frames, frames built (drawn), and the last built frame.
    frames: u32 = 0,
    builds: u32 = 0,
    out: ?context.Output = null,

    /// Plays `recording` (src/core/input.zig `Replay`) into `app`. Fails on a bad recording or
    /// a frame that did not fit its limits.
    pub fn run(app: anytype, recording: []const u8) !Smoke {
        var s: Smoke = .{ .ctx = try .init(&ctx_buffer, smoke_limits), .fb = .init(&pixels, smoke_w, smoke_h, .rgba8) };
        var replay: Replay = .{ .src = recording };
        var ev: Events = .{};
        while (try replay.next(.{ .text = &text, .events = &events, .contacts = &contacts })) |in| {
            s.frames += 1;
            ev.in = in.*;
            if (!s.ctx.needsFrame(&ev.in)) continue;
            var f = s.ctx.begin(&ev.in);
            app.build(&f, &ev);
            const out = f.end(.{});
            if (!out.status.ok()) return error.FrameDidNotFit;
            s.builds += 1;
            draw(app, &s.gfx, &s.fb, .{ .quads = &quads, .first = &first, .count = &count }, &out, ev.in.scale, .rgb(0, 0, 0));
            s.out = out;
        }
        return s;
    }

    /// Where the node `id` was laid out in the last built frame.
    pub fn rect(s: *const Smoke, id: lcgr.types.Id) lcgr.types.Rect {
        const t = s.out.?.tree;
        return t.rect(t.find(id));
    }

    /// Pixel (x, y) of the last drawn frame.
    pub fn at(s: *const Smoke, x: u32, y: u32) Color {
        return s.fb.at(x, y);
    }
};

/// A recording that clicks each point in turn at 800 x 600: move, press, release, one frame
/// each, after a first frame that only lays out, and one settle frame at the end.
pub fn clicks(buf: []u8, points: []const [2]f32) ![]const u8 {
    var wr = std.Io.Writer.fixed(buf);
    try wr.writeAll("frame\nviewport 800 600\n");
    for (points) |p| try wr.print("frame\npointer {d} {d}\nframe\nbuttons left\nframe\nbuttons\n", .{ p[0], p[1] });
    try wr.writeAll("frame\n");
    return wr.buffered();
}

/// The centre of a rect, to click it.
pub fn center(r: lcgr.types.Rect) [2]f32 {
    return .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
}
