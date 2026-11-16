//! The shells' example application (src/shell/example.zig) in the iOS shell: `zig build
//! ios-build -Dtarget=aarch64-ios` builds zig-out/lib/libios-example.a, whose `main` an app
//! bundle links (UIKit and Metal are opened at run time, so only libSystem is needed).
//!
//! Launched with `--replay`, it is the input replay test on a device: the real view, run loop
//! and Metal layer, with testdata/example.uikit fed to the translator in place of the user's
//! touches. It prints the example's results and exits 0 when they are the headless shell's
//! (one reset, four layers, exposure 3), 1 when not.

const std = @import("std");
const lcgr = @import("lcgr");
const ios = @import("ios.zig");
const context = lcgr.context;
const Quad = lcgr.draw_list.Quad;

const limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
// Static, so the program allocates nothing.
var ctx_buffer: [context.Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;
var glyphs: [4096]Quad = undefined;
var first: [limits.texts]u32 = undefined;
var count: [limits.texts]u32 = undefined;
var text: [512]u8 = undefined;
var events: [128]lcgr.input.Input.Event = undefined;
var replay = false;

export fn main(argc: c_int, argv: ?[*]?[*:0]u8) c_int {
    if (argv) |a| for (a[0..@intCast(argc)]) |arg| {
        if (arg != null and std.mem.eql(u8, std.mem.span(arg.?), "--replay")) replay = true;
    };
    ios.start(argc, argv, run);
}

fn run() void {
    var shell: ios.Ios = undefined;
    shell.init(.{ .glyphs = &glyphs, .first = &first, .count = &count, .text = &text, .events = &events }) catch |e| {
        std.debug.print("ios-example: {t}\n", .{e});
        std.process.exit(1);
    };
    defer shell.deinit();
    if (replay) shell.recording = .{ .src = @embedFile("testdata/example.uikit") };
    var ctx = context.Context.init(&ctx_buffer, limits) catch std.process.exit(1);
    var app: lcgr.shell_example.App = .{};
    shell.background = app.theme.panel;
    // iface.run's loop, with the root padded by the safe area; the panel colour behind it
    // fills the corners and the strip under the home indicator.
    var ev: lcgr.shell_iface.Events = .{};
    var safe = shell.safeArea();
    while (shell.poll(&ev)) {
        // Not Input: a change of the safe area alone (the status bar hidden), or a return from
        // the background (frames built there were not shown), asks for a frame.
        if (shell.resumed()) ctx.waker.post();
        if (!std.meta.eql(shell.safeArea(), safe)) {
            safe = shell.safeArea();
            ctx.waker.post();
        }
        if (ctx.needsFrame(&ev.in)) {
            var f = ctx.begin(&ev.in);
            // The recording's taps are at the example's 800 x 600 layout, unpadded.
            _ = f.open(.from("safe-area"), .{ .size = .{ .fill, .fill }, .pad = if (replay) @splat(0) else safe });
            app.build(&f, &ev);
            f.close();
            const out = f.end(.{});
            shell.apply(&out.platform);
            shell.present(&out);
        }
        shell.wait(lcgr.scheduler.wake(&ctx, &ev.in), lcgr.scheduler.pace(&ctx));
    }
    if (!replay) return;
    const ok = shell.err == null and app.resets == 1 and app.layers == 4 and @abs(app.exposure - 3) < 0.01;
    std.debug.print("ios-example replay: polls={d} presents={d} builds={d} resets={d} layers={d} exposure={d:.2} {s}\n", .{
        shell.polls, shell.presents, app.builds, app.resets, app.layers, app.exposure, if (ok) "ok" else "FAILED",
    });
    std.process.exit(if (ok) 0 else 1);
}
