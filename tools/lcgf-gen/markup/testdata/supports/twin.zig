//! supports, written by hand: `@supports` is decided at build time. The rules whose
//! condition the compiler maps apply as if written without it (gap, not (unknown),
//! and/or); the ones that ask for float, which is not lowered, are dropped. Nothing
//! restyles `.bar` at run time, so its transition never runs and adds nothing.

const lcgf = @import("lcgf");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const label = lcgf.widgets_label;

pub const theme: w.Theme = .{};

const blue: lcgf.types.TextStyle = .{ .px = theme.text_px, .color = .rgb(0x80, 0xc0, 0xff) };

pub const spec = s.col(.{ .size = .{ .fill, .fill }, .fill = theme.panel }, .{
    s.row(.{ .pad = @splat(4), .gap = 6 }, .{
        s.textStyled(label.ct.label(theme, "One"), blue),
        s.textStyled(label.ct.label(theme, "Two"), blue),
    }),
});
