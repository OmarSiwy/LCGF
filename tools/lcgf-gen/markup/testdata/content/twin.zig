//! content, written by hand: the document elements over widgets and roles: a link, lists.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const link = lcgf.widgets_link;
const label = lcgf.widgets_label;

pub const theme: w.Theme = .{};

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    link.ct.link(theme, .docs, "Read the docs"),
    // <ul>, <ol>: role list; <li>: role list_item, on the label of text-only content.
    s.col(.{ .role = .list }, .{
        s.styled(label.ct.label(theme, "Plain"), .{ .role = .list_item }),
        s.col(.{ .role = .list_item }, .{ label.ct.label(theme, "Inside"), label.ct.label(theme, "a box") }),
    }),
    s.col(.{ .role = .list }, .{s.styled(label.ct.label(theme, "First"), .{ .role = .list_item })}),
});

pub fn Handlers(comptime Ui: type) type {
    return struct {
        opened: u32 = 0,
        pub fn open_docs(h: *@This(), _: *Ui) void {
            h.opened += 1;
        }
    };
}

/// Clicks the link once through the generated `Page`.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    var in: lcgf.input.Input = .{};
    const t = p.frame(h, &in).tree;
    const r = t.rect(t.find(.from("docs")));
    in.pointer = .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
    in.buttons.left = true;
    _ = p.frame(h, &in);
    in.buttons.left = false;
    _ = p.frame(h, &in);
    try std.testing.expectEqual(1, h.opened);
}
