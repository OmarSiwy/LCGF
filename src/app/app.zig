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
//! src/example/font/LICENSE.txt with the program). The buffers are static: nothing is
//! allocated but X11's pixels, which follow the window's size.
//! `LCGF_APP_SECONDS` in the environment closes the window after that many seconds (a test on
//! a headless server). The web, Android and iOS start an application their own way: their
//! shells' examples (src/shell/web, android, ios) are the place to start there. Tier 3.

const std = @import("std");
const builtin = @import("builtin");
const lcgf = @import("lcgf");
const context = lcgf.context;
const scheduler = lcgf.scheduler;
const Quad = lcgf.draw_list.Quad;
const Events = lcgf.shell_iface.Events;
const Event = lcgf.input.Input.Event;

pub const Options = struct {
    title: []const u8 = "LCGF",
    /// The window's content, in logical pixels.
    size: [2]u32 = .{ 800, 600 },
    /// The frame's capacities: `Context` is made with them.
    limits: context.Limits = .{ .nodes = 1024, .texts = 256 },
};

/// Opens a window titled `options.title` and runs `app` in it until the window is closed.
/// `App` has `pub fn build(*App, *lcgf.frame.Frame, *const lcgf.shell_iface.Events) void`.
pub fn run(comptime App: type, app: *App, init: std.process.Init, comptime options: Options) !void {
    if (!@hasDecl(App, "build")) @compileError(@typeName(App) ++ " needs `pub fn build(*App, *lcgf.frame.Frame, *const lcgf.shell_iface.Events) void`");
    const B = Buffers(options);
    const seconds: f32 = if (init.environ_map.get("LCGF_APP_SECONDS")) |s| std.fmt.parseFloat(f32, s) catch lcgf.types.inf else lcgf.types.inf;
    const clock: Clock = .{ .io = init.io, .t0 = std.Io.Timestamp.now(init.io, .awake), .seconds = seconds };
    var ctx = try context.Context.init(&B.ctx, options.limits);
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
                useFont(&shell);
                return loop(App, app, &shell, &ctx, clock);
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
            useFont(&w);
            const X11 = struct {
                w: *x11.Window,
                pixels: *std.ArrayList(u32),
                gpa: std.mem.Allocator,
                pub fn poll(s: @This(), ev: *Events) bool {
                    return s.w.poll(ev);
                }
                pub fn apply(s: @This(), p: anytype) void {
                    s.w.apply(p);
                }
                pub fn present(s: @This(), out: anytype) void {
                    s.w.present(out);
                }
                pub fn wait(s: @This(), seconds_: f32, pace: scheduler.Pace) void {
                    s.w.wait(seconds_, pace);
                }
                /// The window's pixels follow its size before each frame.
                pub fn beforeFrame(s: @This()) !void {
                    try s.w.fitPixels(s.pixels, s.gpa);
                }
            };
            var shell: X11 = .{ .w = &w, .pixels = &pixels, .gpa = init.gpa };
            return loop(App, app, &shell, &ctx, clock);
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
            useFont(&shell);
            return loop(App, app, &shell, &ctx, clock);
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
            return loop(App, app, &shell, &ctx, clock);
        },
        else => @compileError("lcgf app: no desktop shell for " ++ @tagName(builtin.os.tag) ++ "; the web, Android and iOS start from their shells' examples (src/shell/web, android, ios)"),
    }
}

/// A software shell draws its text with the bundled bitmap font (`render_sw.font`) instead of
/// boxes: the font is image 1 of its renderer, and its glyphs sample it.
const text_images = [_]lcgf.render_sw.Image{ .white, lcgf.render_sw_font.image };
fn useFont(shell: anytype) void {
    shell.gfx.gfx.images = &text_images;
    shell.text_texture = @fromBackingInt(1);
}

/// The static buffers of an application with `options`: one set per program.
fn Buffers(comptime options: Options) type {
    return struct {
        var ctx: [context.Context.requiredBytes(options.limits)]u8 align(lcgf.mem.column_align) = undefined;
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

/// `shell_iface.run`, with the theme following the system's appearance and a time limit.
fn loop(comptime App: type, app: *App, shell: anytype, ctx: *context.Context, clock: Clock) !void {
    const follows = @hasField(App, "theme") and @FieldType(App, "theme") == lcgf.widgets_base.Theme;
    var styled: ?lcgf.input.Input.Appearance = null;
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
            shell.present(&out);
        }
        const left = clock.left();
        if (!(left > 0)) break;
        shell.wait(@min(scheduler.wake(ctx, &ev.in), left), scheduler.pace(ctx));
    }
}
