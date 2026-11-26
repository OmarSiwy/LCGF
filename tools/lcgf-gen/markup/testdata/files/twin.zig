//! files, written by hand: a comptime page with two run-time regions (M8.2, E2). The Spec
//! holds the regions (`ct_interop.region`), sized by their CSS; `Page.frame` fills each from
//! the app's items and composes the draw lists, one region after another.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;

pub const theme: w.Theme = .{};

pub const State = struct { folder: []const u8 = "" };

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.textStyled(s.heading(2, .folder), .{ .px = 21, .color = theme.text }),
    lcgf.ct_interop.region(.each_files, .{ .size = .{ .px(300), .px(200) }, .gap = 2 }),
    lcgf.ct_interop.region(.each_tags, .{ .dir = .x, .size = .{ .px(300), .px(40) }, .gap = 4 }),
});

pub fn Handlers(comptime Ui: type) type {
    return struct {
        opened: ?u32 = null,
        picked: ?u32 = null,

        pub fn open(h: *@This(), _: *Ui, index: u32) void {
            h.opened = index;
        }
        pub fn pick(h: *@This(), _: *Ui, index: u32) void {
            h.picked = index;
        }
    };
}

const File = struct { name: []const u8, size: f32 };
const Tag = struct { label: []const u8 };

/// The items parity.zig gives both frontends' regions; each side gets its own copy.
pub const Sample = struct {
    files: [3]File = .{ .{ .name = "a.txt", .size = 1.5 }, .{ .name = "b.txt", .size = 20 }, .{ .name = "c.txt", .size = 0.25 } },
    tags: [2]Tag = .{ .{ .label = "red" }, .{ .label = "green" } },

    pub fn data(x: *Sample) struct { files: []File, tags: []Tag } {
        return .{ .files = &x.files, .tags = &x.tags };
    }
};

/// The rect of the text run showing `text` in `d`.
fn runOf(d: *const lcgf.draw_list.DrawList, text: []const u8) ?[4]f32 {
    for (d.runs[0..d.run_len]) |r| if (std.mem.eql(u8, d.strings[r.start..][0..r.bytes], text)) return r.rect;
    return null;
}

fn click(p: anytype, h: anytype, in: *lcgf.input.Input, data: anytype, r: [4]f32) void {
    in.pointer = .{ (r[0] + r[2]) / 2, (r[1] + r[3]) / 2 };
    in.buttons.left = true;
    _ = p.frame(h, in, data);
    in.buttons.left = false;
    _ = p.frame(h, in, data);
}

/// Both regions show every item inside their rects; a click in each reports its own index.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    const files = [_]File{ .{ .name = "a.txt", .size = 1.5 }, .{ .name = "b.txt", .size = 20 }, .{ .name = "c.txt", .size = 0.25 } };
    const tags = [_]Tag{ .{ .label = "red" }, .{ .label = "green" } };
    const data = .{ .files = &files, .tags = &tags };
    var in: lcgf.input.Input = .{};
    const out = p.frame(h, &in, data);
    const d = out.draw;
    const files_rect = out.tree.rect(out.tree.find(.from("each_files")));
    const tags_rect = out.tree.rect(out.tree.find(.from("each_tags")));
    for (files) |f| {
        const r = runOf(d, f.name) orelse return error.MissingItem;
        try std.testing.expect(r[1] >= files_rect.y0 and r[3] <= files_rect.y1);
    }
    for (tags) |t| {
        const r = runOf(d, t.label) orelse return error.MissingItem;
        try std.testing.expect(r[1] >= tags_rect.y0 and r[3] <= tags_rect.y1);
    }
    // The tags lie in a row.
    try std.testing.expect(runOf(d, "green").?[0] > runOf(d, "red").?[2]);
    click(p, h, &in, data, runOf(d, "b.txt").?);
    try std.testing.expectEqual(@as(?u32, 1), h.opened);
    click(p, h, &in, data, runOf(p.frame(h, &in, data).draw, "green").?);
    try std.testing.expectEqual(@as(?u32, 1), h.picked);
    try std.testing.expectEqual(@as(?u32, 1), h.opened);
}
