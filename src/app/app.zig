//! app: an application in a window on the desktop, in one call. It picks the platform's shell,
//! opens a window and runs `shell_iface.run`'s loop, built frame by frame from your `build`,
//! until the window closes. On Windows a Win32 window, on macOS an AppKit one with Metal. On
//! Linux it reads the environment:
//!
//!   - A Vulkan build (the default) opens X11 with Vulkan whenever `DISPLAY` is set and
//!     `LCGF_RENDER` is not `sw`, whatever `WAYLAND_DISPLAY` says. If the X server cannot be
//!     reached or has no Vulkan device, it takes the software path below. With
//!     `LCGF_RENDER=sw`, or `DISPLAY` unset or empty, it takes the software path at once.
//!   - The software path (and every `-Drender=sw` build) opens Wayland when `WAYLAND_DISPLAY`
//!     is set and not empty, and X11 on `DISPLAY` only when it is not, or when the compositor
//!     cannot be reached and `DISPLAY` is set. Neither reachable: `run` returns the error.
//!
//! An application:
//!
//!     const App = struct {
//!         theme: lcgf.widgets_base.Theme = .default,
//!         waves: u32 = 0,
//!         pub fn build(app: *App, f: *lcgf.frame.Frame, _: *const lcgf.shell_iface.Events) void {
//!             const ui = lcgf.widgets.on(f, &app.theme);
//!             if (ui.button(.wave, .{ .label = "Wave" }).clicked) app.waves += 1;
//!             _ = ui.text("Waved {d} times", .{app.waves});
//!         }
//!     };
//!     pub fn main(init: std.process.Init) !void {
//!         var app: App = .{};
//!         try lcgf_app.run(App, &app, init, .{ .title = "Hello" });
//!     }
//!
//! and in build.zig, `lcgf.addApp(b, dep, .{ .name = "hello", .root_source_file = b.path("main.zig") })`,
//! which gives the executable this module (`lcgf_app`) with the shells its target needs. An
//! `App` with a `theme` field of `widgets_base.Theme` follows the system's light or dark
//! appearance where the shell reports it. Text is drawn in the faces of `Options.fonts`, else
//! in the system's default faces where the build can ask the system for them (text.zig
//! `can_discover`: not a Linux build without libc), at the window's scale (src/app/text.zig);
//! else, and on macOS, with the bundled bitmap font (`render_sw.font`, DejaVu Sans Mono under
//! its own licence: ship src/example/font/LICENSE.txt with the program). An `App` with
//! `pub fn images(*App) []const Image` gives the UI its images: `Style.texture` k + 1 is
//! image k. `Frame.canvas` draws a canvas; an App with a field `labels: Labels` gets, before
//! its first `build`, what makes canvas labels in the window's fonts, sharp at any zoom
//! (src/app/labels.zig), and the window draws its canvas glyphs from their atlas:
//!
//!     labels: lcgf_app.Labels = .{},
//!     made: ?u32 = null, // the label atlas's generation the labels were made at
//!     fn makeLabels(app: *App) void { // when the document changes, or `made` is stale
//!         app.shapes.reset(); // or only the label rows
//!         for (app.nets) |n| {
//!             const o: lcgf_app.text.labels.Label = .{ .origin = n.at, .px = 1270 };
//!             _ = app.labels.label(&app.shapes, n.name, o) catch |e| switch (e) {
//!                 // A new atlas: `generation` moved on, the next frame makes all again.
//!                 error.Full => return,
//!                 error.Unavailable => {}, // the bitmap font: `Mono.canvasGlyphs`
//!                 error.NoSpace => {}, // more rows than `shapes` holds
//!             };
//!         }
//!         app.made = app.labels.generation();
//!     }
//!     // in build: if (app.made != app.labels.generation()) app.makeLabels();
//!
//! A pan, a zoom or a new window scale makes no label again. Without the field, or without
//! fonts, nothing is carved and canvas glyphs sample the bundled font's cells. The software
//! shells keep last frame's pixels and redraw only what changed
//! (`Context.trackDamage`). The buffers are static: nothing is allocated but X11's pixels,
//! which follow the window's size.
//! `LCGF_APP_SECONDS` in the environment closes the window after that many seconds (a test on
//! a headless server). The web, Android and iOS start an application their own way: their
//! shells' examples (src/shell/web, android, ios) are the place to start there. Tier 3.

const std = @import("std");
const builtin = @import("builtin");
const lcgf = @import("lcgf");
const context = lcgf.context;
const scheduler = lcgf.scheduler;
const Quad = lcgf.draw_list.Quad;
const sw = lcgf.render_sw;
const font = lcgf.render_sw_font;
const Events = lcgf.shell_iface.Events;
const Event = lcgf.input.Input.Event;
/// The window's text: real fonts at the window's scale (src/app/text.zig).
pub const text = @import("text.zig");
const TextService = text.Text;
/// Canvas labels in the window's fonts, for an App with a field `labels: Labels`, which `run`
/// fills before the first `build` (src/app/labels.zig `Handle`).
pub const Labels = text.labels.Handle;
const render = @import("render_options").render;
/// Whether this build draws the window with a GPU: Vulkan over X11 on Linux (src/app/gpu.zig).
pub const has_gpu = builtin.os.tag == .linux and render == .vk;
const gpu_app = if (has_gpu) @import("gpu.zig") else struct {};
const no_gpu = std.fmt.comptimePrint(
    "lcgf_app: this build (-Drender={t}, {t}) has no GPU path; " ++
        "`gpu` needs -Drender=vk on Linux (a `Surface` here is never live)",
    .{ render, builtin.os.tag },
);
/// `lcgf_render.gpu` on the build's back end: what `App.draw` renders a `Surface` with.
pub const gpu = if (has_gpu) gpu_app.gpu else @compileError(no_gpu);
/// A rectangle of the window the application draws itself (src/app/gpu.zig). A window that
/// is not on the GPU (`Surface.live` false) never calls `App.draw`, and the node paints its
/// style's fill.
pub const Surface = if (has_gpu) gpu_app.Surface else NoSurface;
/// What `App.draw` draws with (src/app/gpu.zig).
pub const GpuFrame = if (has_gpu) gpu_app.GpuFrame else NoGpuFrame;

/// A `Surface` in a build with no GPU path: never live, its node the style as it is.
const NoSurface = struct {
    const types = lcgf.types;
    pub fn node(_: *NoSurface, f: *lcgf.frame.Frame, id: types.Id, style: types.Style) types.Node {
        return f.leaf(id, style);
    }
    pub fn live(_: *const NoSurface) bool {
        return false;
    }
    pub fn redraw(_: *NoSurface) void {}
};

/// What `App.draw` would take in a build with no GPU path, where it is never called.
const NoGpuFrame = opaque {};

/// A canvas (`Frame.canvas`) whose camera and palette the application changes without a
/// `build`: kept in the application's state, as a `Surface` is.
///
///     view: lcgf_app.Canvas = .{ .camera = .{ .scale = 2 } },
///     // in build:
///     _ = app.view.node(f, .from("plot"), style, &app.shapes, .{ .ranges = &app.ranges });
///     // anywhere on the UI thread, then:
///     app.view.camera.origin[0] += 10;
///     app.view.redraw();
///
/// On the GPU window `redraw` draws the canvas node's rectangle again from the rows already
/// on the GPU, with the new camera and palette: no `build`, no UI rows uploaded, only the rows
/// the instances dirtied. On a software window it builds a frame, which carries them. A change
/// to anything else about the node (its ranges, overrides or style) needs a `build`.
pub const Canvas = struct {
    camera: lcgf.canvas.Camera = .{},
    palette: lcgf.canvas.Palette = .none,
    /// `redraw` was called since the camera and palette last went into a frame.
    requested: bool = false,

    /// What `node` passes to `Frame.canvas` besides the camera and palette.
    pub const Draw = struct {
        ranges: []const lcgf.canvas.Range,
        overrides: []const lcgf.canvas.Override = &.{},
    };

    /// The canvas node: `Frame.canvas` with this camera and palette. Panics past
    /// `canvases_max` canvases in a program.
    pub fn node(
        v: *Canvas,
        f: *lcgf.frame.Frame,
        id: lcgf.types.Id,
        style: lcgf.types.Style,
        shapes: *const lcgf.canvas.Instances,
        o: Draw,
    ) lcgf.types.Node {
        canvases.add(v);
        v.requested = false;
        return f.canvas(id, style, shapes, .{
            .camera = v.camera,
            .palette = &v.palette,
            .ranges = o.ranges,
            .overrides = o.overrides,
        });
    }

    /// Asks for a frame that shows the canvas with its camera and palette as they are now:
    /// on the UI thread (in `build`, in `draw` or between frames).
    pub fn redraw(v: *Canvas) void {
        v.requested = true;
        if (has_gpu) if (gpu_app.wake()) return;
        if (canvases.ctx) |ctx| ctx.waker.post();
    }
};

/// Canvases one program redraws (`Canvas.redraw`).
pub const canvases_max = 16;

/// The program's `Canvas`es, and the context a software window's `Canvas.redraw` wakes.
// ponytail: module state, as the buffers are: one window a program.
pub const canvases = struct {
    pub var list: [canvases_max]?*Canvas = @splat(null);
    var ctx: ?*context.Context = null;

    fn add(v: *Canvas) void {
        for (list) |l| if (l == v) return;
        for (&list) |*l| if (l.* == null) {
            l.* = v;
            return;
        };
        @panic("lcgf_app: more than canvases_max canvases");
    }

    /// None registered: a frame is being built (its `node` calls register what it shows), or
    /// the window closed. A canvas not in the last frame built is not drawn again.
    pub fn forget() void {
        list = @splat(null);
    }

    /// Some canvas asked to be drawn again.
    pub fn owed() bool {
        for (list) |l| if (l) |v| if (v.requested) return true;
        return false;
    }
};
const page = @import("page.zig");
/// What `App.page` lays its page out with (src/app/page.zig).
pub const PageText = page.PageText;
/// What `App.compose` returns (src/app/page.zig).
pub const Composed = page.Composed;

/// An application's image, which the UI draws through `Style.texture` (texture k + 1 is image
/// k of `App.images`): `size[0]` by `size[1]` texels, row by row, both sides positive, the
/// application's, read while a frame is drawn. A texel is straight (not premultiplied) RGBA8,
/// `types.Color` bits: red in the low byte. The quad shows texel times its `fill`, channel by
/// channel, so a white fill shows the image as it is and a coloured one tints it.
///
/// An alpha-only image (an icon's coverage) is `alpha`, a byte a texel, read as white with that
/// alpha: under a `fill` it draws in the fill's colour. Written into `pixels` it is the same
/// image as `0x00ffffff | @as(u32, a) << 24` per texel; `alpha` takes a quarter of the bytes.
/// Exactly one of the two is set.
pub const Image = struct {
    pixels: []const u32 = &.{},
    alpha: []const u8 = &.{},
    size: [2]u32,
    /// Changed by the application whenever its pixels change, in a frame it asks for (`build`
    /// changing it, or `ctx.waker`): that frame draws and sends the nodes that show the image
    /// again, from the new pixels (the GPU writes them once), and nothing else. A frame that
    /// changes the number of images or an image's size redraws the whole window.
    generation: u32 = 0,
};

/// Images an application may give (`App.images`).
pub const images_max = 64;

pub const Options = struct {
    title: []const u8 = "LCGF",
    /// The window's content, in logical pixels.
    size: [2]u32 = .{ 800, 600 },
    /// The frame's capacities: `Context` is made with them.
    limits: context.Limits = .{ .nodes = 1024, .texts = 256 },
    /// Font files, font k of a run (`TextStyle.font`) the k-th: `@embedFile` them. None asks
    /// the system for its default faces (font 0 proportional, font 1 monospace).
    fonts: []const text.File = &.{},
    /// The text service's capacities; its `texts` are `limits.texts`.
    text: text.Options = .{ .quads = 4096 },
    /// The canvas label atlas's capacities, carved only for an App with a `labels` field in a
    /// window that draws with the text service.
    labels: text.labels.Options = .{},
    /// Canvas rows and polygon vertices a frame draws on the GPU: the GPU window's instance
    /// buffers hold this many, 32 and 8 bytes each. Past them a canvas draws short. The
    /// software shells draw from `Instances` itself and take any number.
    canvas: struct { rows: u32 = 4096, verts: u32 = 4096 } = .{},
};

/// Opens a window titled `options.title` and runs `app` in it until the window is closed.
/// `App` has `pub fn build(*App, *lcgf.frame.Frame, *const lcgf.shell_iface.Events) void`,
/// and may have `pub fn images(*App) []const Image` (at most `images_max`; the software shells
/// and the GPU draw them, the macOS shell, on Metal, not yet).
///
/// An `App` whose window is a page of its own (a `ComptimeUi`) with the frame in a region of
/// it has both of:
///
///     /// Lays the page out over the window's input; the region the frame is built in.
///     pub fn page(app: *App, in: *const Input, text: lcgf_app.PageText) [4]f32 {
///         const top = if (text) |t| app.ui.frameText(in, t) else app.ui.frame(in);
///         app.ui.recordDamage(&app.dm);
///         app.top = top.draw;
///         return rect4(top.tree.rect(top.tree.find(region_id)));
///     }
///     /// The page's list with the frame's in its region.
///     pub fn compose(app: *App, out: *const lcgf.context.Output) lcgf_app.Composed {
///         ct_interop.compose(&app.list, app.top, out.draw, region, &app.strings) catch
///             unreachable; // the list has room for both, and the page has the region
///         app.texts = .{
///             .{ .tx = &app.ui.tables.tx, .strings = app.top.strings },
///             .{ .tx = out.texts, .strings = out.draw.strings, .first_run = app.top.run_len },
///         };
///         return .{ .draw = &app.list, .texts = &app.texts };
///     }
///
/// The frame is then begun with `ct_interop.regionInput(in, rect)`: the region's size is its
/// viewport and the pointer is moved by the region's corner, so `build` lays out and is hit
/// at (0, 0) as in a window of its own; `Events.in` is that input too. The context records its
/// damage and keeps its list whole (`trackDamageWhole`); the page records its own
/// (`ComptimeUi.recordDamage`), and the window draws, culls and uploads only their union. A
/// frame is built when the context asks or the window's input changed at all. A `Surface` of
/// the frame is placed at its node moved by the region's corner.
pub fn run(comptime App: type, app: *App, init: std.process.Init, comptime options: Options) !void {
    if (!@hasDecl(App, "build")) @compileError(@typeName(App) ++ " needs `pub fn build(*App, *lcgf.frame.Frame, *const lcgf.shell_iface.Events) void`");
    const B = Buffers(options);
    const seconds: f32 = if (init.environ_map.get("LCGF_APP_SECONDS")) |s| std.fmt.parseFloat(f32, s) catch lcgf.types.inf else lcgf.types.inf;
    const clock: Clock = .{ .io = init.io, .t0 = std.Io.Timestamp.now(init.io, .awake), .seconds = seconds };
    var ctx = try context.Context.init(&B.ctx, limitsOf(options));
    // The software shells keep the last frame's pixels; Metal draws every frame whole. A list
    // the application composes, or one that may show an image whose pixels changed, is kept
    // whole and culled once, after the compose or with the images' quads.
    const composing = comptime page.composes(App) or @hasDecl(App, "images");
    if (builtin.os.tag != .macos) {
        if (composing) ctx.trackDamageWhole() else ctx.trackDamage();
    }
    const glyphs: Glyphs = .{ .quads = &B.glyphs, .first = &B.first, .count = &B.count };
    // The macOS shell draws its own text with the bitmap font, on Metal: no service there yet.
    const mac = builtin.os.tag == .macos;
    const fonts: []const text.File = if (mac) &.{} else options.fonts;
    const TextWindow = text.WindowOf(serves(options));
    var tw = try TextWindow.open(&B.service, textOptions(options), fonts, !mac, init.gpa, init.io);
    defer tw.close();
    ctx.enableCanvas(&B.canvas_rows);
    openLabels(App, app, options, &tw);
    const env = if (builtin.os.tag == .linux) envOf(init) else {};
    if (has_gpu) switch (try runGpu(App, app, env, options, clock, &ctx, &tw)) {
        .done => return,
        .software => if (composing) ctx.trackDamageWhole() else ctx.trackDamage(),
    };
    switch (builtin.os.tag) {
        .linux => return runSoftwareLinux(App, app, env, options, clock, &ctx, &tw, init.gpa),
        .windows => {
            const Win32 = @import("win32").Win32;
            var shell: Win32 = undefined;
            try shell.init(.{ .title = std.unicode.utf8ToUtf16LeStringLiteral(options.title), .size = options.size }, .{
                .text = &B.text,
                .events = &B.events,
                .preedit = &B.preedit,
                .names = &B.names,
                .ends = &B.ends,
                .pixels = &B.win32_pixels,
                .glyphs = &B.glyphs,
                .first = &B.first,
                .count = &B.count,
            });
            defer shell.deinit();
            return loop(App, app, &shell, &ctx, clock, glyphs, &tw);
        },
        .macos => {
            const Macos = @import("macos").Macos;
            var shell: Macos = undefined;
            try shell.init(.{ .title = std.fmt.comptimePrint("{s}", .{options.title}), .size = options.size }, .{
                .text = &B.text,
                .events = &B.events,
                .preedit = &B.preedit,
                .names = &B.names,
                .ends = &B.ends,
                .glyphs = &B.glyphs,
                .first = &B.first,
                .count = &B.count,
            });
            defer shell.deinit();
            return loop(App, app, &shell, &ctx, clock, glyphs, &tw);
        },
        else => @compileError("lcgf app: no desktop shell for " ++ @tagName(builtin.os.tag) ++ "; the web, Android and iOS start from their shells' examples (src/shell/web, android, ios)"),
    }
}

/// How a GPU build's window ran: to the end on the GPU, or not at all (the software path).
const GpuRun = enum { done, software };

/// What the environment says about the window on Linux: `LCGF_RENDER`, `WAYLAND_DISPLAY`,
/// `XDG_RUNTIME_DIR`, `DISPLAY` and the X authority cookie file's bytes. Unset is empty.
const Env = struct {
    render: []const u8 = "",
    wayland: []const u8 = "",
    runtime_dir: []const u8 = "/tmp",
    display: []const u8 = "",
    auth: []const u8 = "",
};

fn envOf(init: std.process.Init) Env {
    const env = init.environ_map;
    return .{
        .render = env.get("LCGF_RENDER") orelse "",
        .wayland = env.get("WAYLAND_DISPLAY") orelse "",
        .runtime_dir = env.get("XDG_RUNTIME_DIR") orelse "/tmp",
        .display = env.get("DISPLAY") orelse "",
        .auth = readAuth(init) catch "",
    };
}

/// The software window on Linux: Wayland when `env.wayland` names a compositor; X11 on
/// `env.display` when it names none, or when the compositor cannot be reached and a display
/// is named. error.NoDisplay when neither is named; else the error of the last one tried.
// tidy: allow-fn(large-generic-function) one instance per App
// tidy: allow(too-many-parameters) `run`'s own inputs, passed through
fn runSoftwareLinux(
    comptime App: type,
    app: *App,
    env: Env,
    comptime options: Options,
    clock: Clock,
    ctx: *context.Context,
    tw: anytype,
    gpa: std.mem.Allocator,
) !void {
    const B = Buffers(options);
    const glyphs: Glyphs = .{ .quads = &B.glyphs, .first = &B.first, .count = &B.count };
    wayland: {
        if (env.wayland.len == 0) break :wayland;
        const wl = @import("wayland");
        const fd = wl.wire.connect(env.runtime_dir, env.wayland) catch |e| {
            if (env.display.len > 0) break :wayland;
            return e;
        };
        const size: [2]f32 = .{ @floatFromInt(options.size[0]), @floatFromInt(options.size[1]) };
        const bufs: wl.Wayland.Buffers = .{ .glyphs = &B.glyphs, .first = &B.first, .count = &B.count };
        var shell = try wl.Wayland.connect(fd, .{ .title = options.title, .size = size }, bufs);
        defer shell.deinit();
        return loop(App, app, &shell, ctx, clock, glyphs, tw);
    }
    if (env.display.len == 0) return error.NoDisplay;
    const x11 = @import("x11");
    const conn = &B.x11_conn;
    try conn.open(env.display, env.auth);
    defer conn.close();
    var pixels: std.ArrayList(u32) = .empty;
    defer pixels.deinit(gpa);
    var w: x11.Window = undefined;
    const bufs: x11.Window.Buffers = .{
        .pixels = pixels.items,
        .glyphs = &B.glyphs,
        .first = &B.first,
        .count = &B.count,
    };
    try w.open(conn, @intCast(options.size[0]), @intCast(options.size[1]), options.title, bufs);
    defer w.close();
    var shell: X11 = .{ .w = &w, .pixels = &pixels, .gpa = gpa };
    return loop(App, app, &shell, ctx, clock, glyphs, tw);
}

/// The window on the GPU when the build has one: X11 with Vulkan where `DISPLAY` is set
/// (under Wayland, through XWayland) and `LCGF_RENDER` is not `sw`. `.software` when it
/// cannot (no display, no X server there, no Vulkan device, or forced), so `run` opens the
/// software window instead, where `App.draw` is never called and `Surface.live` is false.
// tidy: allow-fn(large-generic-function) one instance per App
// tidy: allow(too-many-parameters) `run`'s own inputs, passed through
fn runGpu(
    comptime App: type,
    app: *App,
    env: Env,
    comptime options: Options,
    clock: anytype,
    ctx: *context.Context,
    tw: *text.Window,
) !GpuRun {
    const B = Buffers(options);
    std.debug.assert(ctx.limits.damage);
    const forced = std.mem.eql(u8, env.render, "sw");
    if (pickGpu(forced, env.display) == .software) return .software;
    const x11 = @import("x11");
    const display = env.display;
    const conn = &B.x11_conn;
    // No server there (a stale `DISPLAY`): the software path, which may find a compositor.
    conn.open(display, env.auth) catch return .software;
    defer conn.close();
    var w: x11.Window = undefined;
    const bufs: x11.Window.Buffers = .{
        .pixels = &.{},
        .glyphs = &B.glyphs,
        .first = &B.first,
        .count = &B.count,
    };
    try w.open(conn, @intCast(options.size[0]), @intCast(options.size[1]), options.title, bufs);
    defer w.close();
    const gw = &B.gpu_window;
    const c = options.canvas;
    const room: gpu_app.Window.Open = .{ .canvas_rows = c.rows, .canvas_verts = c.verts };
    gw.open(&w, display, room) catch return .software;
    defer gw.close();
    ctx.trackDamageWhole();
    const run_: gpu_app.Run = .{
        .w = &w,
        .ctx = ctx,
        .tw = tw,
        .quads = &B.glyphs,
        .first = &B.first,
        .count = &B.count,
    };
    try gpu_app.loop(App, app, gw, run_, clock);
    return .done;
}

/// Where a GPU build draws: on the GPU unless `LCGF_RENDER=sw` forces software or there is no
/// X display (`display` empty) to draw on.
fn pickGpu(forced_software: bool, display: []const u8) GpuRun {
    if (forced_software or display.len == 0) return .software;
    return .done;
}

/// The X authority cookie file's bytes: `XAUTHORITY`, else ~/.Xauthority.
fn readAuth(init: std.process.Init) ![]u8 {
    var buf: [512]u8 = undefined;
    const env = init.environ_map;
    const path = env.get("XAUTHORITY") orelse if (env.get("HOME")) |home|
        try std.fmt.bufPrint(&buf, "{s}/.Xauthority", .{home})
    else
        "";
    return std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(1 << 20));
}

/// The X11 window as the loop's shell: its pixels follow its size before each frame.
const X11 = if (builtin.os.tag == .linux) struct {
    w: *@import("x11").Window,
    pixels: *std.ArrayList(u32),
    gpa: std.mem.Allocator,
    pub fn poll(s: @This(), ev: *Events) bool {
        return s.w.poll(ev);
    }
    pub fn apply(s: @This(), p: anytype) void {
        s.w.apply(p);
    }
    pub fn presentWith(
        s: @This(),
        out: anytype,
        glyphs: lcgf.render_iface.Glyphs,
        images: []const sw.Image,
    ) void {
        s.w.presentWith(out, glyphs, images);
    }
    pub fn wait(s: @This(), seconds_: f32, pace: scheduler.Pace) void {
        s.w.wait(seconds_, pace);
    }
    pub fn beforeFrame(s: @This()) !void {
        try s.w.fitPixels(s.pixels, s.gpa);
    }
} else void;

/// `options.limits` with room to track damage where the shell keeps its pixels.
fn limitsOf(comptime options: Options) context.Limits {
    var limits = options.limits;
    limits.damage = builtin.os.tag != .macos;
    return limits;
}

/// Whether the text service can ever draw a window of `options`: it has font files, or the
/// build can ask the system for faces. Else the program carries none of its code.
fn serves(comptime options: Options) bool {
    return builtin.os.tag != .macos and (options.fonts.len > 0 or text.can_discover);
}

/// An App with a field `labels: Labels` gets the window's text service and a label atlas sized
/// by `options.labels`, which the window then draws canvas glyphs from, when its text is the
/// service's; else the field stays empty and canvas glyphs sample the bundled font. An App
/// without the field carves nothing.
fn openLabels(comptime App: type, app: *App, comptime options: Options, tw: anytype) void {
    if (comptime !(@hasField(App, "labels") and serves(options))) return;
    std.debug.assert(tw.labels == null);
    comptime std.debug.assert(@FieldType(App, "labels") == Labels);
    if (!tw.on()) return;
    const L = struct {
        const n = text.labels.Labels.requiredBytes(options.labels);
        var bytes: [n]u8 align(lcgf.mem.column_align) = undefined;
        var atlas: text.labels.Labels = undefined;
    };
    L.atlas = .init(&L.bytes, options.labels);
    tw.labels = &L.atlas;
    app.labels = .{ .text = &tw.text.?, .labels = &L.atlas };
}

/// `options.text` for the frame's runs.
fn textOptions(comptime options: Options) text.Options {
    var o = options.text;
    o.texts = options.limits.texts;
    return o;
}

/// Rows for one frame's glyph quads.
const Glyphs = struct { quads: []Quad, first: []u32, count: []u32 };

/// What a software shell's renderer samples: the white texture, the application's images, the
/// bundled font, and the text service's atlas when it draws the text. Remembers the images'
/// generations and sizes, to tell which changed.
/// What changed in the application's images since the frame before.
const Change = struct {
    /// Bit k + 1 (texture k + 1) when image k's generation moved.
    moved: u128 = 0,
    /// The count of images or a size changed.
    whole: bool = false,
};

const Textures = struct {
    rows: [images_max + 4]sw.Image = undefined,
    generations: [images_max]u32 = undefined,
    sizes: [images_max][2]u32 = undefined,
    len: u32 = 0,
    known: bool = false,
    /// What the last `update` found changed.
    change: Change = .{},
    /// The last `service` frame had a canvas label atlas: the row after the text's.
    labels: bool = false,

    /// The rows for `images`, and what changed since the last call (`change`); nothing
    /// on the first call, which is drawn whole anyway.
    fn update(t: *Textures, images: []const Image) []const sw.Image {
        std.debug.assert(images.len <= images_max);
        var whole = t.known and t.len != images.len;
        var moved: u128 = 0;
        t.rows[0] = .white;
        for (images, 0..) |img, k| {
            const texels = @as(usize, img.size[0]) * img.size[1];
            std.debug.assert(img.size[0] > 0);
            std.debug.assert(@max(img.pixels.len, img.alpha.len) >= texels);
            const seen = t.known and k < t.len;
            whole = whole or (seen and !std.mem.eql(u32, &t.sizes[k], &img.size));
            const bit = @as(u128, @intFromBool(seen and t.generations[k] != img.generation));
            moved |= bit << @intCast(k + 1);
            t.generations[k] = img.generation;
            t.sizes[k] = img.size;
            t.rows[k + 1] = .{
                .pixels = img.pixels,
                .alpha8 = img.alpha,
                .width = img.size[0],
                .height = img.size[1],
            };
        }
        t.rows[images.len + 1] = font.image;
        t.len = @intCast(images.len);
        t.known = true;
        t.change = .{ .moved = moved, .whole = whole };
        return t.rows[0 .. images.len + 2];
    }

    /// `d`'s damage (its context records it whole: `trackDamageWhole`) with the quads that show
    /// an image whose pixels moved (`change`), or everything when they all may; then `d` culled,
    /// for a shell that draws and sends only that.
    fn damage(t: *const Textures, d: *lcgf.draw_list.DrawList) void {
        const c = t.change;
        if (c.whole) d.damage = .everything else lcgf.damage.addTextures(d, c.moved, &d.damage);
        lcgf.damage.cull(d, &d.damage);
    }

    /// The frame's glyphs in the bundled font, sampling the last row, with the rows updated
    /// for `images` (`damage` then draws what they changed).
    fn frame(
        t: *Textures,
        images: []const Image,
        d: *const lcgf.draw_list.DrawList,
        glyphs: Glyphs,
    ) lcgf.render_iface.Glyphs {
        const rows = t.update(images);
        var g = font.glyphs(d, glyphs.quads, glyphs.first, glyphs.count);
        g.texture = @fromBackingInt(@as(u16, @intCast(rows.len - 1)));
        return g;
    }

    /// The frame's glyphs from the text service (`text.Window.glyphs`), its atlas the row
    /// after the font; canvas labels keep sampling the bundled font, as their cells are its.
    fn service(
        t: *Textures,
        images: []const Image,
        placed: text.Frame,
    ) lcgf.render_iface.Glyphs {
        std.debug.assert(placed.glyphs.first.len == placed.glyphs.count.len);
        const rows = t.update(images);
        const a = placed.atlas;
        t.rows[rows.len] = .{ .alpha8 = a.pixels, .width = a.w, .height = a.h };
        var g = placed.glyphs;
        g.texture = @fromBackingInt(@as(u16, @intCast(rows.len)));
        g.canvas = @fromBackingInt(@as(u16, @intCast(rows.len - 1)));
        t.labels = placed.labels != null;
        if (placed.labels) |l| {
            t.rows[rows.len + 1] = .{ .alpha8 = l.pixels, .width = l.w, .height = l.h };
            g.canvas = @fromBackingInt(@as(u16, @intCast(rows.len + 1)));
        }
        return g;
    }

    /// The rows the last `frame` or `service` gave the renderer.
    fn shown(t: *const Textures, service_on: bool) []const sw.Image {
        const atlases = @as(u32, @intFromBool(service_on)) + @intFromBool(service_on and t.labels);
        return t.rows[0 .. t.len + 2 + atlases];
    }
};

/// The static buffers of an application with `options`: one set per program.
fn Buffers(comptime options: Options) type {
    return struct {
        const limits = limitsOf(options);
        var ctx: [context.Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
        var glyphs: [4096]Quad = undefined;
        var first: [options.limits.texts]u32 = undefined;
        var count: [options.limits.texts]u32 = undefined;
        const service_bytes = if (serves(options))
            TextService.requiredBytes(textOptions(options))
        else
            0;
        var service: [service_bytes]u8 align(lcgf.mem.column_align) = undefined;
        var text: [512]u8 = undefined;
        var events: [128]Event = undefined;
        var preedit: [256]u8 = undefined;
        var names: [8192]u8 = undefined;
        var ends: [64]u32 = undefined;
        // Win32 paints into a fixed buffer that covers a 2560 x 1600 client.
        var win32_pixels: [if (builtin.os.tag == .windows) lcgf.render_sw.Framebuffer.len(2560, 1600) else 0]u32 = undefined;
        var x11_conn: if (builtin.os.tag == .linux) @import("x11").Connection else void = if (builtin.os.tag == .linux) .{} else {};
        var gpu_window: if (has_gpu) gpu_app.Window else void = undefined;
        var canvas_rows: [2 * limits.customs]lcgf.draw_list.CanvasDraw = undefined;
    };
}

/// How long the window stays open: `LCGF_APP_SECONDS`, else until it is closed.
const Clock = struct {
    io: std.Io,
    t0: std.Io.Timestamp,
    seconds: f32,

    pub fn left(c: Clock) f32 {
        const ns = c.t0.durationTo(std.Io.Timestamp.now(c.io, .awake)).toNanoseconds();
        return c.seconds - @as(f32, @floatCast(@as(f64, @floatFromInt(ns)) / std.time.ns_per_s));
    }
};

/// `shell_iface.run`, with the theme following the system's appearance and a time limit. A
/// software shell (one with `presentWith`) gets the text from `tw` at the window's scale, or
/// in the bundled font written into `glyphs`, and the application's images.
// tidy: allow-fn(large-generic-function) one instance per shell a program can open (two on Linux)
// tidy: allow(too-many-parameters) the run's own inputs, made once in `run`, passed through
fn loop(
    comptime App: type,
    app: *App,
    shell: anytype,
    ctx: *context.Context,
    clock: Clock,
    glyphs: Glyphs,
    tw: anytype,
) !void {
    std.debug.assert(glyphs.first.len == glyphs.count.len);
    const follows = @hasField(App, "theme") and @FieldType(App, "theme") == lcgf.widgets_base.Theme;
    var styled: ?lcgf.input.Input.Appearance = null;
    // The window's, kept from one call to the next as its pixels are: a loop run again (a
    // test, a fallback) still knows what the last frame showed.
    const Kept = struct {
        var textures: Textures = .{};
        var paging: page.Paging = .{};
    };
    const textures = &Kept.textures;
    const paging = &Kept.paging;
    canvases.ctx = ctx;
    var ev: Events = .{};
    while (shell.poll(&ev)) {
        if (follows and !std.meta.eql(styled, ev.in.appearance)) {
            styled = ev.in.appearance;
            app.theme = lcgf.theme.widgets(&lcgf.theme.forAppearance(ev.in.appearance));
            if (@hasField(@TypeOf(shell.*), "background")) shell.background = app.theme.panel;
        }
        if (comptime page.composes(App)) {
            if (paging.wants(ctx, &ev.in)) {
                if (@hasDecl(@TypeOf(shell.*), "beforeFrame")) try shell.beforeFrame();
                canvases.forget();
                composedFrame(App, app, shell, ctx, paging, textures, glyphs, tw, &ev);
            }
        } else if (ctx.needsFrame(&ev.in)) {
            if (@hasDecl(@TypeOf(shell.*), "beforeFrame")) try shell.beforeFrame();
            var f = ctx.begin(&ev.in);
            canvases.forget();
            app.build(&f, &ev);
            const out = tw.end(&f);
            shell.apply(&out.platform);
            sayCustom(out.draw);
            if (@hasDecl(@TypeOf(shell.*), "presentWith")) {
                const images = if (@hasDecl(App, "images")) app.images() else &.{};
                const g = if (tw.on())
                    textures.service(images, tw.glyphs(ctx, &out, ev.in.scale))
                else
                    textures.frame(images, out.draw, glyphs);
                // An App with images keeps its list whole (`run`): culled here, with them.
                if (@hasDecl(App, "images")) textures.damage(&ctx.draw);
                shell.presentWith(&out, g, textures.shown(tw.on()));
            } else shell.present(&out);
        }
        const left = clock.left();
        if (!(left > 0)) break;
        shell.wait(@min(scheduler.wake(ctx, &ev.in), left), scheduler.pace(ctx));
    }
}

const log = std.log.scoped(.lcgf_app);
/// A `custom` command reached the window and `sayCustom` said so.
var custom_said = false;

/// Says once, in a debug build, that `list` has a `custom` command (`Frame.custom`), which an
/// `lcgf_app` window draws nothing for. Release builds check nothing.
pub fn sayCustom(list: *const lcgf.draw_list.DrawList) void {
    if (builtin.mode != .debug or custom_said) return;
    const custom: u8 = @backingInt(lcgf.draw_list.DrawList.Kind.custom);
    if (std.mem.indexOfScalar(u8, list.cmd.kind[0..list.cmd_len], custom) == null) return;
    custom_said = true;
    log.warn("a `custom` node (Frame.custom) draws nothing in an lcgf_app window: draw it " ++
        "with a `Surface` and `draw`, a `Frame.canvas`, or an `lcgf_app.Image` on a node", .{});
}

/// One frame of a composing App (`page.build`) on a software shell: the composed list culled
/// to its damage, its text from `tw` (each side's rows) or the bundled font, and presented.
// tidy: allow-fn(large-generic-function) one instance per shell a program can open
// tidy: allow(too-many-parameters) the loop's state, passed through
fn composedFrame(
    comptime App: type,
    app: *App,
    shell: anytype,
    ctx: *context.Context,
    paging: *page.Paging,
    textures: *Textures,
    glyphs: Glyphs,
    tw: anytype,
    ev: *const Events,
) void {
    const b = page.build(App, app, paging, ctx, tw, ev);
    shell.apply(&b.out.platform);
    const d = b.composed.draw;
    sayCustom(d);
    var shown = b.out;
    shown.draw = d;
    if (!@hasDecl(@TypeOf(shell.*), "presentWith")) return shell.present(&shown);
    const images = if (@hasDecl(App, "images")) app.images() else &.{};
    const g = if (tw.on())
        textures.service(images, tw.glyphsOf(ctx, d, b.composed.texts, ev.in.scale))
    else
        textures.frame(images, d, glyphs);
    textures.damage(d);
    shell.presentWith(&shown, g, textures.shown(tw.on()));
}

const testing = std.testing;
const Color = lcgf.types.Color;

test {
    if (has_gpu) _ = gpu_app;
}

/// An application with one image of its own, drawn on a node, and a line of text.
const ImageApp = struct {
    const green = Color.rgb(0, 200, 0);
    const ground = Color.rgb(30, 30, 30);
    texels: [4]u32 = @splat(green.bitsOf()),
    list: [1]Image = undefined,
    builds: u32 = 0,

    pub fn images(a: *ImageApp) []const Image {
        a.list = .{.{ .pixels = &a.texels, .size = .{ 2, 2 } }};
        return &a.list;
    }

    pub fn build(a: *ImageApp, f: *lcgf.frame.Frame, _: *const Events) void {
        a.builds += 1;
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = ground });
        _ = f.leaf(.none, .{ .float = true, .offset = .{
            10,
            10,
        }, .size = .{ .px(20), .px(20) }, .fill = .white, .texture = @fromBackingInt(1) });
        _ = f.textStyled(
            "W",
            .{ .px = 20, .color = .white },
            .{ .float = true, .offset = .{ 100, 10 } },
        );
        f.close();
    }
};

test "textures: image k is texture k + 1, the font last; a generation moves its texture" {
    var t: Textures = .{};
    const texel = [1]u32{0xff00ff00};
    var list = [2]Image{
        .{ .pixels = &texel, .size = .{ 1, 1 } },
        .{ .pixels = &texel, .size = .{ 1, 1 } },
    };
    const rows = t.update(&list);
    // The first frame is whole anyway.
    try testing.expectEqual(0, t.change.moved);
    try testing.expect(!t.change.whole);
    try testing.expectEqual(4, rows.len);
    try testing.expectEqual(texel[0..].ptr, rows[1].pixels.ptr);
    try testing.expectEqual(font.image.alpha8.ptr, rows[3].alpha8.ptr);
    _ = t.update(&list);
    try testing.expectEqual(0, t.change.moved);
    // Image 1's pixels: texture 2, nothing else.
    list[1].generation += 1;
    _ = t.update(&list);
    try testing.expectEqual(1 << 2, t.change.moved);
    try testing.expect(!t.change.whole);
    // A size or a count: everything.
    list[0].size = .{ 1, 1 };
    _ = t.update(list[0..1]);
    try testing.expect(t.change.whole);
}

test "textures: an alpha-only image is coverage, which a fill tints" {
    var t: Textures = .{};
    const icon = [4]u8{ 0, 255, 128, 255 };
    const list = [1]Image{.{ .alpha = &icon, .size = .{ 2, 2 } }};
    const rows = t.update(&list);
    try testing.expectEqual(icon[0..].ptr, rows[1].alpha8.ptr);
    try testing.expectEqual(0, rows[1].pixels.len);
    // Drawn under a blue fill: blue where the icon has coverage, the ground where not.
    var pixels: [sw.Framebuffer.len(2, 1)]u32 = undefined;
    var fb: sw.Framebuffer = .init(&pixels, 2, 1, .rgba8);
    fb.clear(.black);
    var q: Quad = std.mem.zeroes(Quad);
    q.rect = .{ 0, 0, 2, 1 };
    q.clip = .{ 0, 0, 2, 1 };
    q.uv = .{ 0, 0, 1, 0.5 };
    q.fill = Color.rgb(0, 0, 255).bitsOf();
    q.opacity = 1;
    q.xform = .{ 1, 0, 0, 1, 0, 0 };
    var r: sw.Software = .{ .quads = &.{q}, .images = rows };
    const icon_batch: lcgf.draw_list.Batch = .{
        .first = 0,
        .count = 1,
        .texture = @fromBackingInt(1),
        .material = .solid,
    };
    r.drawBatch(.{ .fb = &fb, .scissor = .{ 0, 0, 2, 1 } }, icon_batch);
    try testing.expectEqual(Color.black, fb.at(0, 0));
    try testing.expectEqual(Color.rgb(0, 0, 255), fb.at(1, 0));
}

/// A clock that ends `loop` after `seconds`.
fn clockFor(seconds: f32) Clock {
    return .{ .io = testing.io, .t0 = .now(testing.io, .awake), .seconds = seconds };
}

test "a GPU build draws in software when forced or without a device, an App with draw too" {
    if (!has_gpu) return error.SkipZigTest;
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    const options: Options = .{ .limits = .{ .nodes = 16, .texts = 4 } };
    const B = Buffers(options);
    var ctx = try context.Context.init(&B.ctx, limitsOf(options));
    const gpa = testing.allocator;
    var tw = try text.Window.open(&B.service, textOptions(options), &.{}, false, gpa, testing.io);
    defer tw.close();
    var app: ImageApp = .{};
    var sa: SurfaceApp = .{};
    const k = clockFor(0.1);
    const forced: Env = .{ .render = "sw", .display = display };
    try testing.expectEqual(.software, try runGpu(ImageApp, &app, forced, options, k, &ctx, &tw));
    try testing.expectEqual(.software, try runGpu(SurfaceApp, &sa, forced, options, k, &ctx, &tw));
    const headless: Env = .{};
    try testing.expectEqual(.software, try runGpu(ImageApp, &app, headless, options, k, &ctx, &tw));

    // No Vulkan driver to load: the window opens, the device does not.
    const libc = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    var kept: [4096]u8 = undefined;
    const was: ?[:0]const u8 = if (std.c.getenv("VK_ICD_FILENAMES")) |v| blk: {
        const s = std.mem.span(v);
        @memcpy(kept[0..s.len], s);
        kept[s.len] = 0;
        break :blk kept[0..s.len :0];
    } else null;
    const name = "VK_ICD_FILENAMES";
    defer _ = if (was) |v| libc.setenv(name, v, 1) else libc.unsetenv(name);
    _ = libc.setenv("VK_ICD_FILENAMES", "/nonexistent/lcgf_no_icd.json", 1);
    const gpu_env: Env = .{ .display = display };
    try testing.expectEqual(.software, try runGpu(ImageApp, &app, gpu_env, options, k, &ctx, &tw));
    try testing.expectEqual(.software, try runGpu(SurfaceApp, &sa, gpu_env, options, k, &ctx, &tw));
    try testing.expectEqual(@as(u32, 0), sa.draws);
}

test "a DISPLAY with no server behind it: the GPU path falls through, the software path tries on" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const options: Options = .{ .limits = .{ .nodes = 16, .texts = 4 } };
    const B = Buffers(options);
    var ctx = try context.Context.init(&B.ctx, limitsOf(options));
    ctx.trackDamage();
    const gpa = testing.allocator;
    var tw = try text.Window.open(&B.service, textOptions(options), &.{}, false, gpa, testing.io);
    defer tw.close();
    var app: ImageApp = .{};
    const k = clockFor(0.2);
    // No X server is display 4093, and no compositor is in a runtime dir that does not exist.
    const stale = ":4093";
    const none = "/nonexistent/lcgf";
    if (has_gpu) {
        const env: Env = .{ .display = stale };
        try testing.expectEqual(.software, try runGpu(ImageApp, &app, env, options, k, &ctx, &tw));
    }
    // Neither reachable: the error of the one tried last, X11's or the compositor's.
    const x11_only: Env = .{ .display = stale };
    try testing.expect(std.meta.isError(runSoftwareLinux(ImageApp, &app, x11_only, options, k, &ctx, &tw, gpa)));
    const both: Env = .{ .wayland = "wayland-0", .runtime_dir = none, .display = stale };
    try testing.expect(std.meta.isError(runSoftwareLinux(ImageApp, &app, both, options, k, &ctx, &tw, gpa)));
    const wayland_only: Env = .{ .wayland = "wayland-0", .runtime_dir = none };
    try testing.expect(std.meta.isError(runSoftwareLinux(ImageApp, &app, wayland_only, options, k, &ctx, &tw, gpa)));
    try testing.expectError(error.NoDisplay, runSoftwareLinux(ImageApp, &app, .{}, options, k, &ctx, &tw, gpa));
    // A compositor that cannot be reached and a display that can: X11.
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse return;
    const builds = app.builds;
    const x11: Env = .{ .wayland = "wayland-0", .runtime_dir = none, .display = display };
    try runSoftwareLinux(ImageApp, &app, x11, options, k, &ctx, &tw, gpa);
    try testing.expect(app.builds > builds);
}

/// A surface on a ground, which says whether it is live, and counts the `draw` calls.
const SurfaceApp = struct {
    const fill = Color.rgb(200, 0, 100);
    plot: Surface = .{},
    draws: u32 = 0,
    live: ?bool = null,

    pub fn build(a: *SurfaceApp, f: *lcgf.frame.Frame, _: *const Events) void {
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = ImageApp.ground });
        const box: [2]lcgf.types.Size = .{ .px(40), .px(40) };
        const at: [2]f32 = .{ 10, 10 };
        const style: lcgf.types.Style = .{ .float = true, .offset = at, .size = box, .fill = fill };
        _ = a.plot.node(f, .from("plot"), style);
        a.live = a.plot.live();
        f.close();
    }

    pub fn draw(a: *SurfaceApp, _: *GpuFrame) !void {
        a.draws += 1;
        a.plot.redraw();
    }
};

test "a surface App in the software window runs: not live, no draw, its node's fill painted" {
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    const x11 = @import("x11");
    const options: Options = .{ .limits = .{ .nodes = 16, .texts = 4 } };
    const B = Buffers(options);
    var ctx = try context.Context.init(&B.ctx, limitsOf(options));
    const gpa = testing.allocator;
    var tw = try text.Window.open(&B.service, textOptions(options), &.{}, false, gpa, testing.io);
    defer tw.close();
    var app: SurfaceApp = .{};
    // What `run` does under LCGF_RENDER=sw: the GPU window declines, the software one opens.
    if (has_gpu) {
        const forced: Env = .{ .render = "sw", .display = display };
        const k = clockFor(0.1);
        const ran = try runGpu(SurfaceApp, &app, forced, options, k, &ctx, &tw);
        try testing.expectEqual(.software, ran);
    }
    ctx.trackDamage();
    const conn = &B.x11_conn;
    try conn.open(display, "");
    defer conn.close();
    conn.overrideScale(1);
    var pixels: std.ArrayList(u32) = .empty;
    defer pixels.deinit(gpa);
    var w: x11.Window = undefined;
    const bufs: x11.Window.Buffers = .{
        .pixels = pixels.items,
        .glyphs = &B.glyphs,
        .first = &B.first,
        .count = &B.count,
    };
    try page.openTestWindow(&w, conn, 100, 80, "lcgf app no gpu", bufs);
    defer w.close();
    var shell: X11 = .{ .w = &w, .pixels = &pixels, .gpa = gpa };
    const glyphs: Glyphs = .{ .quads = &B.glyphs, .first = &B.first, .count = &B.count };
    try loop(SurfaceApp, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
    try testing.expectEqual(@as(?bool, false), app.live);
    try testing.expectEqual(@as(u32, 0), app.draws);
    try testing.expectEqual(SurfaceApp.fill, try x11.pixel(&w, 30, 30));
    try testing.expectEqual(ImageApp.ground, try x11.pixel(&w, 70, 70));
}

test "a custom node in the window is said once, in a debug build" {
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    const x11 = @import("x11");
    const options: Options = .{ .limits = .{ .nodes = 16, .texts = 4, .customs = 2 } };
    const B = Buffers(options);
    var ctx = try context.Context.init(&B.ctx, limitsOf(options));
    ctx.trackDamage();
    const gpa = testing.allocator;
    var tw = try text.Window.open(&B.service, textOptions(options), &.{}, false, gpa, testing.io);
    defer tw.close();
    const conn = &B.x11_conn;
    try conn.open(display, "");
    defer conn.close();
    var pixels: std.ArrayList(u32) = .empty;
    defer pixels.deinit(gpa);
    var w: x11.Window = undefined;
    const bufs: x11.Window.Buffers = .{
        .pixels = pixels.items,
        .glyphs = &B.glyphs,
        .first = &B.first,
        .count = &B.count,
    };
    try page.openTestWindow(&w, conn, 100, 80, "lcgf app custom", bufs);
    defer w.close();
    var shell: X11 = .{ .w = &w, .pixels = &pixels, .gpa = gpa };
    const glyphs: Glyphs = .{ .quads = &B.glyphs, .first = &B.first, .count = &B.count };
    const CustomApp = struct {
        custom: bool = false,
        pub fn build(a: *@This(), f: *lcgf.frame.Frame, _: *const Events) void {
            _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = ImageApp.ground });
            if (a.custom) _ = f.custom(.from("3d"), .{ .size = .{ .px(40), .px(40) } }, 7);
            f.close();
        }
    };
    // Kept out of the test output: the build counts a test that writes to stderr as failed.
    const level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = level;
    var app: CustomApp = .{};
    try loop(CustomApp, &app, &shell, &ctx, clockFor(0.2), glyphs, &tw);
    try testing.expect(!custom_said);
    app.custom = true;
    ctx.waker.post();
    try loop(CustomApp, &app, &shell, &ctx, clockFor(0.2), glyphs, &tw);
    try testing.expectEqual(builtin.mode == .debug, custom_said);
}

/// Two images on two nodes; `bump` gives the first new pixels under a new generation.
const TwoImages = struct {
    const ground = Color.rgb(30, 30, 30);
    const green = Color.rgb(0, 200, 0);
    const blue = Color.rgb(0, 0, 220);
    const red = Color.rgb(220, 0, 0);
    const first_rect = [4]f32{ 10, 10, 30, 30 };
    const second_at = [2]f32{ 50, 10 };
    first: [4]u32 = @splat(green.bitsOf()),
    second: [4]u32 = @splat(blue.bitsOf()),
    generation: u32 = 0,
    list: [2]Image = undefined,
    builds: u32 = 0,

    pub fn images(a: *TwoImages) []const Image {
        a.list = .{
            .{ .pixels = &a.first, .size = .{ 2, 2 }, .generation = a.generation },
            .{ .pixels = &a.second, .size = .{ 2, 2 } },
        };
        return &a.list;
    }

    pub fn build(a: *TwoImages, f: *lcgf.frame.Frame, _: *const Events) void {
        std.debug.assert(first_rect[2] < second_at[0]);
        a.builds += 1;
        const size: [2]lcgf.types.Size = .{ .px(20), .px(20) };
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = ground });
        const at: [2]f32 = .{ first_rect[0], first_rect[1] };
        const one: lcgf.types.Texture = @fromBackingInt(1);
        const two: lcgf.types.Texture = @fromBackingInt(2);
        const node: lcgf.types.Style = .{ .float = true, .size = size, .fill = .white };
        var a_node = node;
        a_node.offset = at;
        a_node.texture = one;
        var b_node = node;
        b_node.offset = second_at;
        b_node.texture = two;
        _ = f.leaf(.none, a_node);
        _ = f.leaf(.none, b_node);
        f.close();
    }

    fn bump(a: *TwoImages) void {
        a.first = @splat(red.bitsOf());
        a.generation += 1;
    }
};

test "app on X11: a new generation draws and sends only the nodes that show the image" {
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    const x11 = @import("x11");
    const options: Options = .{ .limits = .{ .nodes = 16, .texts = 4 } };
    const B = Buffers(options);
    const conn = &B.x11_conn;
    try conn.open(display, "");
    defer conn.close();
    conn.overrideScale(1);
    var pixels: std.ArrayList(u32) = .empty;
    defer pixels.deinit(testing.allocator);
    var w: x11.Window = undefined;
    const bufs: x11.Window.Buffers = .{
        .pixels = pixels.items,
        .glyphs = &B.glyphs,
        .first = &B.first,
        .count = &B.count,
    };
    try page.openTestWindow(&w, conn, 200, 100, "lcgf app image damage", bufs);
    defer w.close();
    var shell: X11 = .{ .w = &w, .pixels = &pixels, .gpa = testing.allocator };
    var ctx = try context.Context.init(&B.ctx, limitsOf(options));
    // As `run` keeps an App with images.
    ctx.trackDamageWhole();
    const glyphs: Glyphs = .{ .quads = &B.glyphs, .first = &B.first, .count = &B.count };
    const gpa = testing.allocator;
    var tw = try text.Window.open(&B.service, textOptions(options), &.{}, false, gpa, testing.io);
    defer tw.close();
    var app: TwoImages = .{};
    try loop(TwoImages, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
    try testing.expectEqual(TwoImages.green, try x11.pixel(&w, 20, 20));
    try testing.expectEqual(TwoImages.blue, try x11.pixel(&w, 60, 20));

    // Image 0's new pixels: its node is the damage; the second image's node and the ground,
    // changed behind the window's back, are not drawn or sent again.
    w.fb.fill(.{ 60, 20, 61, 21 }, .white);
    w.fb.fill(.{ 150, 50, 151, 51 }, .white);
    app.bump();
    ctx.waker.post();
    try loop(TwoImages, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
    try testing.expectEqual(TwoImages.red, try x11.pixel(&w, 20, 20));
    try testing.expectEqual(TwoImages.blue, try x11.pixel(&w, 60, 20));
    try testing.expectEqual(TwoImages.ground, try x11.pixel(&w, 150, 50));

    // Idle: nothing is sent.
    const presents = w.presents;
    try loop(TwoImages, &app, &shell, &ctx, clockFor(1), glyphs, &tw);
    try testing.expectEqual(presents, w.presents);
    try testing.expectEqual(@as(u32, 0), conn.errors);
}

test "app on X11: the app's image and text in the bundled font draw; an idle second presents none" {
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    const x11 = @import("x11");
    const options: Options = .{ .limits = .{ .nodes = 16, .texts = 4 } };
    const B = Buffers(options);
    const conn = &B.x11_conn;
    try conn.open(display, "");
    defer conn.close();
    conn.overrideScale(1);
    var pixels: std.ArrayList(u32) = .empty;
    defer pixels.deinit(testing.allocator);
    var w: x11.Window = undefined;
    try page.openTestWindow(
        &w,
        conn,
        200,
        100,
        "lcgf app images",
        .{ .pixels = pixels.items, .glyphs = &B.glyphs, .first = &B.first, .count = &B.count },
    );
    defer w.close();
    var shell: X11 = .{ .w = &w, .pixels = &pixels, .gpa = testing.allocator };
    var ctx = try context.Context.init(&B.ctx, limitsOf(options));
    ctx.trackDamage();
    const glyphs: Glyphs = .{ .quads = &B.glyphs, .first = &B.first, .count = &B.count };
    const gpa = testing.allocator;
    var tw = try text.Window.open(&B.service, textOptions(options), &.{}, false, gpa, testing.io);
    defer tw.close();
    var app: ImageApp = .{};

    // Until the window has settled: its first frame, and whatever the server's exposes ask.
    try loop(ImageApp, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
    try testing.expectEqual(ImageApp.green, try x11.pixel(&w, 20, 20));
    try testing.expectEqual(ImageApp.ground, try x11.pixel(&w, 50, 50));
    // The glyph covers part of its 12 x 25 cell; a box would cover all of it.
    var lit: u32 = 0;
    for (10..35) |y| for (100..112) |x| {
        lit += @intFromBool((try x11.pixel(&w, @intCast(x), @intCast(y))).r > 128);
    };
    try testing.expect(lit > 12);
    try testing.expect(lit < 12 * 25 / 2);

    const presents = w.presents;
    const builds = app.builds;
    try loop(ImageApp, &app, &shell, &ctx, clockFor(1), glyphs, &tw);
    try testing.expectEqual(presents, w.presents);
    try testing.expectEqual(builds, app.builds);
    try testing.expectEqual(@as(u32, 0), conn.errors);
}

/// A line of proportional text over a ground, and a box that `lit` turns white.
const FontApp = struct {
    const ground = Color.rgb(30, 30, 30);
    lit: bool = false,

    pub fn build(a: *FontApp, f: *lcgf.frame.Frame, _: *const Events) void {
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = ground });
        _ = f.textStyled(
            "Wave office fluff \u{2026}",
            .{ .px = 15, .color = .white },
            .{ .float = true, .offset = .{ 8, 8 } },
        );
        const box: Color = if (a.lit) .white else .rgb(0, 0, 200);
        _ = f.leaf(.none, .{
            .float = true,
            .offset = .{ 150, 60 },
            .size = .{ .px(20), .px(20) },
            .fill = box,
        });
        f.close();
    }
};

test "app on X11 with a font file: text as the reference draws it, a change sends its damage" {
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    const x11 = @import("x11");
    const B = Buffers(font_options);
    const conn = &B.x11_conn;
    try conn.open(display, "");
    defer conn.close();
    for ([_]u16{ 1, 2 }) |k| {
        const s: f32 = @floatFromInt(k);
        conn.overrideScale(s);
        var pixels: std.ArrayList(u32) = .empty;
        defer pixels.deinit(testing.allocator);
        var w: x11.Window = undefined;
        const bufs: x11.Window.Buffers = .{
            .pixels = pixels.items,
            .glyphs = &B.glyphs,
            .first = &B.first,
            .count = &B.count,
        };
        try page.openTestWindow(&w, conn, 200 * k, 100 * k, "lcgf app text", bufs);
        defer w.close();
        var shell: X11 = .{ .w = &w, .pixels = &pixels, .gpa = testing.allocator };
        var ctx = try context.Context.init(&B.ctx, limitsOf(font_options));
        ctx.trackDamage();
        const glyphs: Glyphs = .{ .quads = &B.glyphs, .first = &B.first, .count = &B.count };
        const gpa = testing.allocator;
        var tw = try text.Window.open(&B.service, textOptions(font_options), &font_files, false, gpa, testing.io);
        defer tw.close();
        try testing.expect(tw.on());
        var app: FontApp = .{};
        try loop(FontApp, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
        try expectText(&w, &app, s);

        // The box turns white: only its rectangle is drawn and sent, so a pixel of the text
        // changed behind the window's back stays as the server has it.
        const probe: u32 = 20 * k;
        const before = try x11.pixel(&w, @intCast(probe), @intCast(probe));
        w.fb.fill(.{ probe, probe, probe + 1, probe + 1 }, .rgb(255, 0, 255));
        app.lit = true;
        ctx.waker.post();
        try loop(FontApp, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
        const box = try x11.pixel(&w, @intCast(160 * k), @intCast(70 * k));
        try testing.expectEqual(Color.white, box);
        try testing.expectEqual(before, try x11.pixel(&w, @intCast(probe), @intCast(probe)));

        // Idle: nothing presented.
        const presents = w.presents;
        try loop(FontApp, &app, &shell, &ctx, clockFor(1), glyphs, &tw);
        try testing.expectEqual(presents, w.presents);

        // The scale changes with the window open: the text is drawn again, sharp at it.
        conn.overrideScale(3 - s);
        try loop(FontApp, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
        try expectText(&w, &app, 3 - s);
    }
    try testing.expectEqual(@as(u32, 0), conn.errors);
}

const font_options: Options = .{
    .fonts = &font_files,
    .limits = .{ .nodes = 16, .texts = 4 },
    .text = .{
        .atlas = .{ 256, 256 },
        .images = 256,
        .quads = 256,
        .run_glyphs = 64,
        .run_lines = 4,
        .shape_slots = 16,
    },
};
const font_files = [_]text.File{.{ .bytes = @embedFile("layout.ttf") }};

/// The frame `app` builds in window `w` at scale `s`, laid out headless through a service of
/// its own, its glyphs rasterised straight from the face (text.zig's golden reference) white
/// over the ground: every pixel of the window's top-left 140 x 40 logical pixels within 2 of it.
// tidy: allow-fn(large-generic-function) a test helper over the X11 window, one instance
fn expectText(w: anytype, app: *FontApp, s: f32) !void {
    const x11 = @import("x11");
    const Reference = struct {
        const ctx_bytes = context.Context.requiredBytes(limitsOf(font_options));
        const service_bytes = TextService.requiredBytes(textOptions(font_options));
        var ctx: [ctx_bytes]u8 align(lcgf.mem.column_align) = undefined;
        var service: [service_bytes]u8 align(lcgf.mem.column_align) = undefined;
        var img: [400 * 200]u8 = undefined;
    };
    try page.skipResized(w, null, @as(usize, w.width) * w.height <= Reference.img.len);
    const pw: u32 = w.width;
    const ph: u32 = w.height;
    var rctx = try context.Context.init(&Reference.ctx, limitsOf(font_options));
    var t = try TextService.init(&Reference.service, textOptions(font_options), &font_files);
    const view = [2]f32{ @as(f32, @floatFromInt(pw)) / s, @as(f32, @floatFromInt(ph)) / s };
    const in: lcgf.input.Input = .{ .viewport = view, .scale = s };
    var f = rctx.begin(&in);
    app.build(&f, &.{});
    const out = f.endText(&t.stack, t.ascent);
    const img = Reference.img[0 .. @as(usize, pw) * ph];
    @memset(img, 0);
    _ = try text.drawReference(&t, out, s, img, pw);
    var bad: u32 = 0;
    var ink: u32 = 0;
    const g: u32 = FontApp.ground.r;
    const rows: u32 = @min(ph, @as(u32, @intFromFloat(40 * s)));
    const cols: u32 = @min(pw, @as(u32, @intFromFloat(140 * s)));
    for (0..rows) |y| for (0..cols) |x| {
        const c: u32 = img[y * pw + x];
        const want: i32 = @intCast(g + (c * (255 - g) + 127) / 255);
        const got = try x11.pixel(w, @intCast(x), @intCast(y));
        ink += @intFromBool(c > 0);
        bad += @intFromBool(@abs(@as(i32, got.r) - want) > 2);
    };
    const at = .{ s, pw, ph, bad, ink };
    errdefer std.debug.print("scale {d}, window {d} x {d}: {d} bad pixels of {d} inked\n", at);
    try testing.expectEqual(0, bad);
    try testing.expect(ink > 200);
}

const page_options: Options = .{
    .fonts = &font_files,
    .limits = .{ .nodes = 32, .texts = 8, .customs = 8 },
    .text = font_options.text,
};

test "app on X11: a composed page draws both sides; a pan, a widget, idle each send their own" {
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    const x11 = @import("x11");
    const B = Buffers(page_options);
    const conn = &B.x11_conn;
    try conn.open(display, "");
    defer conn.close();
    conn.overrideScale(1);
    var pixels: std.ArrayList(u32) = .empty;
    defer pixels.deinit(testing.allocator);
    var w: x11.Window = undefined;
    const bufs: x11.Window.Buffers = .{
        .pixels = pixels.items,
        .glyphs = &B.glyphs,
        .first = &B.first,
        .count = &B.count,
    };
    try page.openTestWindow(&w, conn, 300, 200, "lcgf app page", bufs);
    defer w.close();
    var shell: X11 = .{ .w = &w, .pixels = &pixels, .gpa = testing.allocator };
    var ctx = try context.Context.init(&B.ctx, limitsOf(page_options));
    ctx.trackDamageWhole();
    const glyphs: Glyphs = .{ .quads = &B.glyphs, .first = &B.first, .count = &B.count };
    const gpa = testing.allocator;
    const o = textOptions(page_options);
    var tw = try text.Window.open(&B.service, o, &font_files, false, gpa, testing.io);
    defer tw.close();
    var app: page.TestApp = .{};

    // Both sides: the page's header, its tinted icon, the region's ground and its canvas.
    try loop(page.TestApp, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
    const T = page.TestApp;
    const c = app.canvas_rect;
    try testing.expectEqual(T.page_fill, try x11.pixel(&w, 200, 4));
    try testing.expectEqual(T.tint, try x11.pixel(&w, 258, 16));
    try testing.expectEqual(T.region_fill, try x11.pixel(&w, 290, 190));
    try testing.expectEqual(T.red, try page.pixelIn(&w, c, 15, 15));
    try testing.expectEqual(T.canvas_fill, try page.pixelIn(&w, c, 50, 40));
    try page.expectPageText(&w, &app, &tw.text.?);

    // A pan, as on the GPU (`Canvas.redraw`), which a software window builds a frame for: the
    // canvas node's rect is the frame's damage, and nothing outside it is sent.
    const probe: [2]u32 = .{ 290, 190 };
    w.fb.fill(.{ probe[0], probe[1], probe[0] + 1, probe[1] + 1 }, .white);
    app.view.camera.offset = .{ 50, 30 };
    app.view.redraw();
    try loop(page.TestApp, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
    try testing.expectEqual(c, app.list.damage.bounds());
    try testing.expectEqual(T.red, try page.pixelIn(&w, c, 55, 35));
    try testing.expectEqual(T.canvas_fill, try page.pixelIn(&w, c, 15, 15));
    try testing.expectEqual(T.region_fill, try x11.pixel(&w, 290, 190));

    // The compiled checkbox: within its rect; the region's pixels are kept.
    const widget = app.widgetRect();
    w.fb.fill(.{ probe[0], probe[1], probe[0] + 1, probe[1] + 1 }, .white);
    app.ui.signals.state.grid = false;
    ctx.waker.post();
    try loop(page.TestApp, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
    const d = app.list.damage.bounds();
    try testing.expect(d[0] >= widget[0] and d[1] >= widget[1]);
    try testing.expect(d[2] <= widget[2] and d[3] <= widget[3]);
    try testing.expect(d[0] < d[2]);
    try testing.expectEqual(T.region_fill, try x11.pixel(&w, 290, 190));

    // The page's icon gets new pixels: only its node is drawn and sent.
    w.fb.fill(.{ probe[0], probe[1], probe[0] + 1, probe[1] + 1 }, .white);
    app.clearIcon();
    ctx.waker.post();
    try loop(page.TestApp, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
    try testing.expectEqual(T.page_fill, try x11.pixel(&w, 258, 16));
    try testing.expectEqual(T.region_fill, try x11.pixel(&w, 290, 190));

    // Idle: nothing is sent. (A loop's first frame is built; here it is a new loop.)
    const presents = w.presents;
    const builds = app.builds;
    try loop(page.TestApp, &app, &shell, &ctx, clockFor(1), glyphs, &tw);
    try testing.expectEqual(presents, w.presents);
    try testing.expect(app.builds <= builds + 1);
    try testing.expectEqual(@as(u32, 0), conn.errors);
}

test "app on X11: a composed page in the bundled font draws both sides' text as letters" {
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    const x11 = @import("x11");
    const B = Buffers(page_options);
    const conn = &B.x11_conn;
    try conn.open(display, "");
    defer conn.close();
    conn.overrideScale(1);
    var pixels: std.ArrayList(u32) = .empty;
    defer pixels.deinit(testing.allocator);
    var w: x11.Window = undefined;
    const bufs: x11.Window.Buffers = .{
        .pixels = pixels.items,
        .glyphs = &B.glyphs,
        .first = &B.first,
        .count = &B.count,
    };
    try page.openTestWindow(&w, conn, 300, 200, "lcgf app page mono", bufs);
    defer w.close();
    var shell: X11 = .{ .w = &w, .pixels = &pixels, .gpa = testing.allocator };
    var ctx = try context.Context.init(&B.ctx, limitsOf(page_options));
    ctx.trackDamageWhole();
    const glyphs: Glyphs = .{ .quads = &B.glyphs, .first = &B.first, .count = &B.count };
    const o = textOptions(page_options);
    var tw = try text.Window.open(&B.service, o, &.{}, false, testing.allocator, testing.io);
    defer tw.close();
    try testing.expect(!tw.on());
    var app: page.TestApp = .{};
    try loop(page.TestApp, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
    try testing.expectEqual(page.TestApp.tint, try x11.pixel(&w, 258, 16));
    // Each run's rect holds some lit pixels and some not: letters, not boxes.
    const d = &app.list;
    try testing.expectEqual(2, d.run_len);
    for (d.runs[0..d.run_len]) |r| {
        var lit: u32 = 0;
        var all: u32 = 0;
        const y0: u32 = @intFromFloat(r.rect[1]);
        const x0: u32 = @intFromFloat(r.rect[0]);
        for (y0..y0 + 12) |y| for (x0..x0 + 24) |x| {
            lit += @intFromBool((try x11.pixel(&w, @intCast(x), @intCast(y))).r > 128);
            all += 1;
        };
        try testing.expect(lit > 4);
        try testing.expect(lit < all / 2);
    }
}

const label_options: Options = .{
    .fonts = &font_files,
    .limits = .{ .nodes = 16, .texts = 4, .customs = 2 },
    .text = font_options.text,
    .labels = .{ .atlas = .{ 256, 128 }, .images = 64, .label_glyphs = 32 },
};
/// "R1 10k Vout" and "GND" take 88 of its 112 rows: twelve more glyphs do not fit beside them.
const small_labels: Options = .{
    .fonts = &font_files,
    .limits = label_options.limits,
    .text = font_options.text,
    .labels = .{ .atlas = .{ 256, 112 }, .images = 64, .label_glyphs = 32 },
};

const bitmap_options: Options = .{
    .fonts = &font_files,
    .limits = .{ .nodes = 16, .texts = 4, .customs = 2 },
    .text = font_options.text,
};

/// `BitmapApp` in software through `loop` with `options`' text: the service's when it has
/// fonts, else the bundled font's.
fn expectBitmapGlyphs(comptime options: Options, display: []const u8) !void {
    const x11 = @import("x11");
    const B = Buffers(options);
    const conn = &B.x11_conn;
    try conn.open(display, "");
    defer conn.close();
    const Shapes = lcgf.canvas.Instances;
    const Rows = struct {
        var bytes: [Shapes.requiredBytes(64, 1, 1, .{})]u8 align(lcgf.mem.column_align) = undefined;
        var reference: [lcgf.render_sw.Framebuffer.len(300, 200)]u32 = undefined;
    };
    for ([_]f32{ 1, 2 }) |s| {
        conn.overrideScale(s);
        var pixels: std.ArrayList(u32) = .empty;
        defer pixels.deinit(testing.allocator);
        var w: x11.Window = undefined;
        const bufs: x11.Window.Buffers = .{
            .pixels = pixels.items,
            .glyphs = &B.glyphs,
            .first = &B.first,
            .count = &B.count,
        };
        try page.openTestWindow(&w, conn, 300, 200, "lcgf app bitmap glyphs", bufs);
        defer w.close();
        var shell: X11 = .{ .w = &w, .pixels = &pixels, .gpa = testing.allocator };
        var ctx = try context.Context.init(&B.ctx, limitsOf(options));
        ctx.trackDamage();
        ctx.enableCanvas(&B.canvas_rows);
        const glyphs: Glyphs = .{ .quads = &B.glyphs, .first = &B.first, .count = &B.count };
        const gpa = testing.allocator;
        const files = options.fonts;
        const o = textOptions(options);
        var tw = try text.Window.open(&B.service, o, files, false, gpa, testing.io);
        defer tw.close();
        try testing.expectEqual(files.len != 0, tw.on());
        var carver: lcgf.mem.Carver = .{ .buf = &Rows.bytes };
        var shapes = Shapes.init(&carver, 64, 1, 1, .{});
        var app: text.labels.BitmapApp = .{ .shapes = &shapes };
        try loop(text.labels.BitmapApp, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
        try app.expectWindow(&w, x11.pixel, s, &Rows.reference);
    }
    try testing.expectEqual(@as(u32, 0), conn.errors);
}

test "app on X11: bitmap canvas glyphs sample the bundled font, with the service on or off" {
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    try expectBitmapGlyphs(bitmap_options, display);
    try expectBitmapGlyphs(.{ .limits = bitmap_options.limits }, display);
}

test "app on X11: canvas labels in the font file draw as the reference at camera scales 1 and 4" {
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    const x11 = @import("x11");
    const B = Buffers(label_options);
    const conn = &B.x11_conn;
    try conn.open(display, "");
    defer conn.close();
    const Shapes = lcgf.canvas.Instances;
    const Rows = struct {
        var bytes: [Shapes.requiredBytes(64, 1, 1, .{})]u8 align(lcgf.mem.column_align) = undefined;
        var reference: [lcgf.render_sw.Framebuffer.len(200, 100)]u32 = undefined;
    };
    for ([_]f32{ 1, 2 }) |s| {
        conn.overrideScale(s);
        var pixels: std.ArrayList(u32) = .empty;
        defer pixels.deinit(testing.allocator);
        var w: x11.Window = undefined;
        const bufs: x11.Window.Buffers = .{
            .pixels = pixels.items,
            .glyphs = &B.glyphs,
            .first = &B.first,
            .count = &B.count,
        };
        try page.openTestWindow(&w, conn, 200, 100, "lcgf app labels", bufs);
        defer w.close();
        var shell: X11 = .{ .w = &w, .pixels = &pixels, .gpa = testing.allocator };
        var ctx = try context.Context.init(&B.ctx, limitsOf(label_options));
        ctx.trackDamage();
        ctx.enableCanvas(&B.canvas_rows);
        const glyphs: Glyphs = .{ .quads = &B.glyphs, .first = &B.first, .count = &B.count };
        const gpa = testing.allocator;
        const o = textOptions(label_options);
        var tw = try text.Window.open(&B.service, o, &font_files, false, gpa, testing.io);
        defer tw.close();
        var carver: lcgf.mem.Carver = .{ .buf = &Rows.bytes };
        var shapes = Shapes.init(&carver, 64, 1, 1, .{});
        var app: text.labels.TestApp = .{ .shapes = &shapes, .words = &.{ "R1 10k Vout", "GND" } };
        openLabels(text.labels.TestApp, &app, label_options, &tw);
        try testing.expect(app.labels.available());
        for ([_]f32{ 1, 4 }) |zoom| {
            app.zoom = zoom;
            ctx.waker.post();
            try loop(text.labels.TestApp, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
            try app.expectWindow(&w, x11.pixel, s, &Rows.reference);
        }
        try testing.expectEqual(1, app.remakes);
        // A pan: no label is made again, no texel of the atlas changes.
        const images = tw.labels.?.image_len;
        app.pan = 30;
        ctx.waker.post();
        try loop(text.labels.TestApp, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
        try app.expectWindow(&w, x11.pixel, s, &Rows.reference);
        try testing.expectEqual(1, app.remakes);
        try testing.expectEqual(images, tw.labels.?.image_len);
    }
    try testing.expectEqual(@as(u32, 0), conn.errors);
}

test "app on X11: a full label atlas is reported, and the labels made again draw" {
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    const x11 = @import("x11");
    const B = Buffers(small_labels);
    const conn = &B.x11_conn;
    try conn.open(display, "");
    defer conn.close();
    conn.overrideScale(1);
    const Shapes = lcgf.canvas.Instances;
    const Rows = struct {
        var bytes: [Shapes.requiredBytes(64, 1, 1, .{})]u8 align(lcgf.mem.column_align) = undefined;
        var reference: [lcgf.render_sw.Framebuffer.len(200, 100)]u32 = undefined;
    };
    var pixels: std.ArrayList(u32) = .empty;
    defer pixels.deinit(testing.allocator);
    var w: x11.Window = undefined;
    const bufs: x11.Window.Buffers = .{
        .pixels = pixels.items,
        .glyphs = &B.glyphs,
        .first = &B.first,
        .count = &B.count,
    };
    try page.openTestWindow(&w, conn, 200, 100, "lcgf app labels", bufs);
    defer w.close();
    var shell: X11 = .{ .w = &w, .pixels = &pixels, .gpa = testing.allocator };
    var ctx = try context.Context.init(&B.ctx, limitsOf(small_labels));
    ctx.trackDamage();
    ctx.enableCanvas(&B.canvas_rows);
    const glyphs: Glyphs = .{ .quads = &B.glyphs, .first = &B.first, .count = &B.count };
    const gpa = testing.allocator;
    const o = textOptions(small_labels);
    var tw = try text.Window.open(&B.service, o, &font_files, false, gpa, testing.io);
    defer tw.close();
    var carver: lcgf.mem.Carver = .{ .buf = &Rows.bytes };
    var shapes = Shapes.init(&carver, 64, 1, 1, .{});
    var app: text.labels.TestApp = .{ .shapes = &shapes, .words = &.{ "R1 10k Vout", "GND" } };
    openLabels(text.labels.TestApp, &app, small_labels, &tw);
    try loop(text.labels.TestApp, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
    try testing.expectEqual(0, app.fulls);
    const first = app.labels.generation();
    // Other words: their glyphs do not fit beside the first ones, so the atlas starts again
    // and the call fails; the app makes them again in the new atlas.
    app.words = &.{ "Qwerty pzx", "JMW" };
    ctx.waker.post();
    try loop(text.labels.TestApp, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
    try testing.expectEqual(1, app.fulls);
    try testing.expect(app.labels.generation() != first);
    try app.expectWindow(&w, x11.pixel, 1, &Rows.reference);
    try testing.expectEqual(@as(u32, 0), conn.errors);
}

test "app on X11: a canvas label in a composed page's region draws as the reference" {
    const display = testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse
        return error.SkipZigTest;
    const x11 = @import("x11");
    const B = Buffers(page_options);
    const conn = &B.x11_conn;
    try conn.open(display, "");
    defer conn.close();
    conn.overrideScale(1);
    var pixels: std.ArrayList(u32) = .empty;
    defer pixels.deinit(testing.allocator);
    var w: x11.Window = undefined;
    const bufs: x11.Window.Buffers = .{
        .pixels = pixels.items,
        .glyphs = &B.glyphs,
        .first = &B.first,
        .count = &B.count,
    };
    try page.openTestWindow(&w, conn, 300, 200, "lcgf app page labels", bufs);
    defer w.close();
    var shell: X11 = .{ .w = &w, .pixels = &pixels, .gpa = testing.allocator };
    var ctx = try context.Context.init(&B.ctx, limitsOf(page_options));
    ctx.trackDamageWhole();
    const glyphs: Glyphs = .{ .quads = &B.glyphs, .first = &B.first, .count = &B.count };
    const o = textOptions(page_options);
    var tw = try text.Window.open(&B.service, o, &font_files, false, testing.allocator, testing.io);
    defer tw.close();
    var app: page.TestApp = .{};
    openLabels(page.TestApp, &app, page_options, &tw);
    try testing.expect(app.labels.available());
    try loop(page.TestApp, &app, &shell, &ctx, clockFor(0.3), glyphs, &tw);
    try testing.expect(app.labelled);
    try page.expectCanvas(&w, &app);
    try page.expectPageText(&w, &app, &tw.text.?);
    try testing.expectEqual(@as(u32, 0), conn.errors);
}
