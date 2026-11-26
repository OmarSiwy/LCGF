//! tokens, written by hand: the page whose `--t-*` custom properties are run-time theme
//! tokens. The Spec carries the CSS defaults and, per node, the fields its tokens set
//! (`spec.tokened`); runtime_test.zig changes the table on both frontends.

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;

pub const theme: w.Theme = .{};

pub const Tokens = struct { space: f32 = 8, panel: lcgf.types.Color = .rgb(0x20, 0x30, 0x40), round: f32 = 3, big: f32 = 20, ink: lcgf.types.Color = .rgb(0xff, 0xd0, 0x80) };

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.tokened(s.col(.{ .pad = .{ 4, 8, 4, 8 }, .gap = 8, .fill = .rgb(0x20, 0x30, 0x40), .radius = 3 }, .{
        s.tokened(s.textStyled(label.ct.label(theme, "Title"), .{ .px = 20, .color = .rgb(0xff, 0xd0, 0x80) }), &.{
            .{ .target = .text_px, .token = "big" },
            .{ .target = .text_color, .token = "ink" },
        }),
        s.styled(label.ct.label(theme, "Body"), .{ .size = .{ .px(120), .fit }, .role = .label }),
    }), &.{
        .{ .target = .pad_top, .token = "space" },
        .{ .target = .pad_bottom, .token = "space" },
        .{ .target = .fill, .token = "panel" },
        .{ .target = .radius, .token = "round" },
        .{ .target = .gap, .token = "space" },
    }),
});
