//! MVVM-C (MVVM with a coordinator): `view_model.zig` runs feature commands, `coordinator.zig`
//! owns navigation and `view.zig` is passive. This root owns the model and the coordinator and
//! hands the ViewModel's navigation requests to the coordinator.

const std = @import("std");
const lcgf = @import("lcgf");
const view = @import("view.zig");
const view_model = @import("view_model.zig");
const Model = @import("model.zig").Model;
const Coordinator = @import("coordinator.zig").Coordinator;

pub const App = struct {
    theme: lcgf.widgets_base.Theme = .default,
    model: Model = .{},
    coordinator: Coordinator = .{},

    pub fn build(app: *App, f: *lcgf.frame.Frame, _: *const lcgf.shell_iface.Events) void {
        const p = view_model.projection(&app.model, app.coordinator.page);
        const action = view.draw(f, &app.theme, &p) orelse return;
        if (view_model.command(&app.model, action)) |page| app.coordinator.show(page);
        // The click is applied after the view drew, so draw again to show it.
        f.ctx.waker.post();
    }
};

const testing = std.testing;
const host = @import("host");

test "mvvm-c: the ViewModel advances the model and the coordinator takes the navigation" {
    var app: App = .{};
    var s = try host.Smoke.run(&app, "frame\nviewport 800 600\n");
    const advance = host.center(s.rect(view.id_advance));
    const open = host.center(s.rect(view.id_open));

    app = .{};
    var rec: [512]u8 = undefined;
    s = try host.Smoke.run(&app, try host.clicks(&rec, &.{ advance, open }));
    try testing.expectEqualSlices(bool, &.{ true, false, false, false }, &app.model.done);
    try testing.expectEqual(.open, app.coordinator.page);
    // The ViewModel only asks; it does not navigate.
    try testing.expectEqual(.all, view_model.command(&app.model, .{ .show = .all }).?);
    try testing.expectEqual(.open, app.coordinator.page);
}
