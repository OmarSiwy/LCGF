//! landmarks, written by hand: the HTML-AAM landmark roles, @layer order, combinators and
//! structural pseudo-classes, custom properties with a fallback, inline style, and the box
//! properties of §2.2 (sizes, flex-grow/shrink, overflow, position, transform, opacity,
//! visibility, pointer-events, a two-stop gradient, a dashed border, four radii).

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;
const separator = lcgf.widgets_separator;
const types = lcgf.types;

pub const theme: w.Theme = .{};

/// Accessible names the a11y export must carry (parity.zig).
pub const names = .{ "Primary", "Settings", "Side notes" };

const item: types.Style = .{ .size = .{ .grow(2), .fit }, .min = .{ 100, 0 }, .shrink = true };

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .gap = 12, .fill = theme.panel }, .{
    // header: banner (not inside a sectioning element); `to right` runs left to right.
    s.landmark(.banner, .{ .dir = .x, .size = .{ .fit, .px(40) }, .main = .center, .fill = .rgb(0x10, 0x20, 0x30), .params = lcgf.features.linear(.rgb(0x40, 0x50, 0x60), 0) }, .{
        // The `page` layer comes after `base`, so its gap wins; base's padding stays.
        s.named(s.landmark(.navigation, .{ .pad = @splat(2), .gap = 6 }, .{
            s.textStyled(label.ct.label(theme, "One"), .{ .px = theme.text_px, .color = .rgb(255, 0, 0) }),
            s.styled(label.ct.label(theme, "Two"), .{ .opacity = 0.5, .role = .label }),
            s.styled(label.ct.label(theme, "Three"), .{ .participation = .hidden, .opacity = 0.5, .role = .label }),
        }), "Primary"),
    }),
    s.landmark(.main, .{ .dir = .x, .size = .{ .fit, .fill }, .clip = true }, .{
        s.named(s.landmark(.region, item, .{
            s.landmark(.article, .{}, .{
                s.textStyled(s.styled(s.heading(2, "Article"), .{ .transform = .{ 1, 0, 0, 1, 3, 2 }, .role = .heading, .value = 2 }), .{ .px = 21, .color = theme.text }),
                s.styled(label.ct.label(theme, "new"), .{ .float = true, .offset = .{ 10, 4 }, .transform = .{ 2, 0, 0, 2, 5, 1 }, .transform_origin = .{ 0, 0 }, .role = .label }),
            }),
            s.styled(label.ct.label(theme, "Card"), .{ .pad = .{ 8, 6, 8, 4 }, .border = 2, .border_color = .rgb(1, 2, 3), .params = lcgf.features.dashed(6, 6), .radii = .{ 1, 2, 3, 4 }, .role = .label }),
            separator.ct.separator(theme, .horizontal),
        }), "Settings"),
        // aria-labelledby: the named elements' text, joined.
        s.named(s.landmark(.complementary, .{ .participation = .{ .hit = false }, .max = .{ 200, types.inf }, .cross = .center }, .{
            label.ct.label(theme, "Side"),
            label.ct.label(theme, "notes"),
        }), "Side notes"),
        // An unnamed section is no landmark.
        s.col(item, .{label.ct.label(theme, "Plain")}),
    }),
    s.landmark(.form, .{}, .{
        s.landmark(.search, .{}, .{label.ct.label(theme, "Find")}),
    }),
    s.landmark(.content_info, .{}, .{label.ct.label(theme, "Footer")}),
});
