//! The examples of docs/guide/backends.md, compiled and run by `zig build docs`. Every ```zig
//! block of the guide is a verbatim piece of this file (docs/guide/snippets.py checks that).
//! The docs build selects the software back end (`lcgr_render` with render = sw), so the frame
//! below really draws, into a framebuffer, with no GPU.

const std = @import("std");
const testing = std.testing;
const lcgr = @import("lcgr");
const Context = lcgr.context.Context;
const DrawList = lcgr.draw_list.DrawList;

// -- frame
const render = @import("lcgr_render");

/// One frame on whichever back end the build selected: the same code for all of them.
fn drawFrame(gfx: *render.Renderer, queue: render.Queue, pass: render.Pass, draw: *const DrawList, glyphs: lcgr.render_iface.Glyphs, viewport: [2]f32, scale: f32) void {
    gfx.prepare(queue, draw, glyphs, viewport, scale); // uploads, before the pass begins
    lcgr.render_iface.render(gfx, pass, draw);
}
// -- end

const limits: lcgr.context.Limits = .{ .nodes = 8, .texts = 2, .customs = 1 };
var buffer: [Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;

test "backends: one frame through the selected back end" {
    comptime std.debug.assert(render.kind == .sw);
    var ctx = try Context.init(&buffer, limits);
    var in: lcgr.input.Input = .{ .viewport = .{ 32, 16 } };
    var f = ctx.begin(&in);
    _ = f.leaf(.from("box"), .{ .size = .{ .fill, .fill }, .fill = .rgb(200, 40, 40) });
    const out = f.end(.{});

    const sw = render.backend;
    var pixels: [sw.Framebuffer.len(32, 16)]u32 = undefined;
    var fb: sw.Framebuffer = .init(&pixels, 32, 16, .rgba8);
    fb.clear(.rgb(0, 0, 0));
    var gfx: render.Renderer = .{};
    // -- pass
    // What a pass is depends on the back end: here a framebuffer and its scissor.
    const pass: render.Pass = switch (render.kind) {
        .sw => .{ .fb = &fb, .scissor = fb.all() },
        else => @compileError("this example draws in software"),
    };
    // -- end
    drawFrame(&gfx, {}, pass, out.draw, .{}, in.viewport, 1);
    try testing.expectEqual(lcgr.types.Color.rgb(200, 40, 40), fb.at(16, 8));
}
