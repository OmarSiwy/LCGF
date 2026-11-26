//! palette, written by hand: a region sized by its content (E1), for menus and palette results.
//! The comptime layout runs before the items exist, so the region takes the size its content
//! measured on the previous frame; a change asks for another frame (`wake = 0`).

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;

pub const theme: w.Theme = .{};

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    lcgf.ct_interop.fitRegion(.each_hits, .{ .gap = 2 }),
    label.ct.label(theme, "Footer"),
});

pub fn Handlers(comptime Ui: type) type {
    _ = Ui;
    return struct {};
}

const Hit = struct { title: []const u8 };

/// The items parity.zig gives both frontends' regions; each side gets its own copy.
pub const Sample = struct {
    hits: [3]Hit = .{ .{ .title = "Open file" }, .{ .title = "Save all" }, .{ .title = "Quit" } },

    pub fn data(x: *Sample) struct { hits: []Hit } {
        return .{ .hits = &x.hits };
    }
};

fn runOf(d: *const lcgf.draw_list.DrawList, text: []const u8) ?[4]f32 {
    for (d.runs[0..d.run_len]) |r| if (std.mem.eql(u8, d.strings[r.start..][0..r.bytes], text)) return r.rect;
    return null;
}

/// The second frame lays the footer out below the region, which is as tall as its three hits.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    const hits = [_]Hit{ .{ .title = "Open file" }, .{ .title = "Save all" }, .{ .title = "Quit" } };
    var in: lcgf.input.Input = .{};
    const first = p.frame(h, &in, .{ .hits = &hits });
    try std.testing.expectEqual(0, first.wake);
    const out = p.frame(h, &in, .{ .hits = &hits });
    try std.testing.expect(out.wake > 0);
    const region = out.tree.rect(out.tree.find(.from("each_hits")));
    const quit = runOf(out.draw, "Quit").?;
    const footer = runOf(out.draw, "Footer").?;
    try std.testing.expect(region.y1 - region.y0 > 3 * (quit[3] - quit[1]));
    try std.testing.expect(footer[1] >= region.y1);
    try std.testing.expect(quit[3] <= region.y1);
}
