//! The shells' example application (src/shell/example.zig) in the iOS shell: `zig build
//! ios-build -Dtarget=aarch64-ios` builds zig-out/lib/libios-example.a, whose `main` an app
//! bundle links (UIKit and Metal are opened at run time, so only libSystem is needed).

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

export fn main(argc: c_int, argv: ?[*]?[*:0]u8) c_int {
    ios.start(argc, argv, run);
}

fn run() void {
    var shell: ios.Ios = undefined;
    shell.init(.{ .glyphs = &glyphs, .first = &first, .count = &count }) catch |e| {
        std.debug.print("ios-example: {t}\n", .{e});
        return;
    };
    defer shell.deinit();
    var ctx = context.Context.init(&ctx_buffer, limits) catch return;
    var app: lcgr.shell_example.App = .{};
    shell.background = app.theme.panel;
    lcgr.shell_iface.run(&shell, &ctx, &app);
}
