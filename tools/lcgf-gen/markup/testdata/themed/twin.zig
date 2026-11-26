//! themed, written by hand: the card component inlined. It takes the page's theme (`pad` 10
//! from `--lcgf-pad`) and its padding reads the run-time token `space`, so changing the table
//! lays the card out again.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;

pub const theme: w.Theme = .{ .pad = 10 };

pub const Tokens = struct { space: f32 = 6 };

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.tokened(s.col(.{ .gap = theme.pad, .fill = theme.control }, .{label.ct.label(theme, "Inside")}), &.{
        .{ .target = .pad_left, .token = "space" },
        .{ .target = .pad_top, .token = "space" },
        .{ .target = .pad_right, .token = "space" },
        .{ .target = .pad_bottom, .token = "space" },
    }),
});

pub fn Handlers(comptime Ui: type) type {
    _ = Ui;
    return struct {};
}

fn runOf(d: *const lcgf.draw_list.DrawList, text: []const u8) ?[4]f32 {
    for (d.runs[0..d.run_len]) |r| if (std.mem.eql(u8, d.strings[r.start..][0..r.bytes], text)) return r.rect;
    return null;
}

/// The card's padding follows the table: from 6 px to 20 px, its text moves 14 px.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    var table: page.ThemeTable = .{};
    p.ui.tokens = &table;
    const in: lcgf.input.Input = .{};
    const before = runOf(p.frame(h, &in).draw, "Inside").?;
    table.set(.space, 20);
    try std.testing.expect(p.ui.themeChanged());
    const after = runOf(p.frame(h, &in).draw, "Inside").?;
    try std.testing.expectEqual(before[0] + 14, after[0]);
    try std.testing.expectEqual(before[1] + 14, after[1]);
}
