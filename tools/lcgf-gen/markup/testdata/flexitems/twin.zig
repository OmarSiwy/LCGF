//! flexitems, written by hand: CSS margins and the other flex item rules (`spec.flexed`).

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;

pub const theme: w.Theme = .{};

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.row(.{ .gap = 4 }, .{
        // CSS top-right-bottom-left; Flex.Style.margin is left, top, right, bottom.
        s.flexed(label.ct.label(theme, "A"), .{ .margin = .{ 6, 2, 6, 2 } }),
        s.flexed(label.ct.label(theme, "B"), .{ .margin = .{ 0, 2, 6, 2 } }),
    }),
    // align-self: Flex.Style.cross.
    s.row(.{ .size = .{ .fit, .px(40) } }, .{
        label.ct.label(theme, "top"),
        s.flexed(label.ct.label(theme, "C"), .{ .cross = .center }),
    }),
    // align-items: baseline on a row: Flex.Style.baseline.
    s.flexed(s.row(.{ .gap = 4 }, .{
        s.textStyled(label.ct.label(theme, "Big"), .{ .px = 24, .color = .rgb(230, 230, 235) }),
        label.ct.label(theme, "small"),
    }), .{ .baseline = true }),
});
