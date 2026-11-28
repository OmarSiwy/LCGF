//! MVVP, a project-defined hybrid: Model-View-ViewModel-Presenter. The name has no standard
//! meaning; here `view_model.zig` owns presentation state and the projection, `view.zig` is
//! passive and `presenter.zig` is the only code that changes the model or the page.

const std = @import("std");
const lcgf = @import("lcgf");
const lcgf_app = @import("lcgf_app");
const presenter = @import("presenter.zig");
const view = @import("view.zig");
const Model = @import("model.zig").Model;
const ViewModel = @import("view_model.zig").ViewModel;

pub const App = struct {
    theme: lcgf.widgets_base.Theme = .default,
    model: Model = .{},
    view_model: ViewModel = .{},

    pub fn build(app: *App, f: *lcgf.frame.Frame, _: *const lcgf.shell_iface.Events) void {
        const p = app.view_model.projection(&app.model);
        const action = view.draw(f, &app.theme, &p) orelse return;
        presenter.apply(&app.model, &app.view_model, action);
        // The click is applied after the view drew, so draw again to show it.
        f.ctx.waker.post();
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try lcgf_app.run(App, &app, init, .{ .title = "MVVP" });
}

const testing = std.testing;
const replay = @import("lcgf_replay");

test "mvvp: the presenter applies clicks to the model and the ViewModel's page" {
    var app: App = .{};
    var s = try replay.run(&app, "frame\nviewport 800 600\n");
    const advance = replay.center(s.rect(view.id_advance));
    const open = replay.center(s.rect(view.id_open));

    app = .{};
    var rec: [512]u8 = undefined;
    s = try replay.run(&app, try replay.clicks(&rec, &.{ advance, open }));
    try testing.expectEqualSlices(bool, &.{ true, false, false, false }, &app.model.done);
    try testing.expectEqual(.open, app.view_model.page);
    try testing.expectEqual(@as(u32, 3), app.view_model.projection(&app.model).len);
}
