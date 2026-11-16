//! The shells' example application (src/shell/example.zig) in the Android shell: `zig build
//! android-build -Dtarget=aarch64-linux-android` builds zig-out/lib/libandroid-example.so, the
//! library a NativeActivity loads (its manifest names it with `android.app.lib_name`).
//!
//! Started with the intent extra `lcgr.replay` (`adb shell am start -n <package>/
//! android.app.NativeActivity --ez lcgr.replay true`), it is the input replay test on a
//! device: the real activity, window and Vulkan swapchain, with testdata/example.events fed to
//! the translator in place of the user's touches. It logs the example's results (logcat, tag
//! lcgr: "replay ... ok" when they are the headless shell's: one reset, four layers,
//! exposure 3) and finishes the activity.

const std = @import("std");
const lcgr = @import("lcgr");
const android = @import("android.zig");
const context = lcgr.context;
const Quad = lcgr.draw_list.Quad;

comptime {
    _ = &android.ANativeActivity_onCreate; // the entry point Android looks up
}

const limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
// Static, so the program allocates nothing.
var ctx_buffer: [context.Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;
var glyphs: [4096]Quad = undefined;
var first: [limits.texts]u32 = undefined;
var count: [limits.texts]u32 = undefined;
var text: [512]u8 = undefined;
var events: [128]lcgr.input.Input.Event = undefined;

/// The host loop, on the shell's thread (android.zig).
pub fn androidMain() void {
    var shell: android.Android = undefined;
    shell.init(.{ .glyphs = &glyphs, .first = &first, .count = &count, .text = &text, .events = &events }) catch return;
    defer shell.deinit();
    const replay = shell.intentFlag("lcgr.replay");
    if (replay) shell.recording = .{ .src = @embedFile("testdata/example.events") };
    var ctx = context.Context.init(&ctx_buffer, limits) catch return;
    var app: lcgr.shell_example.App = .{};
    shell.background = app.theme.panel;
    // iface.run's loop, with the root padded by the safe area; a change of it, or a return
    // from the background, is not Input, so it asks for a frame. The panel colour behind
    // fills the bars' strips.
    var ev: lcgr.shell_iface.Events = .{};
    var safe = shell.safeArea();
    while (shell.poll(&ev)) {
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
    shell.log("replay: polls={d} presents={d} builds={d} resets={d} layers={d} exposure={d:.2} {s}", .{
        shell.polls, shell.presents, app.builds, app.resets, app.layers, app.exposure, if (ok) "ok" else "FAILED",
    });
}
