//! The app module of the themed fixture: a card whose gap is the page theme's `pad` and
//! whose padding is the run-time token the page passes (`pad="var(--t-space)"`).

const lcgf = @import("lcgf");
const s = lcgf.spec;

pub const components = struct {
    pub fn @"sfy-card"(comptime theme: lcgf.widgets_base.Theme, comptime props: struct { pad: []const u8, children: []const s.Spec }) s.Spec {
        return s.tokened(s.col(.{ .gap = theme.pad, .fill = theme.control }, props.children), &.{
            .{ .target = .pad_left, .token = props.pad },
            .{ .target = .pad_top, .token = props.pad },
            .{ .target = .pad_right, .token = props.pad },
            .{ .target = .pad_bottom, .token = props.pad },
        });
    }
};
