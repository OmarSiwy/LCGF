//! runtime, written by hand: a page that asks for the runtime frontend
//! (`<html lcgf-frontend="runtime">`). Its spec, which both frontends share, and its handlers,
//! which are the same code in both (`ui.signals`).

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const button = lcgf.widgets_button;
const slider = lcgf.widgets_slider;
const label = lcgf.widgets_label;

pub const theme: w.Theme = .{};

pub const State = struct { level: f32 = 0, view: enum { small, large } = .small };

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.row(.{ .pad = @splat(4), .gap = 6 }, .{
        button.ct.button(theme, .less, "Less"),
        button.ct.button(theme, .more, "More"),
        s.textStyled(s.text("{.2}", .{.level}), .{ .px = theme.text_px, .color = .rgb(0x80, 0xc0, 0xff) }),
    }),
    slider.ct.slider(theme, .level, .level, .{}),
    s.choice(.view, .{}, .{
        label.ct.label(theme, "Small"),
        s.col(.{}, .{label.ct.label(theme, "Large")}),
    }),
});

pub fn Handlers(comptime Ui: type) type {
    return struct {
        changes: u32 = 0,

        pub fn less(_: *@This(), ui: *Ui) void {
            ui.signals.set(.level, @max(0, ui.signals.state.level - 0.25));
        }
        pub fn more(_: *@This(), ui: *Ui) void {
            ui.signals.set(.level, @min(1, ui.signals.state.level + 0.25));
            ui.signals.set(.view, .large);
        }
        pub fn level_changed(h: *@This(), _: *Ui, _: f32) void {
            h.changes += 1;
        }
    };
}

/// Clicks on More through the spec frontend's Page; the runtime one is in parity.zig.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    var in: lcgf.input.Input = .{};
    const t = p.frame(h, &in).tree;
    const r = t.rect(t.find(.from("more")));
    in.pointer = .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
    in.buttons.left = true;
    _ = p.frame(h, &in);
    in.buttons.left = false;
    _ = p.frame(h, &in);
    _ = page;
    try std.testing.expectEqual(0.25, p.ui.signals.state.level);
    try std.testing.expectEqualStrings("large", @tagName(p.ui.signals.state.view));
}
