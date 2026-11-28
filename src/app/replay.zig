//! replay: an `lcgf_app` App tested without a window. A recording (src/core/input.zig
//! `Replay`) drives the App through the frame path `lcgf_app.run` takes on a software window,
//! the same code (app.zig `loop`): `build`, or `page`, `build` and `compose` for an App that
//! composes a page of its own (src/app/page.zig, with `trackDamageWhole` and its region input);
//! `App.images`; canvases, `lcgf_app.Canvas` included; canvas labels for an App with a
//! `labels` field when the replay has font files. Each frame is drawn by the software back end
//! (`sw.Setup`, real canvas drawing) into a framebuffer of `Options.size` logical pixels at
//! `Options.scale`, which keeps the last frame's pixels as a window does. Text is the bundled
//! bitmap font, or the text service over `Options.fonts` (no system faces: a replay draws the
//! same on every machine). A `Surface` is never live here.
//!
//! In: the App, the recording, `Options`. Out: `Run`, the last frame's tree, output and list
//! (for a composing App the composed list, and where its region's corner is) and the pixels,
//! all in the window's coordinates, as the recording's. `draw` paints a list a test composed
//! itself, for pixel parity. Static buffers, one set per `Options`, and `std.testing`'s
//! allocator and io: for tests, and not re-entrant.
//!
//! Contents
//!   pub const width, height
//!   pub const Options = struct
//!   pub const Run = struct
//!     pub fn rect(r: *const Run, id: Id) Rect
//!     pub fn at(r: *const Run, x: u32, y: u32) Color
//!     pub fn list(r: *const Run) *const DrawList
//!   pub fn run(app: anytype, recording: []const u8) !Run
//!   pub fn runWith(app: anytype, recording: []const u8, comptime o: Options) !Run
//!   pub fn draw(fb: *Framebuffer, list: *const DrawList, images: []const Image, scale: f32,
//!       background: Color) void
//!   pub fn clicks(buf: []u8, points: []const [2]f32) ![]const u8
//!   pub fn center(r: Rect) [2]f32

const std = @import("std");
const lcgf = @import("lcgf");
const app_mod = @import("app.zig");
const text = @import("text.zig");
const lcgf_page = @import("page.zig");
const context = lcgf.context;
const sw = lcgf.render_sw;
const font = lcgf.render_sw_font;
const types = lcgf.types;
const Events = lcgf.shell_iface.Events;
const Input = lcgf.input.Input;
const Quad = lcgf.draw_list.Quad;
const DrawList = lcgf.draw_list.DrawList;
const Image = app_mod.Image;

/// The default size, logical pixels: what `clicks` sets the viewport to.
pub const width = 800;
pub const height = 600;

pub const Options = struct {
    /// The viewport before the recording sets one, logical pixels; the framebuffer is this
    /// times `scale` (the recording may make the viewport smaller, not larger).
    size: [2]u32 = .{ width, height },
    /// Physical pixels per logical one, before the recording sets one.
    scale: f32 = 1,
    /// The context's capacities, as `lcgf_app.Options.limits`.
    limits: context.Limits = .{ .nodes = 1024, .texts = 256 },
    /// Font files for the text service; none draws with the bundled bitmap font.
    fonts: []const text.File = &.{},
    text: text.Options = .{ .quads = 4096 },
    labels: text.labels.Options = .{},
};

/// One played recording.
pub const Run = struct {
    fb: sw.Framebuffer,
    /// Frames the recording had, and frames built (and drawn).
    frames: u32 = 0,
    builds: u32 = 0,
    /// The last frame built, as the window was given it: its `draw` the list drawn (for a
    /// composing App the composed one), its tree the frame's.
    out: ?context.Output = null,
    /// What the window cleared to: the theme's panel for an App with a `theme`.
    background: types.Color = .rgb(0, 0, 0),
    /// Where the frame's (0, 0) is in the window, logical pixels: the corner of a composing
    /// App's region (`page`), else (0, 0). `out.tree` is in the frame's coordinates.
    origin: [2]f32 = .{ 0, 0 },

    /// Where node `id` of the last frame built is in the window, logical pixels: the
    /// coordinates of `at` (divided by the scale) and of the recording, so a click at
    /// `center(rect(id))` hits the node.
    pub fn rect(r: *const Run, id: types.Id) types.Rect {
        const t = r.out.?.tree;
        const n = t.rect(t.find(id));
        const o = r.origin;
        return .{ .x0 = n.x0 + o[0], .y0 = n.y0 + o[1], .x1 = n.x1 + o[0], .y1 = n.y1 + o[1] };
    }

    /// Pixel (x, y) of the framebuffer, physical pixels.
    pub fn at(r: *const Run, x: u32, y: u32) types.Color {
        return r.fb.at(x, y);
    }

    /// The list the last frame drew: the frame's, or the one a composing App composed.
    pub fn list(r: *const Run) *const DrawList {
        return r.out.?.draw;
    }
};

/// The headless window `loop` runs: its events from the recording, a frame each `poll`, its
/// frames drawn into `fb`, which keeps the last one's pixels.
const Shell = struct {
    replay: lcgf.input.Replay,
    input: lcgf.input.Replay.Buffers,
    fb: sw.Framebuffer,
    gfx: sw.Setup = .{},
    /// What the window clears to; `loop` sets it to the theme's panel for an App with one.
    background: types.Color = .rgb(0, 0, 0),
    /// Where the frame's (0, 0) is; `loop` sets it for a composing App.
    origin: [2]f32 = .{ 0, 0 },
    scale: f32 = 1,
    frames: u32 = 0,
    builds: u32 = 0,
    last: ?context.Output = null,
    err: ?lcgf.input.Replay.Error = null,
    overflow: bool = false,

    pub fn poll(s: *Shell, ev: *Events) bool {
        const next = s.replay.next(s.input) catch |e| {
            s.err = e;
            return false;
        };
        const in = next orelse return false;
        ev.* = .{ .in = in.* };
        s.frames += 1;
        s.scale = in.scale;
        return true;
    }

    pub fn apply(_: *Shell, _: *const context.Platform) void {}

    pub fn presentWith(
        s: *Shell,
        out: *const context.Output,
        glyphs: lcgf.render_iface.Glyphs,
        images: []const sw.Image,
    ) void {
        std.debug.assert(images.len > @backingInt(glyphs.texture));
        s.overflow = s.overflow or !out.status.ok();
        s.gfx.gfx.images = images;
        s.gfx.draw(&s.fb, out.draw, glyphs, s.background, s.scale);
        s.builds += 1;
        s.last = out.*;
    }

    pub fn wait(_: *Shell, _: f32, _: lcgf.scheduler.Pace) void {}
};

/// `draw`'s buffers: the textures and the glyph rows of one list.
const drawn = struct {
    var rows: [app_mod.images_max + 2]sw.Image = undefined;
    var glyphs: [4096]Quad = undefined;
    var first: [1024]u32 = undefined;
    var count: [1024]u32 = undefined;
};

/// `runWith` at the default options: 800 x 600 at scale 1, the bundled font.
pub fn run(app: anytype, recording: []const u8) !Run {
    return runWith(app, recording, .{});
}

/// Plays `recording` into `app` (a fresh one: its state is the test's). Fails on a bad
/// recording or a frame past `o.limits`.
// tidy: allow-fn(large-generic-function) a test harness, one instance per App and options
pub fn runWith(app: anytype, recording: []const u8, comptime o: Options) !Run {
    const App = @TypeOf(app.*);
    const B = Buffers(o);
    std.debug.assert(recording.len != 0); // nothing to play: no frame, no `out`
    var ctx = try context.Context.init(&B.ctx, app_mod.limitsOf(B.ao));
    // The window's choices (`run`): a composed list, or one showing images, is kept whole.
    const whole = comptime lcgf_page.composes(App) or @hasDecl(App, "images");
    if (whole) ctx.trackDamageWhole() else ctx.trackDamage();
    const serves = o.fonts.len > 0;
    const TextWindow = text.WindowOf(serves);
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tw = try TextWindow.open(&B.service, app_mod.textOptions(B.ao), o.fonts, false, gpa, io);
    defer tw.close();
    ctx.enableCanvas(&B.canvas_rows);
    if (serves) app_mod.openKept(&ctx, B.ao, &tw);
    if (serves) app_mod.openLabels(App, app, B.ao, &tw);
    const viewport: [2]f32 = .{ @floatFromInt(o.size[0]), @floatFromInt(o.size[1]) };
    var shell: Shell = .{
        .replay = .{ .src = recording, .in = .{ .viewport = viewport, .scale = o.scale } },
        .input = .{ .text = &B.typed, .events = &B.events, .contacts = &B.contacts },
        .fb = .init(&B.pixels, B.physical[0], B.physical[1], .rgba8),
    };
    const t0 = std.Io.Timestamp.now(io, .awake);
    const clock: app_mod.Clock = .{ .io = io, .t0 = t0, .seconds = types.inf };
    const glyphs: app_mod.Glyphs = .{ .quads = &B.glyphs, .first = &B.first, .count = &B.count };
    try app_mod.loop(App, app, &shell, &ctx, clock, glyphs, &tw);
    if (shell.err) |e| return e;
    if (shell.overflow) return error.FrameDidNotFit;
    return .{
        .fb = shell.fb,
        .frames = shell.frames,
        .builds = shell.builds,
        .out = shell.last,
        .background = shell.background,
        .origin = shell.origin,
    };
}

/// Draws all of `list` into `fb` as a replay draws a frame: `images` as the App's (texture
/// k + 1 is image k), the text in the bundled bitmap font, over `background`. For a test that
/// composed a list itself and compares it with a replay's pixels.
pub fn draw(
    fb: *sw.Framebuffer,
    list: *const DrawList,
    images: []const Image,
    scale: f32,
    background: types.Color,
) void {
    std.debug.assert(images.len < drawn.rows.len - 1);
    drawn.rows[0] = .white;
    for (images, drawn.rows[1..][0..images.len]) |img, *row| {
        const size: [2]u32 = img.size;
        row.* = .{ .pixels = img.pixels, .alpha8 = img.alpha, .width = size[0], .height = size[1] };
    }
    drawn.rows[images.len + 1] = font.image;
    var g = font.glyphs(list, &drawn.glyphs, &drawn.first, &drawn.count);
    g.texture = @fromBackingInt(@as(u16, @intCast(images.len + 1)));
    var gfx: sw.Software = .{ .images = drawn.rows[0 .. images.len + 2] };
    gfx.prepare({}, list, g, .{ 0, 0 }, scale);
    gfx.frame(.{ .fb = fb, .scissor = fb.all() }, list, background);
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

/// The static buffers of a replay at `o`, and `o` as `lcgf_app.Options`.
fn Buffers(comptime o: Options) type {
    return struct {
        const ao: app_mod.Options = .{
            .size = o.size,
            .limits = o.limits,
            .fonts = o.fonts,
            .text = o.text,
            .labels = o.labels,
        };
        const physical = .{ physicalOf(o.size[0], o.scale), physicalOf(o.size[1], o.scale) };
        const ctx_bytes = context.Context.requiredBytes(app_mod.limitsOf(ao));
        const service_bytes = if (o.fonts.len > 0)
            text.Text.requiredBytes(app_mod.textOptions(ao))
        else
            0;
        var ctx: [ctx_bytes]u8 align(lcgf.mem.column_align) = undefined;
        var canvas_rows: [2 * o.limits.customs]lcgf.draw_list.CanvasDraw = undefined;
        var service: [service_bytes]u8 align(lcgf.mem.column_align) = undefined;
        var pixels: [sw.Framebuffer.len(physical[0], physical[1])]u32 = undefined;
        var glyphs: [4096]Quad = undefined;
        var first: [o.limits.texts]u32 = undefined;
        var count: [o.limits.texts]u32 = undefined;
        var typed: [256]u8 = undefined;
        var events: [64]Input.Event = undefined;
        var contacts: [8]Input.Contact = undefined;
    };
}

fn physicalOf(logical: u32, scale: f32) u32 {
    return @intFromFloat(@ceil(@as(f32, @floatFromInt(logical)) * scale));
}

const testing = std.testing;
const T = lcgf_page.TestApp;
const font_files = [_]text.File{.{ .bytes = @embedFile("layout.ttf") }};
const page_size: Options = .{ .size = .{ 300, 200 } };

test "replay: a composed page through a click, both sides drawn, the list composed" {
    var app: T = .{};
    var s = try runWith(&app, "frame\n", page_size);
    // The page's header, its tinted icon, the region's ground and the frame's canvas.
    const c = app.canvas_rect;
    try testing.expectEqual(T.page_fill, s.at(200, 4));
    try testing.expectEqual(T.tint, s.at(258, 16));
    try testing.expectEqual(T.region_fill, s.at(290, 190));
    try testing.expectEqual(T.red, s.at(@intFromFloat(c[0] + 15), @intFromFloat(c[1] + 15)));
    const ground = s.at(@intFromFloat(c[0] + 50), @intFromFloat(c[1] + 40));
    try testing.expectEqual(T.canvas_fill, ground);
    // The list drawn is the one the App composed: the page's runs, then the frame's.
    try testing.expectEqual(@as(*const DrawList, &app.list), s.list());
    try testing.expect(s.list().run_len > app.top.run_len);
    // Rects are in the window's coordinates: the plot is where the window shows it, below the
    // page's header, where the region starts.
    const plot = s.rect(.from("plot"));
    try testing.expectEqual(c, [4]f32{ plot.x0, plot.y0, plot.x1, plot.y1 });
    try testing.expect(s.origin[1] > 0);

    // A click on the compiled checkbox reaches the page.
    try testing.expect(app.ui.signals.state.grid);
    const box = app.widgetRect();
    var rec: [256]u8 = undefined;
    const p = center(.{ .x0 = box[0], .y0 = box[1], .x1 = box[2], .y1 = box[3] });
    const click = "frame\npointer {d} {d}\nframe\nbuttons left\nframe\nbuttons\nframe\n";
    app = .{};
    s = try runWith(&app, try std.fmt.bufPrint(&rec, click, .{ p[0], p[1] }), page_size);
    try testing.expect(!app.ui.signals.state.grid);
    try testing.expectEqual(@as(u32, 4), s.frames);
}

test "replay: a canvas label in the text service's font matches the software back end's" {
    var app: T = .{};
    const s = try runWith(&app, "frame\n", .{ .size = .{ 300, 200 }, .fonts = &font_files });
    try testing.expect(app.labelled);
    // The reference: the canvas node's rows, square and label, drawn alone from the same atlas.
    const Ref = struct {
        var px: [sw.Framebuffer.len(200, 60)]u32 = undefined;
    };
    var fb = sw.Framebuffer.init(&Ref.px, 200, 60, .rgba8);
    const look: text.labels.CanvasLook = .{ .ground = T.canvas_fill, .palette = &app.view.palette };
    text.labels.drawCanvas(&fb, &app.shapes, app.view.camera, &app.labels.labels.?.atlas, look);
    const c = app.canvas_rect;
    const corner: [2]u32 = .{ @intFromFloat(c[0]), @intFromFloat(c[1]) };
    var bad: u32 = 0;
    var lit: u32 = 0;
    for (0..60) |y| for (0..200) |x| {
        const want = fb.at(@intCast(x), @intCast(y));
        const got = s.at(corner[0] + @as(u32, @intCast(x)), corner[1] + @as(u32, @intCast(y)));
        lit += @intFromBool(want.r > 128);
        const off = @abs(@as(i32, got.r) - want.r) > 2 or @abs(@as(i32, got.g) - want.g) > 2;
        bad += @intFromBool(off);
    };
    errdefer std.debug.print("replay canvas: {d} bad pixels, {d} lit\n", .{ bad, lit });
    try testing.expectEqual(0, bad);
    // The square's 100 pixels and the label's.
    try testing.expect(lit > 150);
}

/// A chat input: a text area that wraps, one line tall at first, growing to eight, Enter
/// submitting, in a column 200 px wide.
const Chat = struct {
    const textarea = lcgf.widgets_textarea;
    const th: lcgf.widgets_base.Theme = .default;
    /// In the bundled bitmap font, and in the text service's test face.
    const both = .{
        Options{ .size = .{ 300, 200 } },
        Options{ .size = .{ 300, 200 }, .fonts = &font_files },
    };
    draft: lcgf.widgets_textfield.Text(256) = .{},
    sent: u32 = 0,

    pub fn build(a: *Chat, f: *lcgf.frame.Frame, _: *const Events) void {
        const fill: [2]types.Size = .{ .fill, .fill };
        const panel: types.Style = .{
            .dir = .y,
            .size = fill,
            .pad = @splat(10),
            .fill = th.panel,
        };
        _ = f.open(.none, panel);
        _ = f.open(.none, .{ .dir = .y, .size = .{ .px(200), .fit } });
        const o: textarea.Options = .{ .rows = .{ .min = 1, .max = 8 }, .enter = .submit };
        _ = textarea.textarea(f, &th, .from("chat"), &a.draft, o, "Message");
        a.sent += @intFromBool(a.draft.result.submitted);
        f.close();
        f.close();
    }

    /// The box, its first line's run, its caret, and ink below its first line, after typing
    /// `typed` into it.
    const Typed = struct { box: types.Rect, run: types.Rect, caret: types.Rect, ink: u32 };

    fn typing(typed: []const u8, comptime o: Options) !Typed {
        var app: Chat = .{};
        var rec: [512]u8 = undefined;
        // Focused by a click inside its padding, then typed into.
        const script = "frame\npointer 14 14\nframe\nbuttons left\nframe\nbuttons\nframe\n" ++
            "text {s}\nframe\nframe\n";
        const s = try runWith(&app, try std.fmt.bufPrint(&rec, script, .{typed}), o);
        try testing.expectEqualStrings(typed, app.draft.text());
        const t = s.out.?.tree;
        const a = t.find(.from("chat"));
        const box = s.rect(.from("chat"));
        const first = t.rect(a + 1);
        const caret = t.rect(t.c.end[a] - 1);
        // Text-coloured pixels below the first line, inside the box.
        var ink: u32 = 0;
        const x0: u32 = @intFromFloat(first.x0);
        // The caret is one line tall: the second line starts that far below the first.
        const y1: u32 = @intFromFloat(first.y0 + caret.h());
        var y: u32 = y1;
        while (y < @as(u32, @intFromFloat(box.y1 - 2))) : (y += 1) {
            for (x0..x0 + 150) |x| ink += @intFromBool(s.at(@intCast(x), y).r > 160);
        }
        return .{ .box = box, .run = first, .caret = caret, .ink = ink };
    }
};

test "replay: a text area typed past its right edge wraps, grows a line and shows it" {
    inline for (Chat.both) |o| {
        const short = try Chat.typing("Wave office", o);
        const long = try Chat.typing("Wave office fluff and a few words", o);
        // One line, then two: the run twice as tall, the box one line taller, in one frame.
        try testing.expectApproxEqAbs(2 * short.run.h(), long.run.h(), 1);
        try testing.expectApproxEqAbs(short.box.h() + short.run.h(), long.box.h(), 1);
        // Ink on the second line, none below the first before.
        try testing.expectEqual(@as(u32, 0), short.ink);
        try testing.expect(long.ink > 20);
        // The caret at the end of the text, on the second line.
        try testing.expect(long.caret.y0 >= long.run.y0 + short.run.h() - 1);
        try testing.expect(long.caret.y1 <= long.run.y1 + 1);
    }
}

test "replay: Up, Home, End and Down on a text area's wrapped lines, in Mono and the service" {
    const typed = "Wave office fluff and a few words";
    const Keys = struct {
        /// The caret after typing `typed` and pressing `presses` (HID codes), a frame each.
        fn caret(comptime presses: []const u8, comptime o: Options) !u32 {
            var app: Chat = .{};
            var rec: [512]u8 = undefined;
            const script = "frame\npointer 14 14\nframe\nbuttons left\nframe\nbuttons\nframe\n" ++
                "text {s}\nframe\n";
            var n = (try std.fmt.bufPrint(&rec, script, .{typed})).len;
            inline for (presses) |code| {
                n += (try std.fmt.bufPrint(rec[n..], "press {d}\nframe\n", .{code})).len;
            }
            _ = try runWith(&app, rec[0..n], o);
            return app.draft.ed.caret;
        }
    };
    const up = 82;
    const down = 81;
    const home = 74;
    const end = 77;
    inline for (Chat.both) |o| {
        // Up from the text's end on the second line lands on the first; Home is its start;
        // End its last stop, before where it breaks; Down from there is on the second line.
        const above = try Keys.caret(&.{up}, o);
        const start = try Keys.caret(&.{ up, home }, o);
        const last = try Keys.caret(&.{ up, end }, o);
        const below = try Keys.caret(&.{ up, end, down }, o);
        try testing.expect(above > 0 and above <= last);
        try testing.expectEqual(@as(u32, 0), start);
        try testing.expect(last > 0 and last < typed.len);
        try testing.expect(below > last);
    }
}

test "replay: draw paints a list as the replay drew it" {
    var app: T = .{};
    const s = try runWith(&app, "frame\n", page_size);
    const Ref = struct {
        var px: [sw.Framebuffer.len(300, 200)]u32 = undefined;
    };
    var fb = sw.Framebuffer.init(&Ref.px, 300, 200, .rgba8);
    draw(&fb, s.list(), app.images(), 1, s.background);
    for (0..200) |y| for (0..300) |x| {
        try testing.expectEqual(s.at(@intCast(x), @intCast(y)), fb.at(@intCast(x), @intCast(y)));
    };
}

/// `TestApp` with a button at the top of its region, above the frame `TestApp` builds.
const Pressable = struct {
    inner: T = .{},
    presses: u32 = 0,

    pub fn page(a: *Pressable, in: *const Input, t: lcgf_page.PageText) [4]f32 {
        return a.inner.page(in, t);
    }

    pub fn build(a: *Pressable, f: *lcgf.frame.Frame, ev: *const Events) void {
        const th: lcgf.widgets_base.Theme = .default;
        _ = f.open(.none, .{ .dir = .y, .size = .{ .fill, .fill } });
        if (lcgf.widgets_base.button(f, &th, .from("press"), "Press").clicked) a.presses += 1;
        a.inner.build(f, ev);
        f.close();
    }

    pub fn compose(a: *Pressable, out: *const context.Output) lcgf_page.Composed {
        return a.inner.compose(out);
    }

    pub fn images(a: *Pressable) []const Image {
        return a.inner.images();
    }
};

test "replay: a click at the centre of a region's widget's rect hits it" {
    var app: Pressable = .{};
    const s = try runWith(&app, "frame\n", page_size);
    const r = s.rect(.from("press"));
    // In the window: inside the region, below the page's header.
    try testing.expect(r.y0 >= s.origin[1] and s.origin[1] > 0);
    const p = center(r);
    var rec: [256]u8 = undefined;
    const click = "frame\npointer {d} {d}\nframe\nbuttons left\nframe\nbuttons\nframe\n";
    app = .{};
    _ = try runWith(&app, try std.fmt.bufPrint(&rec, click, .{ p[0], p[1] }), page_size);
    try testing.expectEqual(@as(u32, 1), app.presses);
}
