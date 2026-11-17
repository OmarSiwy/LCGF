//! The shells' example application (src/shell/example.zig) in a Win32 window: `zig build
//! win32-example -Dtarget=x86_64-windows` builds zig-out/bin/win32-example.exe. The loop is
//! iface.run's, written out so it can follow the system's dark mode and accent colour; the 3D
//! viewport shows the shell's background.

const std = @import("std");
const lcgf = @import("lcgf");
const Win32 = @import("win32.zig").Win32;
const context = lcgf.context;
const scheduler = lcgf.scheduler;
const Events = lcgf.shell_iface.Events;
const Quad = lcgf.draw_list.Quad;
const Event = lcgf.input.Input.Event;

const limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
// Static, so the program allocates nothing: the frame buffer covers a 2560 x 1600 client.
var ctx_buffer: [context.Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
var pixels: [lcgf.render_sw.Framebuffer.len(2560, 1600)]u32 = undefined;
var glyphs: [4096]Quad = undefined;
var first: [limits.texts]u32 = undefined;
var count: [limits.texts]u32 = undefined;
var text: [512]u8 = undefined;
var events: [128]Event = undefined;
var preedit: [256]u8 = undefined;
var names: [8192]u8 = undefined;
var ends: [64]u32 = undefined;

pub fn main() !void {
    var shell: Win32 = undefined;
    try shell.init(.{ .title = std.unicode.utf8ToUtf16LeStringLiteral("LCGF example") }, .{
        .text = &text,
        .events = &events,
        .preedit = &preedit,
        .names = &names,
        .ends = &ends,
        .pixels = &pixels,
        .glyphs = &glyphs,
        .first = &first,
        .count = &count,
    });
    defer shell.deinit();
    var ctx = try context.Context.init(&ctx_buffer, limits);
    var app: lcgf.shell_example.App = .{};
    // Restyled for the system's appearance on the first frame and whenever it changes; a
    // change is input, so the frame that sees it is built.
    var styled: ?lcgf.input.Input.Appearance = null;

    var ev: Events = .{};
    while (shell.poll(&ev)) {
        if (!std.meta.eql(styled, ev.in.appearance)) {
            styled = ev.in.appearance;
            app.theme = lcgf.theme.widgets(&lcgf.theme.forAppearance(ev.in.appearance));
            shell.background = app.theme.panel;
        }
        if (ctx.needsFrame(&ev.in)) {
            var f = ctx.begin(&ev.in);
            app.build(&f, &ev);
            const out = f.end(.{});
            shell.apply(&out.platform);
            shell.present(&out);
        }
        shell.wait(scheduler.wake(&ctx, &ev.in), scheduler.pace(&ctx));
    }
}
