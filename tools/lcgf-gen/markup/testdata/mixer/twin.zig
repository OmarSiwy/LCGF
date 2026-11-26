//! mixer, written by hand (the plan's §3.2 example without the list and the component): a bound
//! heading, a checkbox captioned by its wrapping label, a slider with a range and a name, a
//! formatted gain, a progress bar; on:change handlers on both controls.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const checkbox = lcgf.widgets_checkbox;
const slider = lcgf.widgets_slider;
const progress = lcgf.widgets_progress;

pub const theme: w.Theme = .{};

pub const State = struct { title: []const u8 = "", muted: bool = false, volume: f32 = 0.5, level: f32 = 0 };

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.landmark(.main, .{ .pad = @splat(8), .gap = 4 }, .{
        s.textStyled(s.heading(1, .title), .{ .px = 2 * theme.text_px, .color = theme.text }),
        checkbox.ct.checkbox(theme, .mute, .muted, "Mute"),
        s.named(slider.ct.slider(theme, .volume, .volume, .{ .lo = 0, .hi = 1 }), "Volume"),
        s.text("Gain {.1}", .{.volume}),
        progress.ct.progress(theme, .level),
    }),
});

pub fn Handlers(comptime Ui: type) type {
    return struct {
        mutes: u32 = 0,
        last_mute: bool = false,
        volumes: u32 = 0,

        pub fn mute_changed(h: *@This(), _: *Ui, value: bool) void {
            h.mutes += 1;
            h.last_mute = value;
        }
        pub fn volume_changed(h: *@This(), _: *Ui, _: f32) void {
            h.volumes += 1;
        }
    };
}

/// A click on the checkbox reports one change with the new value; the slider did not move.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    var in: lcgf.input.Input = .{};
    const first = p.frame(h, &in);
    const t = first.tree;
    const r = t.rect(t.find(.from("mute")));
    in.pointer = .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
    in.buttons.left = true;
    _ = p.frame(h, &in);
    in.buttons.left = false;
    _ = p.frame(h, &in);
    _ = page;
    try std.testing.expectEqual(1, h.mutes);
    try std.testing.expect(h.last_mute);
    try std.testing.expectEqual(0, h.volumes);
}
