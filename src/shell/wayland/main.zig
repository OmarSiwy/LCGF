//! The shell example (src/shell/example.zig) in a Wayland window: connects to
//! `$WAYLAND_DISPLAY`, opens a toplevel and runs `iface.run`'s loop until the window is closed.
//!
//!   --exit-when-idle   end once nothing is left to draw for half a second, and print what
//!                      happened and the theme's colours: what a compositor without input
//!                      devices (weston --backend=headless) can show
//!   --idle SECONDS     how long "idle" is (default 0.5): long enough to take a screenshot
//!   --dump PATH        at the end, write the main window's last frame as committed: width and
//!                      height (u32, little-endian), then its rows of ARGB words
//!   --ready PATH       create PATH once the compositor has shown a frame of the main window
//!                      (its frame callback came back) and nothing is left to draw: a capture
//!                      taken after that sees the frame `--dump` writes
//!   --multi            also open a second toplevel and a popup under the Reset button, each
//!                      running the example with its own context

const std = @import("std");
const lcgr = @import("lcgr");
const wire = @import("wire.zig");
const Wayland = @import("wayland.zig").Wayland;
const context = lcgr.context;
const scheduler = lcgr.scheduler;
const Events = lcgr.shell_iface.Events;

const limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
var ctx_buffers: [3][context.Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;
var glyphs: [4096]lcgr.draw_list.Quad = undefined;
var first: [limits.texts]u32 = undefined;
var count: [limits.texts]u32 = undefined;

pub fn main(init: std.process.Init) !void {
    var exit_when_idle = false;
    var multi = false;
    var idle_seconds: f32 = 0.5;
    var dump: ?[]const u8 = null;
    var ready: ?[]const u8 = null;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |a| {
        exit_when_idle = exit_when_idle or std.mem.eql(u8, a, "--exit-when-idle");
        multi = multi or std.mem.eql(u8, a, "--multi");
        if (std.mem.eql(u8, a, "--dump")) dump = args.next();
        if (std.mem.eql(u8, a, "--ready")) ready = args.next();
        if (std.mem.eql(u8, a, "--idle")) idle_seconds = try std.fmt.parseFloat(f32, args.next() orelse "0.5");
    }

    const env = init.minimal.environ;
    const fd = try wire.connect(env.getPosix("XDG_RUNTIME_DIR") orelse "/tmp", env.getPosix("WAYLAND_DISPLAY") orelse "wayland-0");
    var shell = try Wayland.connect(fd, .{ .title = "lcgr example" }, .{ .glyphs = &glyphs, .first = &first, .count = &count });
    defer shell.deinit();
    var n: usize = 1;
    if (multi) {
        _ = shell.openWindow(.{ .title = "lcgr second window", .size = .{ 400, 300 } });
        // No constraint adjustment: weston 16's headless back end (no seat) crashes in
        // weston_desktop_xdg_positioner_get_geometry when asked to slide or flip a popup.
        _ = shell.openPopup(.{ .parent = 0, .anchor = .{ .x0 = 8, .y0 = 8, .x1 = 66, .y1 = 42 }, .size = .{ 300, 120 }, .adjust = 0 });
        n = 3;
    }

    var ctxs: [3]context.Context = undefined;
    var apps: [3]lcgr.shell_example.App = @splat(.{});
    for (ctxs[0..n], ctx_buffers[0..n]) |*c, *b| c.* = try context.Context.init(b, limits);
    var evs: [3]Events = @splat(.{});
    // iface.run's body for each window, with a way out when idle: half a second without
    // anything to draw (events after a window is mapped, such as its scale, come first).
    var idle_since: ?f64 = null;
    while (shell.pollWindows(evs[0..n])) {
        var built = false;
        var wake: f32 = lcgr.types.inf;
        var pace: scheduler.Pace = .idle;
        for (0..n) |k| {
            const win = shell.windows[k];
            if (!win.open or win.closed or !win.configured) continue;
            const ctx = &ctxs[k];
            if (ctx.needsFrame(&evs[k].in)) {
                var f = ctx.begin(&evs[k].in);
                apps[k].build(&f, &evs[k]);
                const out = f.end(.{});
                shell.applyWindow(@intCast(k), &out.platform);
                shell.presentWindow(@intCast(k), &out);
                built = true;
            }
            wake = @min(wake, scheduler.wake(ctx, &evs[k].in));
            pace = @fromBackingInt(@intCast(@max(@backingInt(pace), @backingInt(scheduler.pace(ctx)))));
        }
        if (!built and shell.presents > 0 and !shell.framePending()) if (ready) |path| {
            const file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
            file.close(init.io);
            ready = null;
        };
        if (!built and exit_when_idle) {
            const now = shell.clock();
            const since = idle_since orelse now;
            idle_since = since;
            const left = idle_seconds - (now - since);
            if (!(left > 0)) break;
            shell.wait(@floatCast(left), .timer);
            continue;
        }
        idle_since = null;
        shell.wait(wake, pace);
    }

    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    for (0..n) |k| {
        const in = evs[k].in;
        const win = shell.windows[k];
        try w.interface.print("wayland-example: window {d}{s}: viewport {d}x{d} scale {d}, configured {}, {d} frames built\n", .{ k, if (win.popup) " (popup)" else "", in.viewport[0], in.viewport[1], in.scale, win.configured, apps[k].builds });
    }
    try w.interface.print("wayland-example: {d} presented, {d} dropped, error {?}\n", .{ shell.presents, shell.dropped, shell.err });
    const th = apps[0].theme;
    try w.interface.print("wayland-example: colours panel {x:0>6} control {x:0>6} text {x:0>6}\n", .{ rgb(th.panel), rgb(th.control), rgb(th.text) });
    try w.interface.flush();
    if (dump) |path| {
        const main_win = &shell.windows[0];
        const fb = main_win.shm.framebuffer(main_win.shown);
        const file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
        defer file.close(init.io);
        var fbuf: [4096]u8 = undefined;
        var fw = file.writerStreaming(init.io, &fbuf);
        try fw.interface.writeInt(u32, fb.width, .little);
        try fw.interface.writeInt(u32, fb.height, .little);
        for (0..fb.height) |y| try fw.interface.writeAll(std.mem.sliceAsBytes(fb.pixels[y * fb.stride ..][0..fb.width]));
        try fw.interface.flush();
    }
    if (shell.err != null) std.process.exit(1);
}

fn rgb(c: lcgr.types.Color) u32 {
    return (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
}
