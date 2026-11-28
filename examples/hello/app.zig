//! Hello window: the smallest application. One panel in the middle of the window with a
//! greeting and a button, built from the public widgets. `zig build run` opens it through
//! `lcgf_app`; `zig build test` plays recordings into it without a window.

const std = @import("std");
const lcgf = @import("lcgf");
const w = lcgf.widgets_base;
const Frame = lcgf.frame.Frame;
const Id = lcgf.types.Id;
const Events = lcgf.shell_iface.Events;
const lcgf_app = @import("lcgf_app");

pub const id_panel = Id.from("hello");
pub const id_wave = Id.from("wave");

pub const App = struct {
    theme: w.Theme = .default,
    waves: u32 = 0,

    /// The whole UI. Runs top to bottom every frame; nothing calls back into it.
    pub fn build(app: *App, f: *Frame, _: *const Events) void {
        const th = &app.theme;
        _ = f.open(.from("center"), .{ .size = .{ .fill, .fill }, .main = .center, .cross = .center });
        _ = f.open(id_panel, .{ .pad = @splat(16), .gap = 8, .cross = .center, .fill = th.panel, .radius = th.radius });
        // The widget kit: the theme given once, options by name, text formatted in place.
        const ui = lcgf.widgets.on(f, th);
        _ = ui.label("Hello, window");
        if (ui.button(.wave, .{ .label = "Wave" }).clicked) app.waves += 1;
        _ = ui.text("Waved {d} times", .{app.waves});
        f.close();
        f.close();
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try lcgf_app.run(App, &app, init, .{ .title = "Hello" });
}

const testing = std.testing;
const replay = @import("lcgf_replay");

test "hello: builds, draws a centred panel and its text, and a click on Wave counts" {
    var app: App = .{};
    // First frame: lay out, to find the button.
    var s = try replay.run(&app, "frame\nviewport 800 600\n");
    const panel = s.rect(id_panel);
    try testing.expectApproxEqAbs(@as(f32, 400), (panel.x0 + panel.x1) / 2, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 300), (panel.y0 + panel.y1) / 2, 0.5);
    try testing.expectEqual(app.theme.panel, s.at(@intFromFloat(panel.x0 + 4), @intFromFloat(panel.y0 + 4)));
    // The title's first glyph cell is drawn in the text colour (the headless shell draws a
    // glyph as its cell).
    const title = s.out.?.draw.runs[0].rect;
    try testing.expectEqual(app.theme.text, s.at(@intFromFloat(title[0] + 2), @intFromFloat(title[1] + 5)));

    var rec: [256]u8 = undefined;
    const click = try replay.clicks(&rec, &.{replay.center(s.rect(id_wave))});
    app = .{};
    s = try replay.run(&app, click);
    try testing.expectEqual(@as(u32, 1), app.waves);
    try testing.expectEqual(@as(u32, 5), s.shell.polls);
}
