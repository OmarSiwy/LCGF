//! palette, written by hand: a region sized by its content (E1), for menus and palette results.
//! The comptime layout runs before the items exist; the page builds the region, keeps the size
//! its content measured, and lays itself out again around it in the same frame.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;

pub const theme: w.Theme = .{};

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel, .cross = .center }, .{
    lcgf.ct_interop.fitRegion(.each_hits, .{ .gap = 2 }),
    label.ct.label(theme, "Footer"),
});

pub fn Handlers(comptime Ui: type) type {
    return struct {
        picked: ?u32 = null,

        pub fn pick(h: *@This(), _: *Ui, index: u32) void {
            h.picked = index;
        }
    };
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

/// The first frame lays the footer out below the region, which is already as tall as its three
/// hits (E1: the page is laid out again around the size the region measured), and asks for no
/// second frame. A click in the frame the centred region grows lands on its final rect.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    const hits = [_]Hit{ .{ .title = "Open file" }, .{ .title = "Save all" }, .{ .title = "Quit" } };
    var in: lcgf.input.Input = .{};
    const out = p.frame(h, &in, .{ .hits = &hits });
    try std.testing.expect(out.wake > 0);
    const region = out.tree.rect(out.tree.find(.from("each_hits")));
    const quit = runOf(out.draw, "Quit").?;
    const footer = runOf(out.draw, "Footer").?;
    try std.testing.expect(region.y1 - region.y0 > 3 * (quit[3] - quit[1]));
    try std.testing.expect(footer[1] >= region.y1);
    try std.testing.expect(quit[3] <= region.y1);
    // A frame with the same items lays the page out once: the size is already kept.
    try std.testing.expect(p.frame(h, &in, .{ .hits = &hits }).wake > 0);

    // The centred region grows by a long hit, and moves left, in the frame that presses Quit's
    // new right edge: the press is judged against the region's final rect, not the one the
    // first layout gave it.
    const short = [_]Hit{.{ .title = "Quit" }};
    const long = [_]Hit{ .{ .title = "Quit" }, .{ .title = "Open the file with the longest name" } };
    const grown = p.frame(h, &in, .{ .hits = &long });
    const after = grown.tree.rect(grown.tree.find(.from("each_hits")));
    const edge = runOf(grown.draw, "Quit").?;
    const small = p.frame(h, &in, .{ .hits = &short });
    const before = small.tree.rect(small.tree.find(.from("each_hits")));
    // Far enough that the old origin puts the pointer left of Quit.
    try std.testing.expect(before.x0 - after.x0 > edge[2] - after.x0);
    in.pointer = .{ edge[2] - 1, (edge[1] + edge[3]) / 2 };
    in.buttons.left = true;
    _ = p.frame(h, &in, .{ .hits = &long });
    in.buttons.left = false;
    _ = p.frame(h, &in, .{ .hits = &long });
    try std.testing.expectEqual(@as(?u32, 0), h.picked);
}
