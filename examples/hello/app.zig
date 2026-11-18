//! Hello window: the smallest application. One panel in the middle of the window with a
//! greeting and a button, built from the public widgets the way prototype/example.zig `buildUi`
//! builds its toolbar. `zig build examples` runs the smoke test below and builds
//! zig-out/bin/example-hello, this application in an X11 window (src/example/window.zig).

const std = @import("std");
const lcgf = @import("lcgf");
const w = lcgf.widgets_base;
const Frame = lcgf.frame.Frame;
const Id = lcgf.types.Id;
const Events = lcgf.shell_iface.Events;

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
        _ = w.label(f, th, "Hello, window");
        if (w.button(f, th, id_wave, "Wave").clicked) app.waves += 1;
        var buf: [32]u8 = undefined;
        _ = w.label(f, th, std.fmt.bufPrint(&buf, "Waved {d} times", .{app.waves}) catch "?");
        f.close();
        f.close();
    }
};

const testing = std.testing;
const host = @import("host");
const Smoke = host.Smoke;

test "hello: builds, draws a centred panel, and a click on Wave counts" {
    var app: App = .{};
    // First frame: lay out, to find the button.
    var s = try Smoke.run(&app, "frame\nviewport 800 600\n");
    const panel = s.rect(id_panel);
    try testing.expectApproxEqAbs(@as(f32, 400), (panel.x0 + panel.x1) / 2, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 300), (panel.y0 + panel.y1) / 2, 0.5);
    try testing.expectEqual(app.theme.panel, s.at(@intFromFloat(panel.x0 + 4), @intFromFloat(panel.y0 + 4)));

    // The H has two stems, a crossbar and panel-coloured space between the stems.
    const title = s.out.?.draw.runs[0].rect;
    const x: u32 = @intFromFloat(title[0]);
    const y: u32 = @intFromFloat(title[1]);
    try testing.expect(s.at(x + 2, y + 5).r > 128);
    try testing.expect(s.at(x + 7, y + 5).r > 100);
    try testing.expect(s.at(x + 4, y + 8).r > 128);
    try testing.expectEqual(app.theme.panel, s.at(x + 4, y + 5));
    try testing.expectEqual(app.theme.panel, s.at(x + 4, y + 10));

    var rec: [256]u8 = undefined;
    const click = try host.clicks(&rec, &.{host.center(s.rect(id_wave))});
    app = .{};
    s = try Smoke.run(&app, click);
    try testing.expectEqual(@as(u32, 1), app.waves);
    try testing.expectEqual(@as(u32, 5), s.frames);
}
