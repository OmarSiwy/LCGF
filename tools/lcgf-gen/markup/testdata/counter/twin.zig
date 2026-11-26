//! counter, written by hand (examples/counter's layout as a comptime page): two buttons and a
//! formatted count in a row, a bound summary under it; the theme's accent and control colours
//! set from CSS tokens.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const button = lcgf.widgets_button;
const label = lcgf.widgets_label;

pub const theme: w.Theme = .{ .control = .rgb(40, 44, 52), .accent = .rgb(255, 136, 0) };

pub const State = struct { count: f32 = 0, summary: []const u8 = "" };

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.row(.{ .size = .{ .pct(1), .fit }, .pad = @splat(16), .gap = 8, .cross = .center }, .{
        button.ct.button(theme, .dec, "-"),
        button.ct.button(theme, .inc, "+"),
        s.textStyled(s.text("Count: {.0}", .{.count}), .{ .px = theme.text_px, .color = .rgb(255, 204, 0) }),
    }),
    s.styled(label.ct.label(theme, .summary), .{ .pad = @splat(16), .fill = theme.control, .radius = 4, .cursor = .pointer, .role = .label }),
});

pub fn Handlers(comptime Ui: type) type {
    return struct {
        pub fn dec(_: *@This(), ui: *Ui) void {
            ui.signals.set(.count, ui.signals.state.count - 1);
        }
        pub fn inc(_: *@This(), ui: *Ui) void {
            ui.signals.set(.count, ui.signals.state.count + 1);
        }
    };
}

/// Clicks + twice and - once through the generated `Page`.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    var in: lcgf.input.Input = .{};
    const first = p.frame(h, &in);
    const t = first.tree;
    const inc = t.rect(t.find(.from("inc")));
    const dec = t.rect(t.find(.from("dec")));
    for ([_]lcgf.types.Rect{ inc, inc, dec }) |r| {
        in.pointer = .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
        in.buttons.left = true;
        _ = p.frame(h, &in);
        in.buttons.left = false;
        _ = p.frame(h, &in);
    }
    _ = page;
    try std.testing.expectEqual(1, p.ui.signals.state.count);
}
