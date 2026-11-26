//! tokens, written by hand: the page with its run-time tokens at their defaults, as the spec
//! frontend folds them. runtime_test.zig changes the table on the runtime page.

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;

pub const theme: w.Theme = .{};

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.col(.{ .pad = .{ 4, 8, 4, 8 }, .gap = 8, .fill = .rgb(0x20, 0x30, 0x40), .radius = 3 }, .{
        s.textStyled(label.ct.label(theme, "Title"), .{ .px = 20, .color = .rgb(0xff, 0xd0, 0x80) }),
        s.styled(label.ct.label(theme, "Body"), .{ .size = .{ .px(120), .fit }, .role = .label }),
    }),
});
