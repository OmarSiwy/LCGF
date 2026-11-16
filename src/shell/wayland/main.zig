//! The shell example (src/shell/example.zig) in a Wayland window: connects to
//! `$WAYLAND_DISPLAY`, opens a toplevel and runs `iface.run`'s loop until the window is closed.
//! `--exit-when-idle` ends the program instead once nothing is left to draw, and prints what
//! happened: what a compositor without input devices (weston --backend=headless) can show.

const std = @import("std");
const lcgr = @import("lcgr");
const wire = @import("wire.zig");
const Wayland = @import("wayland.zig").Wayland;
const context = lcgr.context;
const scheduler = lcgr.scheduler;

const limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
var ctx_buffer: [context.Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;
var glyphs: [4096]lcgr.draw_list.Quad = undefined;
var first: [limits.texts]u32 = undefined;
var count: [limits.texts]u32 = undefined;

pub fn main(init: std.process.Init) !void {
    var exit_when_idle = false;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |a| exit_when_idle = exit_when_idle or std.mem.eql(u8, a, "--exit-when-idle");

    const env = init.minimal.environ;
    const fd = try wire.connect(env.getPosix("XDG_RUNTIME_DIR") orelse "/tmp", env.getPosix("WAYLAND_DISPLAY") orelse "wayland-0");
    var shell = try Wayland.connect(fd, .{ .title = "lcgr example" }, .{ .glyphs = &glyphs, .first = &first, .count = &count });
    defer shell.deinit();

    var ctx = try context.Context.init(&ctx_buffer, limits);
    var app: lcgr.shell_example.App = .{};
    var ev: lcgr.shell_iface.Events = .{};
    // iface.run's body, with a way out when idle.
    while (shell.poll(&ev)) {
        if (ctx.needsFrame(&ev.in)) {
            var f = ctx.begin(&ev.in);
            app.build(&f, &ev);
            const out = f.end(.{});
            shell.apply(&out.platform);
            shell.present(&out);
        } else if (exit_when_idle) break;
        shell.wait(scheduler.wake(&ctx, &ev.in), scheduler.pace(&ctx));
    }

    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
    try w.interface.print("wayland-example: viewport {d}x{d} scale {d}, {d} frames built, {d} presented, {d} dropped, error {?}\n", .{ ev.in.viewport[0], ev.in.viewport[1], ev.in.scale, app.builds, shell.presents, shell.dropped, shell.err });
    try w.interface.flush();
    if (shell.err != null) std.process.exit(1);
}
