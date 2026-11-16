//! The examples of docs/guide/runtime.md, compiled and run by `zig build docs`. Every ```zig
//! block of the guide is a verbatim piece of this file (docs/guide/snippets.py checks that).

const std = @import("std");
const testing = std.testing;
const lcgr = @import("lcgr");

// -- memory
const Context = lcgr.context.Context;
const limits: lcgr.context.Limits = .{ .nodes = 256, .texts = 64, .customs = 4 };
var buffer: [Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;
// -- end

// -- build
const Frame = lcgr.frame.Frame;
const Id = lcgr.types.Id;
const w = lcgr.widgets_base;

const App = struct {
    theme: w.Theme = .default,
    resets: u32 = 0,
    wireframe: bool = false,
    exposure: f32 = 1,
    layers: lcgr.runtime_signals.Cell(u32),
    sidebar_builds: u32 = 0,

    fn build(app: *App, f: *Frame) void {
        const th = &app.theme;
        _ = f.open(.from("toolbar"), .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .fill = th.panel });
        if (w.button(f, th, .from("reset"), "Reset").clicked) app.resets += 1;
        _ = w.checkbox(f, th, .from("wire"), &app.wireframe, "Wireframe");
        _ = w.slider(f, th, .from("exposure"), &app.exposure, 0, 4);
        f.close();

        _ = f.open(.from("body"), .{ .dir = .x, .size = .{ .fill, .fill } });
        // Rebuilt only when `layers` changes or the pointer is on one of its widgets.
        if (!f.reuse(.from("sidebar"), &.{app.layers.signal})) {
            app.sidebar_builds += 1;
            _ = f.open(.from("sidebar"), .{ .size = .{ .px(160), .fill }, .pad = @splat(8), .gap = 4 });
            var name: [24]u8 = undefined;
            for (0..app.layers.get()) |i| {
                _ = w.label(f, th, std.fmt.bufPrint(&name, "Layer {d}", .{i}) catch "?");
            }
            f.close();
        }
        // The UI only reserves this rect; the host draws into it.
        _ = f.custom(.from("viewport"), .{ .size = .{ .fill, .fill } }, 0);
        f.close();
    }
};
// -- end

// -- widget
/// A widget is a function over `Frame`: build its nodes, ask what input did to them.
fn swatch(f: *Frame, id: Id, color: *lcgr.types.Color, other: lcgr.types.Color) bool {
    const node = f.leaf(id, .{ .size = .{ .px(24), .px(24) }, .radius = 4, .fill = color.*, .role = .button });
    const r = f.interact(node, .button);
    f.setCursor(.pointer, r.hovered);
    if (r.clicked) color.* = other;
    return r.clicked;
}
// -- end

fn center(r: lcgr.types.Rect) [2]f32 {
    return .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
}

test "host loop: init, frames, idle, click" {
    // -- init
    var ctx = try Context.init(&buffer, limits);
    var app: App = .{ .layers = .init(&ctx.signals, 3) };
    var in: lcgr.input.Input = .{ .viewport = .{ 800, 600 } };
    // -- end
    var frames: u32 = 0;
    var customs: u32 = 0;
    var viewport: [4]f32 = @splat(0);
    var out: lcgr.context.Output = undefined;
    for (0..3) |_| {
        // -- loop
        if (ctx.needsFrame(&in)) {
            var f = ctx.begin(&in);
            app.build(&f);
            out = f.end(.{}); // measure with the built-in monospace font, lay out, paint
            frames += 1;

            for (0..out.draw.cmd_len) |i| switch (out.draw.command(@intCast(i))) {
                .quads => |batch| _ = batch, // renderer.drawBatch(pass, batch)
                .text => |run| _ = run, // renderer.drawText(pass, run)
                .custom => |k| { // your own pipeline, in paint order
                    customs += 1;
                    viewport = out.draw.customs[k].rect;
                },
            };
        }
        // -- end
    }
    // One frame, one settle frame, then idle.
    try testing.expectEqual(2, frames);
    try testing.expectEqual(lcgr.types.inf, out.wake);
    try testing.expect(out.status.ok());
    try testing.expectEqual([4]f32{ 160, 50, 800, 600 }, viewport);
    try testing.expectEqual(1, app.sidebar_builds);

    // A click is a press and a release over the button, found in last frame's geometry.
    in.pointer = center(out.tree.rect(out.tree.find(.from("reset"))));
    for ([_]bool{ false, true, false }) |down| {
        in.buttons.left = down;
        var f = ctx.begin(&in);
        app.build(&f);
        out = f.end(.{});
    }
    try testing.expectEqual(1, app.resets);

    // A changed signal wakes the host and rebuilds the sidebar once.
    in.pointer = .{ 700, 500 };
    {
        var f = ctx.begin(&in);
        app.build(&f);
        _ = f.end(.{});
    }
    const builds = app.sidebar_builds;
    // -- signal
    app.layers.set(&ctx.signals, 5); // wakes the host: needsFrame is now true
    // -- end
    try testing.expect(ctx.needsFrame(&in));
    var f = ctx.begin(&in);
    app.build(&f);
    _ = f.end(.{});
    try testing.expectEqual(builds + 1, app.sidebar_builds);
}

test "a widget of your own" {
    const S = struct {
        var buf: [Context.requiredBytes(.{ .nodes = 16, .texts = 4, .customs = 1 })]u8 align(lcgr.mem.column_align) = undefined;
    };
    var ctx = try Context.init(&S.buf, .{ .nodes = 16, .texts = 4, .customs = 1 });
    var color: lcgr.types.Color = .rgb(200, 0, 0);
    var in: lcgr.input.Input = .{ .viewport = .{ 100, 100 }, .pointer = .{ 12, 12 } };
    var clicked = false;
    for ([_]bool{ false, true, false }) |down| {
        in.buttons.left = down;
        var f = ctx.begin(&in);
        clicked = swatch(&f, .from("swatch"), &color, .rgb(0, 0, 200));
        _ = f.end(.{});
    }
    try testing.expect(clicked);
    try testing.expectEqual(lcgr.types.Color.rgb(0, 0, 200), color);
}
