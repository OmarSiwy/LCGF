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
    // flex-wrap: wrap on a row: Flex.Style.wrap; align-content: Flex.Style.lines. Named, so
    // the runtime page has both flex columns and `semantics`.
    s.named(s.flexed(s.row(.{ .size = .{ .px(60), .px(80) }, .gap = 4 }, .{
        label.ct.label(theme, "one"),
        label.ct.label(theme, "two"),
        label.ct.label(theme, "three"),
    }), .{ .wrap = true, .lines = .center }), "Tags"),
    // align-content: space-between, and normal (unset): Flex.Style.line_space.
    s.flexed(s.row(.{ .size = .{ .px(60), .px(80) } }, .{ label.ct.label(theme, "one"), label.ct.label(theme, "two"), label.ct.label(theme, "three") }), .{ .wrap = true, .line_space = .between }),
    s.flexed(s.row(.{ .size = .{ .px(60), .px(80) } }, .{ label.ct.label(theme, "one"), label.ct.label(theme, "two") }), .{ .wrap = true, .line_space = .stretch }),
    // align-items: baseline on a column: start, CSS's fallback.
    s.col(.{ .cross = .start }, .{ label.ct.label(theme, "p"), label.ct.label(theme, "q") }),
    // aspect-ratio: Flex.Style.aspect, width over height.
    s.flexed(s.col(.{ .size = .{ .px(40), .fit }, .fill = .rgb(192, 64, 64) }, .{}), .{ .aspect = 2 }),
    // justify-content: space-*: Flex.Style.space, on rows and columns.
    s.flexed(s.row(.{ .size = .{ .px(200), .fit }, .gap = 4 }, .{
        label.ct.label(theme, "L"),
        label.ct.label(theme, "M"),
        label.ct.label(theme, "R"),
    }), .{ .space = .between }),
    s.flexed(s.col(.{ .size = .{ .fit, .px(60) } }, .{ label.ct.label(theme, "x"), label.ct.label(theme, "y") }), .{ .space = .evenly }),
});
