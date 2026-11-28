//! replay: an application's test without a window. A recording (src/core/input.zig `Replay`)
//! drives the `App` an example gives `lcgf_app.run`, through the headless shell
//! (src/shell/headless.zig): each frame the context asks for is built, then drawn by the
//! software back end into an 800 x 600 framebuffer the test reads. The shell draws text as
//! solid cells of its colour, the canvas as it is, and an App's `images` (`lcgf_app.Image`) as
//! the window does: `Style.texture` k + 1 is image k. A `Surface` is never live here.
//!
//! The root of the `lcgf_replay` module (build.zig), for the examples' `zig build test`.
//!
//! Contents
//!   pub const width, height
//!   pub const limits: context.Limits
//!   pub const Run = struct
//!     pub fn rect(r: *const Run, id: Id) Rect
//!     pub fn at(r: *const Run, x: u32, y: u32) Color
//!   pub fn run(app: anytype, recording: []const u8) !Run
//!   pub fn clicks(buf: []u8, points: []const [2]f32) ![]const u8
//!   pub fn center(r: Rect) [2]f32

const std = @import("std");
const lcgf = @import("lcgf");
const context = lcgf.context;
const sw = lcgf.render_sw;
const Headless = lcgf.shell_headless.Headless;
const Events = lcgf.shell_iface.Events;
const Input = lcgf.input.Input;
const Quad = lcgf.draw_list.Quad;
const types = lcgf.types;

pub const width = 800;
pub const height = 600;
/// What every run's context is made with: `lcgf_app.Options.limits`' default.
pub const limits: context.Limits = .{ .nodes = 1024, .texts = 256 };

/// One played recording.
pub const Run = struct {
    shell: Headless,
    /// Frames built (and drawn), and the last one.
    builds: u32 = 0,
    out: ?context.Output = null,

    /// Where node `id` was laid out in the last frame built.
    pub fn rect(r: *const Run, id: types.Id) types.Rect {
        const t = r.out.?.tree;
        return t.rect(t.find(id));
    }

    /// Pixel (x, y) of the last frame drawn.
    pub fn at(r: *const Run, x: u32, y: u32) types.Color {
        return r.shell.fb.at(x, y);
    }
};

/// Static, as the window's are: the framebuffer alone is 1.9 MB.
const buffers = struct {
    var ctx: [context.Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
    var canvas: [2 * limits.customs]lcgf.draw_list.CanvasDraw = undefined;
    var pixels: [sw.Framebuffer.len(width, height)]u32 = undefined;
    var glyphs: [4096]Quad = undefined;
    var first: [limits.texts]u32 = undefined;
    var count: [limits.texts]u32 = undefined;
    var text: [64]u8 = undefined;
    var events: [16]Input.Event = undefined;
    var contacts: [4]Input.Contact = undefined;
    var images: [65]sw.Image = undefined;
};

/// Plays `recording` into `app` (a fresh one: its state is the test's). Fails on a bad
/// recording or a frame past `limits`.
// tidy: allow-fn(large-generic-function) a test helper, one instance per example App
pub fn run(app: anytype, recording: []const u8) !Run {
    const App = @TypeOf(app.*);
    std.debug.assert(recording.len != 0); // nothing to play: no frame, no `out`
    var ctx = try context.Context.init(&buffers.ctx, limits);
    ctx.enableCanvas(&buffers.canvas);
    const input: lcgf.input.Replay.Buffers = .{
        .text = &buffers.text,
        .events = &buffers.events,
        .contacts = &buffers.contacts,
    };
    var r: Run = .{ .shell = .init(std.testing.io, recording, width, height, .{
        .replay = input,
        .pixels = &buffers.pixels,
        .glyphs = &buffers.glyphs,
        .first = &buffers.first,
        .count = &buffers.count,
    }) };
    var ev: Events = .{};
    while (r.shell.poll(&ev)) {
        if (!ctx.needsFrame(&ev.in)) continue;
        var f = ctx.begin(&ev.in);
        app.build(&f, &ev);
        const out = f.end(.{});
        if (!out.status.ok()) return error.FrameDidNotFit;
        if (comptime @hasDecl(App, "images")) r.shell.gfx.images = textures(app.images());
        r.shell.apply(&out.platform);
        r.shell.present(&out);
        r.builds += 1;
        r.out = out;
    }
    if (r.shell.err) |e| return e;
    return r;
}

/// A recording that clicks each point in turn at 800 x 600: move, press, release, one frame
/// each, after a first frame that only lays out, and one settle frame at the end.
pub fn clicks(buf: []u8, points: []const [2]f32) ![]const u8 {
    var wr = std.Io.Writer.fixed(buf);
    try wr.writeAll("frame\nviewport 800 600\n");
    const click = "frame\npointer {d} {d}\nframe\nbuttons left\nframe\nbuttons\n";
    for (points) |p| try wr.print(click, .{ p[0], p[1] });
    try wr.writeAll("frame\n");
    return wr.buffered();
}

/// The centre of `r`, to click it.
pub fn center(r: types.Rect) [2]f32 {
    return .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
}

// ---- private ----

/// The software back end's textures for an App's images (`lcgf_app.Image`): white, then each.
fn textures(images: anytype) []const sw.Image {
    std.debug.assert(images.len < buffers.images.len);
    buffers.images[0] = sw.Image.white;
    for (images, buffers.images[1..][0..images.len]) |img, *t| {
        const size: [2]u32 = img.size;
        t.* = .{ .pixels = img.pixels, .alpha8 = img.alpha, .width = size[0], .height = size[1] };
    }
    return buffers.images[0 .. images.len + 1];
}
