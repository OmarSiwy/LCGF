//! Compose the title, summary, and controls. The view never mutates domain state.

const std = @import("std");
const lcgf = @import("lcgf");
const w = lcgf.widgets_base;
const Id = lcgf.types.Id;
const Frame = lcgf.frame.Frame;
const Action = @import("entity.zig").Action;
const Model = @import("presenter.zig").Model;
const Commands = @import("../../core/commands.zig").Buffer(Action, 8);
const button = @import("../../ui/button.zig");

pub const id = Id.from("topbar");
pub const theme_id = Id.from("topbar.theme");
pub const advance_id = Id.from("topbar.advance");
pub const sidebar_id = Id.from("topbar.sidebar");

pub fn draw(f: *Frame, theme: *const w.Theme, model: Model, commands: *Commands) error{Full}!void {
    _ = f.open(id, .{
        .dir = .x,
        .size = .{ .fill, .fit },
        .pad = @splat(12),
        .gap = 10,
        .cross = .center,
        .fill = theme.panel,
        .clip = true,
    });
    defer f.close();

    if (button.draw(f, theme, sidebar_id, "Menu").clicked)
        try commands.append(.toggle_sidebar);
    _ = f.text(model.page.title(), .{ .px = 16, .color = theme.text });
    _ = f.leaf(.none, .{ .size = .{ .fill, .px(1) } });

    // LCGF copies text bytes into frame storage, so this scratch buffer can stay on the stack.
    var text: [48]u8 = undefined;
    const summary = std.fmt.bufPrint(&text, "{d}/{d} done", .{ model.completed, model.total }) catch unreachable;
    _ = w.label(f, theme, summary);
    if (button.draw(f, theme, theme_id, if (model.dark) "Light" else "Dark").clicked)
        try commands.append(.toggle_theme);
    if (button.draw(f, theme, advance_id, "Advance").clicked)
        try commands.append(.advance);
}
