//! MVP (Model-View-Presenter): `model.zig` owns all state, `view.zig` is passive and
//! `presenter.zig` moves data between them. This root only owns the model and the theme.

const std = @import("std");
const lcgf = @import("lcgf");
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

const testing = std.testing;
const host = @import("host");

test "mvp: clicks reach the model through the presenter" {
    var app: App = .{};
    var s = try host.Smoke.run(&app, "frame\nviewport 800 600\n");
    const advance = host.center(s.rect(view.id_advance));
    const open = host.center(s.rect(view.id_open));

    app = .{};
    var rec: [512]u8 = undefined;
    s = try host.Smoke.run(&app, try host.clicks(&rec, &.{ advance, open }));
    try testing.expectEqualSlices(bool, &.{ true, false, false, false }, &app.model.done);
    try testing.expectEqual(.open, app.model.page);
}
