//! todo, written by hand: the static regions. lcgf-if is `spec.when`, a bounded lcgf-each is
//! `spec.list`, lcgf-switch with its cases is `spec.choice` over a generated enum, and
//! lcgf-if with lcgf-else is `spec.choice` over the bool, its false alternative first.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;
const checkbox = lcgf.widgets_checkbox;

pub const theme: w.Theme = .{};

pub const State = struct { show_done: bool = false, count: u32 = 0, mode: enum { compact, detailed } = .compact, busy: bool = false };

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    checkbox.ct.checkbox(theme, .show, .show_done, "Show done"),
    s.when(.show_done, label.ct.label(theme, "Done items are shown")),
    s.list(.count, 3, .{ .gap = 2 }, s.col(.{}, .{label.ct.label(theme, "Item")})),
    s.choice(.mode, .{}, .{
        label.ct.label(theme, "Compact"),
        s.col(.{}, .{label.ct.label(theme, "Detailed")}),
    }),
    s.choice(.busy, .{}, .{ label.ct.label(theme, "Saved"), label.ct.label(theme, "Saving") }),
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
    // lcgf-if="busy" with lcgf-else: one alternative at a time.
    try std.testing.expect(drawn(p.frame(h, &in).draw, "Saved") and !drawn(p.frame(h, &in).draw, "Saving"));
    p.ui.signals.set(.busy, true);
    try std.testing.expect(drawn(p.frame(h, &in).draw, "Saving") and !drawn(p.frame(h, &in).draw, "Saved"));
}

fn drawn(d: *const lcgf.draw_list.DrawList, text: []const u8) bool {
    for (d.runs[0..d.run_len]) |r| if (std.mem.eql(u8, d.strings[r.start..][0..r.bytes], text)) return true;
    return false;
}
