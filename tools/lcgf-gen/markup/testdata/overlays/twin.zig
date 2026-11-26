//! overlays, written by hand: a select with a group of options, a button's tooltip (title=),
//! a dialog of any content, a popover and a menu (engine spec F10), each moved last into a
//! root over the viewport so they float from its origin and draw above the page.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const button = lcgf.widgets_button;
const checkbox = lcgf.widgets_checkbox;
const dialog = lcgf.widgets_dialog;
const label = lcgf.widgets_label;
const select = lcgf.widgets_select;
const tooltip = lcgf.widgets_tooltip;
const popover = lcgf.widgets_popover;
const menu = lcgf.widgets_menu;

pub const theme: w.Theme = .{};

pub const State = struct {
    shape: select.SelectState = .{ .selected = 1 },
    settings_tip: tooltip.Tip = .{},
    prefs_open: bool = true,
    snap: bool = false,
    info_open: bool = false,
    edit_menu: menu.MenuState = .{},
};

const edit: menu.Def = .{ .items = &.{ "undo", "redo" } };

const shapes: select.Options = .{ .texts = &.{ "Circle", "Square", "Tri" }, .groups = &.{.{ .at = 1, .label = "Angular" }} };

pub const spec = s.col(.{ .size = .{ .fill, .fill } }, .{
    s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
        s.row(.{ .pad = @splat(8), .gap = 8 }, .{
            s.named(select.ct.select(theme, .shape, .shape, shapes), "Shape"),
            button.ct.button(theme, .settings, "Settings"),
            popover.ct.button(theme, .info, .info_open, "Info"),
            menu.ct.button(theme, .edit, .edit_menu, edit, "Edit"),
        }),
    }),
    select.ct.list(theme, .shape, .shape, shapes),
    tooltip.ct.tooltip(theme, .settings, .settings_tip, "Open the preferences"),
    dialog.ct.dialog(theme, .prefs, .prefs_open, .{
        label.ct.label(theme, "Preferences"),
        checkbox.ct.checkbox(theme, .snap, .snap, "Snap"),
        button.ct.button(theme, .done, "Done"),
    }),
    popover.ct.popover(theme, .info, .info_open, .{label.ct.label(theme, "Version 1")}),
    menu.ct.list(theme, .edit, .edit_menu, edit, &.{ "Undo", "Redo" }),
});

pub const names = .{"Shape"};

/// The dialog starts open: Tab inside it, a press on its backdrop (nothing), Escape; then the
/// select: open it, Down to Tri, Enter, and a click on Circle; then the pointer rests on
/// Settings until its tooltip shows, and Escape hides it; Info opens its popover, and a
/// press outside closes it; Edit opens its menu, Down moves, and a click chooses.
pub const replay =
    \\frame
    \\viewport 800 600
    \\pointer 400 300
    \\frame
    \\frame
    \\press 43
    \\frame
    \\pointer 60 25
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\press 41
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\press 81
    \\frame
    \\press 40
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 60 65
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 170 25
    \\dt 0.3
    \\frame
    \\frame
    \\frame
    \\press 41
    \\frame
    \\dt 0.016
    \\pointer 252 25
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 252 70
    \\frame
    \\pointer 700 500
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\pointer 310 25
    \\buttons left
    \\frame
    \\buttons
    \\frame
    \\press 81
    \\frame
    \\pointer 310 85
    \\frame
    \\buttons left
    \\frame
    \\buttons
    \\frame
;

pub fn Handlers(comptime Ui: type) type {
    return struct {
        shapes: u32 = 0,
        last: u32 = 99,
        undos: u32 = 0,
        redos: u32 = 0,

        pub fn shape_changed(h: *@This(), _: *Ui, value: u32) void {
            h.shapes += 1;
            h.last = value;
        }
        pub fn undo(h: *@This(), _: *Ui) void {
            h.undos += 1;
        }
        pub fn redo_it(h: *@This(), _: *Ui) void {
            h.redos += 1;
        }
        pub fn open_settings(_: *@This(), ui: *Ui) void {
            ui.signals.set(.prefs_open, true);
        }
        pub fn close_settings(_: *@This(), ui: *Ui) void {
            ui.signals.set(.prefs_open, false);
        }
    };
}

/// Through the spec frontend's Page: Escape closes the dialog, Settings opens it, Done closes
/// it; the select's choice by keys reaches on:change; Settings' tooltip shows.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    var in: lcgf.input.Input = .{ .viewport = .{ 800, 600 } };
    _ = p.frame(h, &in);
    const esc = [_]lcgf.input.Input.Event{.{ .kind = .press, .code = 0x29 }};
    in.events = &esc;
    _ = p.frame(h, &in);
    in.events = &.{};
    try std.testing.expect(!p.ui.signals.state.prefs_open);
    try click(p, h, &in, "settings");
    try std.testing.expect(p.ui.signals.state.prefs_open);
    _ = p.frame(h, &in);
    try click(p, h, &in, "done");
    try std.testing.expect(!p.ui.signals.state.prefs_open);
    try click(p, h, &in, "shape");
    try std.testing.expect(p.ui.signals.state.shape.menu.open);
    const down_enter = [_]lcgf.input.Input.Event{ .{ .kind = .press, .code = 0x51 }, .{ .kind = .press, .code = 0x28 } };
    in.events = &down_enter;
    _ = p.frame(h, &in);
    in.events = &.{};
    try std.testing.expectEqual(@as(u32, 1), h.shapes);
    try std.testing.expectEqual(@as(u32, 2), h.last);
    // Resting on Settings for the tooltip's delay shows its tip.
    const t = p.frame(h, &in).tree;
    const r = t.rect(t.find(.from("settings")));
    in.pointer = .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
    in.dt = lcgf.widgets_tooltip.delay;
    _ = p.frame(h, &in);
    _ = p.frame(h, &in);
    try std.testing.expect(p.ui.signals.state.settings_tip.shown);
    // Info opens its popover; a press outside closes it.
    in.dt = 0;
    try click(p, h, &in, "info");
    try std.testing.expect(p.ui.signals.state.info_open);
    in.pointer = .{ 700, 500 };
    in.buttons.left = true;
    _ = p.frame(h, &in);
    in.buttons.left = false;
    _ = p.frame(h, &in);
    try std.testing.expect(!p.ui.signals.state.info_open);
    // Edit opens its menu; Down and Enter choose Redo, a click on Undo chooses Undo.
    try click(p, h, &in, "edit");
    try std.testing.expect(p.ui.signals.state.edit_menu.open);
    const keys = [_]lcgf.input.Input.Event{ .{ .kind = .press, .code = 0x51 }, .{ .kind = .press, .code = 0x28 } };
    in.events = &keys;
    _ = p.frame(h, &in);
    in.events = &.{};
    try std.testing.expectEqual(@as(u32, 1), h.redos);
    try click(p, h, &in, "edit");
    try click(p, h, &in, "edit_undo");
    try std.testing.expectEqual(@as(u32, 1), h.undos);
    try std.testing.expect(!p.ui.signals.state.edit_menu.open);
}

fn click(p: anytype, h: anytype, in: *lcgf.input.Input, comptime id: []const u8) !void {
    const t = p.frame(h, in).tree;
    const r = t.rect(t.find(.from(id)));
    in.pointer = .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
    in.buttons.left = true;
    _ = p.frame(h, in);
    in.buttons.left = false;
    _ = p.frame(h, in);
}
