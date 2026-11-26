//! VIPER (View-Interactor-Presenter-Entity-Router): the composition root. It owns the entity and
//! the router and wires the view to the presenter; each file in this directory is one VIPER part.

const std = @import("std");
const lcgf = @import("lcgf");
const presenter = @import("presenter.zig");
const view = @import("view.zig");
const Tasks = @import("entity.zig").Tasks;
const Router = @import("router.zig").Router;

pub const App = struct {
    theme: lcgf.widgets_base.Theme = .default,
    tasks: Tasks = .{},
    router: Router = .{},

    pub fn build(app: *App, f: *lcgf.frame.Frame, _: *const lcgf.shell_iface.Events) void {
        const p = presenter.projection(&app.tasks, app.router.page);
        const action = view.draw(f, &app.theme, &p) orelse return;
        presenter.handle(action, &app.tasks, &app.router);
        // The click is applied after the view drew, so draw again to show it.
        f.ctx.waker.post();
    }
};

const testing = std.testing;
const host = @import("host");

test "viper: the presenter sends Advance to the interactor and Open to the router" {
    var app: App = .{};
    var s = try host.Smoke.run(&app, "frame\nviewport 800 600\n");
    const advance = host.center(s.rect(view.id_advance));
    const open = host.center(s.rect(view.id_open));

    app = .{};
    var rec: [512]u8 = undefined;
    s = try host.Smoke.run(&app, try host.clicks(&rec, &.{ advance, open }));
    try testing.expectEqualSlices(bool, &.{ true, false, false, false }, &app.tasks.done);
    try testing.expectEqual(.open, app.router.page);
    try testing.expectEqual(@as(u32, 3), presenter.projection(&app.tasks, app.router.page).len);
}
