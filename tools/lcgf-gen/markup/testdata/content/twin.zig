//! content, written by hand: the document elements over widgets and roles: a link, lists, a
//! details section, the accent colour.

const std = @import("std");
const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const link = lcgf.widgets_link;
const label = lcgf.widgets_label;
const accordion = lcgf.widgets_accordion;

/// accent-color on :root: the theme's accent.
pub const theme: w.Theme = .{ .accent = .rgb(48, 128, 224) };

pub const State = struct { more_open: bool = true };

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    link.ct.link(theme, .docs, "Read the docs"),
    // <ul>, <ol>: role list; <li>: role list_item, on the label of text-only content.
    s.col(.{ .role = .list }, .{
        s.styled(label.ct.label(theme, "Plain"), .{ .role = .list_item }),
        s.col(.{ .role = .list_item }, .{ label.ct.label(theme, "Inside"), label.ct.label(theme, "a box") }),
    }),
    s.col(.{ .role = .list }, .{s.styled(label.ct.label(theme, "First"), .{ .role = .list_item })}),
    // <details open bind:open>: an accordion section, its <summary> the header.
    accordion.ct.section(theme, .more, .more_open, "More", .{
        s.textStyled(label.ct.label(theme, "Hidden text"), .{ .color = theme.text, .wrap = true }),
    }),
});

pub fn Handlers(comptime Ui: type) type {
    return struct {
        opened: u32 = 0,
        pub fn open_docs(h: *@This(), _: *Ui) void {
            h.opened += 1;
        }
    };
}

/// Clicks the link and the section's header once each through the generated `Page`.
pub fn events(comptime page: type, p: anytype, h: anytype) !void {
    _ = page;
    var in: lcgf.input.Input = .{};
    const t = p.frame(h, &in).tree;
    for ([_]lcgf.types.Rect{ t.rect(t.find(.from("docs"))), t.rect(t.find(.from("more"))) }) |r| {
        in.pointer = .{ (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 };
        in.buttons.left = true;
        _ = p.frame(h, &in);
        in.buttons.left = false;
        _ = p.frame(h, &in);
    }
    try std.testing.expectEqual(1, h.opened);
    try std.testing.expect(!p.ui.signals.state.more_open);
}
