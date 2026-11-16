//! The shells' example application (src/shell/example.zig) in a macOS window, drawn with Metal:
//!
//!     zig build macos-example && zig-out/bin/macos-example [seconds]
//!
//! The loop is iface.run's, written out so it can follow the system's appearance and stop after
//! `seconds` (ci/jobs/macos-shell.sh runs it for 2 on a macOS runner). Prints how many frames it
//! built.

const std = @import("std");
const lcgr = @import("lcgr");
const Macos = @import("macos.zig").Macos;
const context = lcgr.context;
const scheduler = lcgr.scheduler;
const Events = lcgr.shell_iface.Events;
const Quad = lcgr.draw_list.Quad;
const Event = lcgr.input.Input.Event;

const limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
// Static, so the program allocates nothing.
var ctx_buffer: [context.Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;
var glyphs: [4096]Quad = undefined;
var first: [limits.texts]u32 = undefined;
var count: [limits.texts]u32 = undefined;
var text: [512]u8 = undefined;
var events: [128]Event = undefined;
var preedit: [256]u8 = undefined;
var names: [8192]u8 = undefined;
var ends: [64]u32 = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const seconds: f32 = if (args.next()) |s| try std.fmt.parseFloat(f32, s) else lcgr.types.inf;

    var shell: Macos = undefined;
    try shell.init(.{ .title = "LCGR example" }, .{
        .text = &text,
        .events = &events,
        .preedit = &preedit,
        .names = &names,
        .ends = &ends,
        .glyphs = &glyphs,
        .first = &first,
        .count = &count,
    });
    defer shell.deinit();
    var ctx = try context.Context.init(&ctx_buffer, limits);
    var app: lcgr.shell_example.App = .{ .theme = lcgr.theme.widgets(&shell.appearance.tokens()) };
    shell.background = app.theme.panel;

    const t0 = std.Io.Timestamp.now(io, .awake);
    var ev: Events = .{};
    while (shell.poll(&ev)) {
        if (shell.appearanceChanged()) |a| {
            app.theme = lcgr.theme.widgets(&a.tokens());
            shell.background = app.theme.panel;
            ctx.waker.post();
        }
        if (ctx.needsFrame(&ev.in)) {
            var f = ctx.begin(&ev.in);
            app.build(&f, &ev);
            const out = f.end(.{});
            shell.apply(&out.platform);
            shell.present(&out);
        }
        const elapsed: f32 = @floatCast(@as(f64, @floatFromInt(t0.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds())) / std.time.ns_per_s);
        if (elapsed >= seconds) break;
        shell.wait(@min(scheduler.wake(&ctx, &ev.in), seconds - elapsed), scheduler.pace(&ctx));
    }

    var buf: [128]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    try out.interface.print("macos-example: {d} frames built\n", .{app.builds});
    try out.interface.flush();
    if (app.builds == 0) return error.ExampleFailed;
}
