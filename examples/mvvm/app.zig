//! MVVM (Model-View-ViewModel): `view_model.zig` owns the model and the page and offers commands,
//! `view.zig` binds to them and `model.zig` holds the tasks. There is no presenter or coordinator.

const std = @import("std");
const lcgf = @import("lcgf");
const lcgf_app = @import("lcgf_app");
const view = @import("view.zig");
const ViewModel = @import("view_model.zig").ViewModel;

pub const App = struct {
    theme: lcgf.widgets_base.Theme = .default,
    view_model: ViewModel = .{},

    pub fn build(app: *App, f: *lcgf.frame.Frame, _: *const lcgf.shell_iface.Events) void {
        // A command ran after the view read its projection, so draw again to show it.
        if (view.draw(f, &app.theme, &app.view_model)) f.ctx.waker.post();
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try lcgf_app.run(App, &app, init, .{ .title = "MVVM" });
}

const testing = std.testing;
const replay = lcgf_app.replay;

test "mvvm: the view's clicks run ViewModel commands" {
    var app: App = .{};
    var s = try replay.run(&app, "frame\nviewport 800 600\n");
    const advance = replay.center(s.rect(view.id_advance));
    const open = replay.center(s.rect(view.id_open));

    app = .{};
    var rec: [512]u8 = undefined;
    s = try replay.run(&app, try replay.clicks(&rec, &.{ advance, open }));
    try testing.expectEqualSlices(bool, &.{ true, false, false, false }, &app.view_model.model.done);
    try testing.expectEqual(.open, app.view_model.page);
    try testing.expectEqual(@as(u32, 3), app.view_model.projection().len);
}
