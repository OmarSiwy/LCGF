//! positioned, written by hand: right/bottom insets and position: fixed as anchors
//! (`spec.anchored`), position: sticky with top (`spec.sticky`), z-index as stacking layers
//! (`spec.layer`), inset 0 as a full-size float, and relative right/bottom as a translate.

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;

pub const theme: w.Theme = .{};

fn floating(comptime text: []const u8, comptime style: lcgf.types.Style) s.Spec {
    var st = style;
    st.float = true;
    st.role = .label;
    return s.styled(label.ct.label(theme, text), st);
}

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.col(.{ .size = .{ .px(200), .px(120) }, .pad = @splat(6), .fill = .rgb(0x30, 0x34, 0x40) }, .{
        // position: relative; right: 5px; bottom: 2px.
        s.styled(label.ct.label(theme, "Title"), .{ .transform = .{ 1, 0, 0, 1, -5, -2 }, .role = .label }),
        // inset 0: as large as the parent's content box.
        s.layer(s.col(.{ .size = .{ .pct(1), .pct(1) }, .float = true, .fill = .rgba(0, 0, 0, 0x40) }, .{}), 1),
        s.layer(s.anchored(floating("3", .{ .fill = .rgb(0xc0, 0x30, 0x30) }), .{ .at = .top_right, .pivot = .top_right, .offset = .{ -4, 4 } }), 2),
        s.anchored(floating("More", .{}), .{ .at = .bottom_right, .pivot = .bottom_right, .offset = .{ -8, -6 } }),
    }),
    s.sticky(label.ct.label(theme, "Section"), 140),
    s.layer(s.anchored(floating("Saved", .{ .pad = @splat(4), .fill = .rgb(0x20, 0x50, 0x30) }), .{ .at = .bottom_right, .pivot = .bottom_right, .offset = .{ -10, -10 }, .viewport = true }), 3),
});
