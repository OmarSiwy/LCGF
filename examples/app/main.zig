//! The hello window through `lcgf_app`: one call opens a window on the desktop (Wayland or X11
//! on Linux, Win32, macOS) and runs the application in it until it is closed.
//!
//!     zig build app-example && zig-out/bin/app-example
//!     zig build app-example -Dtarget=x86_64-windows     (or aarch64-macos)
//!
//! `LCGF_APP_SECONDS=1` closes it after a second (ci/run.sh runs it so on Xvfb).

const std = @import("std");
const lcgf = @import("lcgf");
const lcgf_app = @import("lcgf_app");

const App = struct {
    /// Follows the system's light or dark appearance (`lcgf_app` sets it).
    theme: lcgf.widgets_base.Theme = .default,
    waves: u32 = 0,
    volume: f32 = 0.5,
    glow: lcgf.types.Color = .rgb(90, 140, 255),

    pub fn build(app: *App, f: *lcgf.frame.Frame, _: *const lcgf.shell_iface.Events) void {
        const th = &app.theme;
        _ = f.open(.from("center"), .{ .size = .{ .fill, .fill }, .main = .center, .cross = .center });
        _ = f.open(.from("panel"), .{ .pad = @splat(16), .gap = 8, .cross = .center, .fill = th.panel, .radius = th.radius });
        const ui = lcgf.widgets.on(f, th);
        _ = ui.label("Hello, window");
        if (ui.button(.wave, .{ .label = "Wave" }).clicked) app.waves += 1;
        _ = ui.text("Waved {d} times", .{app.waves});
        _ = ui.slider(.volume, &app.volume, .{ .min = 0, .max = 1 });
        // A colour on springs: it eases to the next one after each wave.
        const target: lcgf.types.Color = if (app.waves % 2 == 0) .rgb(90, 140, 255) else .rgb(255, 140, 90);
        app.glow = f.animate(.from("glow"), target, .{});
        _ = f.leaf(.from("swatch"), .{ .size = .{ .px(120), .px(8) }, .fill = app.glow, .radius = 4 });
        f.close();
        f.close();
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try lcgf_app.run(App, &app, init, .{ .title = "Hello", .size = .{ 480, 320 } });
}
