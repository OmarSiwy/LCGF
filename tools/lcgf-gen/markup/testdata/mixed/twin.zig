//! mixed, written by hand: flex margins beside, around and inside a grid, and on an
//! anchored, raised box (`spec.flexed` with `spec.grid`, `spec.anchored` and `spec.layer`).

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;

pub const theme: w.Theme = .{};

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.row(.{ .gap = 4 }, .{
        s.flexed(label.ct.label(theme, "A"), .{ .margin = .{ 6, 2, 6, 2 } }),
        s.flexed(label.ct.label(theme, "B"), .{ .margin = .{ 6, 2, 6, 2 } }),
    }),
    s.flexed(s.grid(.{}, .{ .columns = &.{ .px(80), .fit }, .gap = .{ 4, 4 } }, .{
        s.col(.{}, .{s.flexed(label.ct.label(theme, "One"), .{ .margin = .{ 5, 0, 0, 0 } })}),
        label.ct.label(theme, "Two"),
    }), .{ .margin = .{ 10, 8, 0, 0 } }),
    s.flexed(s.layer(s.anchored(s.styled(label.ct.label(theme, "Note"), .{ .float = true, .role = .label }), .{ .at = .bottom_right, .pivot = .bottom_right, .offset = .{ -4, -4 } }), 2), .{ .margin = .{ 2, 2, 2, 2 } }),
});
