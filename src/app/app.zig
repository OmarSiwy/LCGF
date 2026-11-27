//! app: an application in a window on the desktop, in one call. It picks the platform's shell
//! (Wayland when `WAYLAND_DISPLAY` names a compositor and X11 otherwise on Linux, Win32 on Windows, AppKit
//! with Metal on macOS), opens a window and runs `shell_iface.run`'s loop, built frame by frame
//! from your `build`, until the window closes:
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
//! appearance where the shell reports it. Text is drawn with the bundled bitmap font
//! (`render_sw.font`, DejaVu Sans Mono under its own licence: ship
//! src/example/font/LICENSE.txt with the program). An `App` with
//! `pub fn images(*App) []const Image` gives the UI its images: `Style.texture` k + 1 is
//! image k. The software shells keep last frame's pixels and redraw only what changed
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

/// An application's image, which the UI draws through `Style.texture` (texture k + 1 is image
/// k of `App.images`). RGBA8 texels (`types.Color` bits), `size[0]` by `size[1]`, row by row;
/// both sides positive. The pixels are the application's, read while a frame is drawn.
pub const Image = struct {
    pixels: []const u32,
    size: [2]u32,
    /// Changed by the application whenever `pixels` change: the next frame redraws the
    /// whole window with them.
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
};

/// Opens a window titled `options.title` and runs `app` in it until the window is closed.
/// `App` has `pub fn build(*App, *lcgf.frame.Frame, *const lcgf.shell_iface.Events) void`,
/// and may have `pub fn images(*App) []const Image` (at most `images_max`; the software shells
/// draw them, the macOS shell, on Metal, not yet).
pub fn run(comptime App: type, app: *App, init: std.process.Init, comptime options: Options) !void {
    if (!@hasDecl(App, "build")) @compileError(@typeName(App) ++ " needs `pub fn build(*App, *lcgf.frame.Frame, *const lcgf.shell_iface.Events) void`");
    const B = Buffers(options);
    const seconds: f32 = if (init.environ_map.get("LCGF_APP_SECONDS")) |s| std.fmt.parseFloat(f32, s) catch lcgf.types.inf else lcgf.types.inf;
    const clock: Clock = .{ .io = init.io, .t0 = std.Io.Timestamp.now(init.io, .awake), .seconds = seconds };
    var ctx = try context.Context.init(&B.ctx, limitsOf(options));
    // The software shells keep the last frame's pixels; Metal draws every frame whole.
    if (builtin.os.tag != .macos) ctx.trackDamage();
    const glyphs: Glyphs = .{ .quads = &B.glyphs, .first = &B.first, .count = &B.count };
    switch (builtin.os.tag) {
        .linux => {
            const env = init.minimal.environ;
            // Wayland when WAYLAND_DISPLAY names a compositor; X11 when it is unset or empty,
            // or when the compositor cannot be reached and DISPLAY is set.
            wayland: {
                const name = env.getPosix("WAYLAND_DISPLAY") orelse break :wayland;
                if (name.len == 0) break :wayland;
                const wl = @import("wayland");
                const fd = wl.wire.connect(env.getPosix("XDG_RUNTIME_DIR") orelse "/tmp", name) catch |e| {
                    if (init.environ_map.get("DISPLAY") != null) break :wayland;
                    return e;
                };
                var shell = try wl.Wayland.connect(fd, .{ .title = options.title, .size = .{ @floatFromInt(options.size[0]), @floatFromInt(options.size[1]) } }, .{ .glyphs = &B.glyphs, .first = &B.first, .count = &B.count });
                defer shell.deinit();
                return loop(App, app, &shell, &ctx, clock, glyphs);
            }
            const x11 = @import("x11");
            const display = init.environ_map.get("DISPLAY") orelse return error.NoDisplay;
            var auth_path_buf: [512]u8 = undefined;
            const auth_path = init.environ_map.get("XAUTHORITY") orelse if (init.environ_map.get("HOME")) |home| try std.fmt.bufPrint(&auth_path_buf, "{s}/.Xauthority", .{home}) else "";
            const auth = std.Io.Dir.cwd().readFileAlloc(init.io, auth_path, init.gpa, .limited(1 << 20)) catch "";
            const conn = &B.x11_conn;
            try conn.open(display, auth);
            defer conn.close();
            var pixels: std.ArrayList(u32) = .empty;
            defer pixels.deinit(init.gpa);
            var w: x11.Window = undefined;
            try w.open(conn, @intCast(options.size[0]), @intCast(options.size[1]), options.title, .{ .pixels = pixels.items, .glyphs = &B.glyphs, .first = &B.first, .count = &B.count });
            defer w.close();
            var shell: X11 = .{ .w = &w, .pixels = &pixels, .gpa = init.gpa };
            return loop(App, app, &shell, &ctx, clock, glyphs);
        },
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
            return loop(App, app, &shell, &ctx, clock, glyphs);
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
            return loop(App, app, &shell, &ctx, clock, glyphs);
        },
        else => @compileError("lcgf app: no desktop shell for " ++ @tagName(builtin.os.tag) ++ "; the web, Android and iOS start from their shells' examples (src/shell/web, android, ios)"),
    }
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

/// Rows for one frame's glyph quads.
const Glyphs = struct { quads: []Quad, first: []u32, count: []u32 };

/// What a software shell's renderer samples: the white texture, the application's images, the
/// bundled font last. Remembers the images' generations, to tell when they change.
const Textures = struct {
    rows: [images_max + 2]sw.Image = undefined,
    generations: [images_max]u32 = undefined,
    len: u32 = 0,
    known: bool = false,

    /// The rows for `images`. `changed` is set when an image differs from the last call's
    /// (its generation, or how many there are), never on the first call.
    fn update(t: *Textures, images: []const Image, changed: *bool) []const sw.Image {
        std.debug.assert(images.len <= images_max);
        var same = !t.known or t.len == images.len;
        t.rows[0] = .white;
        for (images, 0..) |img, k| {
            std.debug.assert(img.size[0] > 0);
            std.debug.assert(img.pixels.len >= @as(usize, img.size[0]) * img.size[1]);
            same = same and (!t.known or k >= t.len or t.generations[k] == img.generation);
            t.generations[k] = img.generation;
            t.rows[k + 1] = .{ .pixels = img.pixels, .width = img.size[0], .height = img.size[1] };
        }
        t.rows[images.len + 1] = font.image;
        t.len = @intCast(images.len);
        t.known = true;
        changed.* = !same;
        return t.rows[0 .. images.len + 2];
    }

    /// The frame's glyphs in the bundled font, sampling the last row, with the rows updated
    /// for `images`. A change to them came after this frame's damage was taken: the next frame
    /// redraws everything, at once.
    fn frame(
        t: *Textures,
        ctx: *context.Context,
        images: []const Image,
        d: *const lcgf.draw_list.DrawList,
        glyphs: Glyphs,
    ) lcgf.render_iface.Glyphs {
        var changed = false;
        const rows = t.update(images, &changed);
        if (changed) {
            ctx.redrawAll();
            ctx.waker.post();
        }
        var g = font.glyphs(d, glyphs.quads, glyphs.first, glyphs.count);
        g.texture = @fromBackingInt(@as(u16, @intCast(rows.len - 1)));
        return g;
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
        var text: [512]u8 = undefined;
        var events: [128]Event = undefined;
        var preedit: [256]u8 = undefined;
        var names: [8192]u8 = undefined;
        var ends: [64]u32 = undefined;
        // Win32 paints into a fixed buffer that covers a 2560 x 1600 client.
        var win32_pixels: [if (builtin.os.tag == .windows) lcgf.render_sw.Framebuffer.len(2560, 1600) else 0]u32 = undefined;
        var x11_conn: if (builtin.os.tag == .linux) @import("x11").Connection else void = if (builtin.os.tag == .linux) .{} else {};
    };
}

/// How long the window stays open: `LCGF_APP_SECONDS`, else until it is closed.
const Clock = struct {
    io: std.Io,
    t0: std.Io.Timestamp,
    seconds: f32,

    fn left(c: Clock) f32 {
        const ns = c.t0.durationTo(std.Io.Timestamp.now(c.io, .awake)).toNanoseconds();
        return c.seconds - @as(f32, @floatCast(@as(f64, @floatFromInt(ns)) / std.time.ns_per_s));
    }
};

/// `shell_iface.run`, with the theme following the system's appearance and a time limit. A
/// software shell (one with `presentWith`) gets the text in the bundled font, written into
/// `glyphs`, and the application's images.
// tidy: allow-fn(large-generic-function) one instance per shell a program can open (two on Linux)
fn loop(
    comptime App: type,
    app: *App,
    shell: anytype,
    ctx: *context.Context,
    clock: Clock,
    glyphs: Glyphs,
) !void {
    const follows = @hasField(App, "theme") and @FieldType(App, "theme") == lcgf.widgets_base.Theme;
    var styled: ?lcgf.input.Input.Appearance = null;
    var textures: Textures = .{};
    var ev: Events = .{};
    while (shell.poll(&ev)) {
        if (follows and !std.meta.eql(styled, ev.in.appearance)) {
            styled = ev.in.appearance;
            app.theme = lcgf.theme.widgets(&lcgf.theme.forAppearance(ev.in.appearance));
            if (@hasField(@TypeOf(shell.*), "background")) shell.background = app.theme.panel;
        }
        if (ctx.needsFrame(&ev.in)) {
            if (@hasDecl(@TypeOf(shell.*), "beforeFrame")) try shell.beforeFrame();
            var f = ctx.begin(&ev.in);
            app.build(&f, &ev);
            const out = f.end(.{});
            shell.apply(&out.platform);
            if (@hasDecl(@TypeOf(shell.*), "presentWith")) {
                const images = if (@hasDecl(App, "images")) app.images() else &.{};
                const g = textures.frame(ctx, images, out.draw, glyphs);
                shell.presentWith(&out, g, textures.rows[0 .. textures.len + 2]);
            } else shell.present(&out);
        }
        const left = clock.left();
        if (!(left > 0)) break;
        shell.wait(@min(scheduler.wake(ctx, &ev.in), left), scheduler.pace(ctx));
    }
}

const testing = std.testing;
const Color = lcgf.types.Color;

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

test "textures: image k is texture k + 1, the font last; a new generation or count is a change" {
    var t: Textures = .{};
    const texel = [1]u32{0xff00ff00};
    var list = [2]Image{
        .{ .pixels = &texel, .size = .{ 1, 1 } },
        .{ .pixels = &texel, .size = .{ 1, 1 } },
    };
    var changed = true;
    const rows = t.update(&list, &changed);
    try testing.expect(!changed); // the first frame is whole anyway
    try testing.expectEqual(4, rows.len);
    try testing.expectEqual(texel[0..].ptr, rows[1].pixels.ptr);
    try testing.expectEqual(font.image.alpha8.ptr, rows[3].alpha8.ptr);
    _ = t.update(&list, &changed);
    try testing.expect(!changed);
    list[1].generation += 1;
    _ = t.update(&list, &changed);
    try testing.expect(changed);
    _ = t.update(list[0..1], &changed);
    try testing.expect(changed);
}

/// A clock that ends `loop` after `seconds`.
fn clockFor(seconds: f32) Clock {
    return .{ .io = testing.io, .t0 = .now(testing.io, .awake), .seconds = seconds };
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
    try w.open(
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
    var app: ImageApp = .{};

    // Until the window has settled: its first frame, and whatever the server's exposes ask.
    try loop(ImageApp, &app, &shell, &ctx, clockFor(0.3), glyphs);
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
    try loop(ImageApp, &app, &shell, &ctx, clockFor(1), glyphs);
    try testing.expectEqual(presents, w.presents);
    try testing.expectEqual(builds, app.builds);
    try testing.expectEqual(@as(u32, 0), conn.errors);
}
