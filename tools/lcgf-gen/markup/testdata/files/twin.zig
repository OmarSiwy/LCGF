//! files, written by hand: a comptime page with a run-time region (M8.2). The Spec holds the
//! region (`ct_interop.region`), sized by its CSS; `Page.frame` fills it each frame from the
//! app's items and composes the two draw lists.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;

pub const theme: w.Theme = .{};

pub const State = struct { folder: []const u8 = "" };

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.textStyled(s.heading(2, .folder), .{ .px = 21, .color = theme.text }),
    lcgf.ct_interop.region(.each_files, .{ .size = .{ .px(300), .px(200) }, .gap = 2 }),
});

pub fn Handlers(comptime Ui: type) type {
    return struct {
        opened: ?u32 = null,

        pub fn open(h: *@This(), _: *Ui, index: u32) void {
            h.opened = index;
        }
    };
}

const File = struct { name: []const u8, size: f32 };

/// The region shows every item; a click on the second item's button reports its index.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    const files = [_]File{ .{ .name = "a.txt", .size = 1.5 }, .{ .name = "b.txt", .size = 20 }, .{ .name = "c.txt", .size = 0.25 } };
    var in: lcgf.input.Input = .{};
    const out = p.frame(h, &in, .{ .files = &files });
    const d = out.draw;
    var found: [3]bool = @splat(false);
    var b_rect: [4]f32 = undefined;
    for (d.runs[0..d.run_len]) |r| {
        const text = d.strings[r.start..][0..r.bytes];
        for (files, 0..) |f, k| if (std.mem.eql(u8, text, f.name)) {
            found[k] = true;
            if (k == 1) b_rect = r.rect;
        };
    }
    try std.testing.expectEqual([3]bool{ true, true, true }, found);
    // The items sit inside the region's rect (y below the heading).
    const region = out.tree.rect(out.tree.find(.from("each_files")));
    try std.testing.expect(b_rect[1] >= region.y0 and b_rect[3] <= region.y1);
    in.pointer = .{ (b_rect[0] + b_rect[2]) / 2, (b_rect[1] + b_rect[3]) / 2 };
    in.buttons.left = true;
    _ = p.frame(h, &in, .{ .files = &files });
    in.buttons.left = false;
    _ = p.frame(h, &in, .{ .files = &files });
    try std.testing.expectEqual(@as(?u32, 1), h.opened);
}
