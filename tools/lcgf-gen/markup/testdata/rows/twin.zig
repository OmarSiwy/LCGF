//! rows, written by hand: per-item view state inside a run-time region. The checkbox binds the
//! item's `selected` and the details show while the item's `expanded` holds; both fields are
//! the app's, written through the mutable slice it passes.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;

pub const theme: w.Theme = .{};

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    lcgf.ct_interop.region(.each_rows, .{ .size = .{ .px(400), .px(300) }, .gap = 2 }),
});

pub fn Handlers(comptime Ui: type) type {
    _ = Ui;
    return struct {};
}

const Row = struct { name: []const u8, detail: []const u8, selected: bool = false, expanded: bool = false };

fn runOf(d: *const lcgf.draw_list.DrawList, text: []const u8) ?[4]f32 {
    for (d.runs[0..d.run_len]) |r| if (std.mem.eql(u8, d.strings[r.start..][0..r.bytes], text)) return r.rect;
    return null;
}

/// A click on row 1's checkbox selects that item only; an expanded item shows its details.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    var rows = [_]Row{ .{ .name = "one", .detail = "first" }, .{ .name = "two", .detail = "second" } };
    var in: lcgf.input.Input = .{};
    var out = p.frame(h, &in, .{ .rows = &rows });
    try std.testing.expect(runOf(out.draw, "first") == null);
    // The checkbox sits left of its row's text.
    const two = runOf(out.draw, "two").?;
    in.pointer = .{ two[0] - 12, (two[1] + two[3]) / 2 };
    in.buttons.left = true;
    _ = p.frame(h, &in, .{ .rows = &rows });
    in.buttons.left = false;
    _ = p.frame(h, &in, .{ .rows = &rows });
    try std.testing.expect(rows[1].selected and !rows[0].selected);
    rows[0].expanded = true;
    out = p.frame(h, &in, .{ .rows = &rows });
    try std.testing.expect(runOf(out.draw, "first") != null and runOf(out.draw, "second") == null);
}
