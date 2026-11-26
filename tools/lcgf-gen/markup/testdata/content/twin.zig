//! content, written by hand: the document elements over widgets and roles: a link, lists
//! with markers, a
//! details section, the accent colour,
//! text-transform, box-shadow, outline.

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
    // text-transform: Unicode casing of the literal text at build time, inherited; lang=tr.
    s.col(.{}, .{ label.ct.label(theme, "SHOUT"), label.ct.label(theme, "Two Words"), label.ct.label(theme, "STRASSE"), label.ct.label(theme, "İSTANBUL") }),
    // <ul>, <ol>: role list; <li>: a list_item row of its marker (disc, decimal from the
    // UA sheet; list-style-type) and its content, which fills the rest.
    s.col(.{ .role = .list }, .{
        s.row(.{ .role = .list_item }, .{ label.ct.label(theme, "\u{2022} "), s.styled(label.ct.label(theme, "Plain"), .{ .size = .{ .fill, .fit }, .role = .label }) }),
        s.row(.{ .role = .list_item }, .{
            label.ct.label(theme, "\u{2022} "),
            s.col(.{ .size = .{ .fill, .fit } }, .{ label.ct.label(theme, "Inside"), label.ct.label(theme, "a box") }),
        }),
    }),
    s.col(.{ .role = .list }, .{
        s.row(.{ .role = .list_item }, .{ label.ct.label(theme, "3. "), s.styled(label.ct.label(theme, "First"), .{ .size = .{ .fill, .fit }, .role = .label }) }),
        s.row(.{ .role = .list_item }, .{ label.ct.label(theme, "\u{25AA} "), s.styled(label.ct.label(theme, "Square"), .{ .size = .{ .fill, .fit }, .role = .label }) }),
    }),
    s.col(.{ .role = .list }, .{s.styled(label.ct.label(theme, "Bare"), .{ .role = .list_item })}),
    // Counter styles (text_counters, at build time) and a string marker.
    s.col(.{ .role = .list }, .{
        s.row(.{ .role = .list_item }, .{ label.ct.label(theme, "IV. "), s.styled(label.ct.label(theme, "Four"), .{ .size = .{ .fill, .fit }, .role = .label }) }),
        s.row(.{ .role = .list_item }, .{ label.ct.label(theme, "\u{3B5}. "), s.styled(label.ct.label(theme, "Five"), .{ .size = .{ .fill, .fit }, .role = .label }) }),
    }),
    s.col(.{ .role = .list }, .{s.row(.{ .role = .list_item }, .{ label.ct.label(theme, "- "), s.styled(label.ct.label(theme, "Dash"), .{ .size = .{ .fill, .fit }, .role = .label }) })}),
    // box-shadow: a column in the box's place, a floating shadow node of its size first.
    s.flexed(s.col(.{ .size = .{ .px(120), .fit } }, .{
        s.col(.{ .float = true, .size = .{ .pct(1), .pct(1) }, .fill = .rgba(0, 0, 0, 128), .radius = 5, .params = lcgf.features.shadow(3), .paint_outset = .{ 1, -1, 1, 3 } }, .{}),
        s.col(.{ .size = .{ .fill, .fill }, .pad = @splat(8), .fill = .rgb(51, 51, 51), .radius = 4 }, .{ label.ct.label(theme, "Card"), label.ct.label(theme, "body") }),
    }), .{ .margin = @splat(4) }),
    // outline: a floating ring node, outset by its width and offset, in the same column.
    s.col(.{}, .{
        s.col(.{ .float = true, .size = .{ .pct(1), .pct(1) }, .border = 2, .border_color = .rgb(255, 204, 0), .radius = 6, .paint_outset = @splat(3) }, .{}),
        s.col(.{ .size = .{ .fill, .fill }, .radius = 3 }, .{label.ct.label(theme, "Ringed")}),
    }),
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
