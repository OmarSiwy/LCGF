//! The shells' example application (src/shell/example.zig) in the Android shell: `zig build
//! android-build -Dtarget=aarch64-linux-android` builds zig-out/lib/libandroid-example.so, the
//! library a NativeActivity loads (its manifest names it with `android.app.lib_name`).

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
    var ctx = context.Context.init(&ctx_buffer, limits) catch return;
    var app: lcgr.shell_example.App = .{};
    shell.background = app.theme.panel;
    lcgr.shell_iface.run(&shell, &ctx, &app);
}
