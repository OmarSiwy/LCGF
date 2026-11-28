//! MVP (Model-View-Presenter): `model.zig` owns all state, `view.zig` is passive and
//! `presenter.zig` moves data between them. This root only owns the model and the theme.

const std = @import("std");
const lcgf = @import("lcgf");
const lcgf_app = @import("lcgf_app");
const presenter = @import("presenter.zig");
const view = @import("view.zig");
const Model = @import("model.zig").Model;

pub const App = struct {
    theme: lcgf.widgets_base.Theme = .default,
    model: Model = .{},

    pub fn build(app: *App, f: *lcgf.frame.Frame, _: *const lcgf.shell_iface.Events) void {
        // The click is applied after the view drew, so draw again to show it.
        if (presenter.build(&app.model, f, &app.theme)) f.ctx.waker.post();
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try lcgf_app.run(App, &app, init, .{ .title = "MVP" });
}

const testing = std.testing;
const replay = lcgf_app.replay;

test "mvp: clicks reach the model through the presenter" {
    var app: App = .{};
    var s = try replay.run(&app, "frame\nviewport 800 600\n");
    const advance = replay.center(s.rect(view.id_advance));
    const open = replay.center(s.rect(view.id_open));

    app = .{};
    var rec: [512]u8 = undefined;
    s = try replay.run(&app, try replay.clicks(&rec, &.{ advance, open }));
    try testing.expectEqualSlices(bool, &.{ true, false, false, false }, &app.model.done);
    try testing.expectEqual(.open, app.model.page);
}
