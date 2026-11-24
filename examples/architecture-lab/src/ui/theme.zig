//! Theme selection is one value; modules receive it read-only.
const lcgf = @import("lcgf");
const Color = lcgf.types.Color;
const Theme = lcgf.widgets_base.Theme;

pub fn make(dark: bool) Theme {
    return if (dark) .{
        .text = Color.rgb(222, 230, 237),
        .panel = Color.rgb(24, 31, 40),
        .control = Color.rgb(39, 49, 63),
        .control_hot = Color.rgb(55, 68, 86),
        .control_held = Color.rgb(18, 24, 33),
        .accent = Color.rgb(39, 111, 134),
        .radius = 5,
        .pad = 7,
    } else .{
        .text = Color.rgb(25, 40, 53),
        .panel = Color.rgb(237, 243, 247),
        .control = Color.rgb(214, 225, 234),
        .control_hot = Color.rgb(191, 210, 223),
        .control_held = Color.rgb(250, 252, 253),
        .accent = Color.rgb(139, 204, 216),
        .radius = 5,
        .pad = 7,
    };
}
