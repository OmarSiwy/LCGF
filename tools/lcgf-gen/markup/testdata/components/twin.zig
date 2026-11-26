//! components, written by hand: the page with each app component's body inlined. A spec
//! component is a function returning a `Spec`, so the page equals the inline page; the
//! component inside the lcgf-each region is the runtime form, built once per item.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const button = lcgf.widgets_button;
const label = lcgf.widgets_label;

pub const theme: w.Theme = .{};

pub const State = struct { gain: f32 = 0 };

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.row(.{ .gap = 4 }, .{ label.ct.label(theme, "Gain"), lcgf.widgets_progress.ct.progress(theme, .gain) }),
    lcgf.widgets_slider.ct.slider(theme, .gain, .gain, .{}),
    s.col(.{ .gap = 2, .pad = @splat(4) }, .{
        label.ct.label(theme, "Tools"),
        s.row(.{ .gap = 4 }, .{ button.ct.button(theme, .save, "Save"), button.ct.button(theme, .zoom, "+") }),
    }),
    lcgf.ct_interop.region(.each_nets, .{ .size = .{ .px(300), .px(120) }, .gap = 2 }),
});

pub fn Handlers(comptime Ui: type) type {
    return struct {
        saves: u32 = 0,
        zooms: u32 = 0,
        picked: ?u32 = null,

        pub fn save(h: *@This(), _: *Ui) void {
            h.saves += 1;
        }
        pub fn zoom(h: *@This(), _: *Ui) void {
            h.zooms += 1;
        }
        pub fn pick(h: *@This(), _: *Ui, index: u32) void {
            h.picked = index;
        }
    };
}

const Net = struct { name: []const u8 };

fn runOf(d: *const lcgf.draw_list.DrawList, text: []const u8) ?[4]f32 {
    for (d.runs[0..d.run_len]) |r| if (std.mem.eql(u8, d.strings[r.start..][0..r.bytes], text)) return r.rect;
    return null;
}

fn click(p: anytype, h: anytype, in: *lcgf.input.Input, nets: []const Net, at: [4]f32) void {
    in.pointer = .{ (at[0] + at[2]) / 2, (at[1] + at[3]) / 2 };
    in.buttons.left = true;
    _ = p.frame(h, in, .{ .nets = nets });
    in.buttons.left = false;
    _ = p.frame(h, in, .{ .nets = nets });
}

/// A click on the component's button reaches the page's `zoom`; a click on a region row
/// built by the runtime component reaches `pick` with the item's index.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    const nets: []const Net = &.{ .{ .name = "vdd" }, .{ .name = "gnd" } };
    var in: lcgf.input.Input = .{};
    const out = p.frame(h, &in, .{ .nets = nets });
    const plus = runOf(out.draw, "+").?;
    const gnd = runOf(out.draw, "gnd").?;
    click(p, h, &in, nets, plus);
    try std.testing.expectEqual(1, h.zooms);
    try std.testing.expectEqual(0, h.saves);
    click(p, h, &in, nets, gnd);
    try std.testing.expectEqual(@as(?u32, 1), h.picked);
}
