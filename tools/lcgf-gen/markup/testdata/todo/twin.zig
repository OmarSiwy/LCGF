//! todo, written by hand: the static regions. lcgf-if is `spec.when`, a bounded lcgf-each is
//! `spec.list`, lcgf-switch with its cases is `spec.choice` over a generated enum.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;
const checkbox = lcgf.widgets_checkbox;

pub const theme: w.Theme = .{};

pub const State = struct { show_done: bool = false, count: u32 = 0, mode: enum { compact, detailed } = .compact };

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    checkbox.ct.checkbox(theme, .show, .show_done, "Show done"),
    s.when(.show_done, label.ct.label(theme, "Done items are shown")),
    s.list(.count, 3, .{ .gap = 2 }, s.col(.{}, .{label.ct.label(theme, "Item")})),
    s.choice(.mode, .{}, .{
        label.ct.label(theme, "Compact"),
        s.col(.{}, .{label.ct.label(theme, "Detailed")}),
    }),
});

pub fn Handlers(comptime Ui: type) type {
    return struct {
        pub const Page = Ui;
    };
}

/// The regions follow the state: two of three copies, the detailed alternative, the note.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    const in: lcgf.input.Input = .{};
    const before = p.frame(h, &in).tree.len;
    p.ui.signals.set(.count, 2);
    p.ui.signals.set(.mode, .detailed);
    p.ui.signals.set(.show_done, true);
    const after = p.frame(h, &in).tree.len;
    _ = page;
    // + the note, + two items (col and label each), the detailed col beside its label.
    try std.testing.expectEqual(before + 1 + 4 + 1, after);
}
