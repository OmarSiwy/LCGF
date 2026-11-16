//! Accessibility settings (tier 2): the platform's accessibility preferences as plain inputs,
//! and what they change. Shells read the platform (Windows high contrast, `prefers-contrast`,
//! ...) and set the fields; this file turns them into theme tokens (src/theme/theme.zig), so
//! honouring a setting needs no per-widget code.

const std = @import("std");
const types = @import("../core/types.zig");
const theme = @import("../theme/theme.zig");
const base = @import("../widgets/base.zig");
const Color = types.Color;
const Tokens = theme.Tokens;

/// What the user asked the platform for. Plain data the host sets, every frame or on change.
pub const Settings = struct {
    /// Use `high_contrast_palette` instead of the theme's colours.
    high_contrast: bool = false,
    /// Text size relative to the theme's, from the platform's text-size setting (Windows "Make
    /// text bigger", iOS Dynamic Type, Android font scale). Clamped to `text_scale_min` to
    /// `text_scale_max`; NaN reads as `text_scale_min`. Only text grows: layout fits it.
    text_scale: f32 = 1,
};

/// The range `Settings.text_scale` is clamped to: past both ends of what platforms offer
/// (Android 0.85, iOS accessibility sizes about 3.1).
pub const text_scale_min: f32 = 0.5;
pub const text_scale_max: f32 = 4;

/// Light text and yellow accents on black, as the platforms' high-contrast themes draw them.
/// Control faces stay apart from the panel and from each other so states still show.
// ponytail: one dark palette; add a light high-contrast palette if a platform asks for one.
pub const high_contrast_palette: theme.Palette = .{
    Color.rgb(255, 255, 255), // text
    Color.rgb(0, 0, 0), // surface
    Color.rgb(32, 32, 32), // control
    Color.rgb(64, 64, 64), // control_hot
    Color.rgb(16, 16, 16), // control_held
    Color.rgb(255, 230, 0), // accent
};

/// `tok` adjusted by the settings: the tokens the widget theme is built from.
pub fn tokens(s: *const Settings, tok: *const Tokens) Tokens {
    var out = tok.*;
    if (s.high_contrast) out.palette = high_contrast_palette;
    const k = @min(@max(s.text_scale, text_scale_min), text_scale_max);
    for (&out.text_size) |*px| px.* *= k;
    return out;
}

/// The widget theme of `tok` under the settings. Cheap enough to call every frame, so a change
/// of setting restyles the next frame.
pub fn widgets(s: *const Settings, tok: *const Tokens) base.Theme {
    return theme.widgets(&tokens(s, tok));
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "settings: the defaults leave the theme alone" {
    for ([_]Tokens{ theme.dark, theme.light }) |tok| {
        try testing.expectEqual(tok, tokens(&.{}, &tok));
        try testing.expectEqual(theme.widgets(&tok), widgets(&.{}, &tok));
    }
}

test "settings: high contrast swaps the palette and nothing else" {
    const hc = tokens(&.{ .high_contrast = true }, &theme.light);
    try testing.expectEqual(high_contrast_palette, hc.palette);
    try testing.expectEqual(theme.light.space, hc.space);
    try testing.expectEqual(theme.light.radius, hc.radius);
    try testing.expectEqual(theme.light.text_size, hc.text_size);
}

test "settings: switching high contrast on and off restyles the page, behaviour unchanged" {
    const on: Settings = .{ .high_contrast = true };
    try theme.expectSwitch(comptime widgets(&.{}, &theme.dark), comptime widgets(&on, &theme.dark));
    try theme.expectSwitch(comptime widgets(&on, &theme.light), comptime widgets(&.{}, &theme.light));
}

test "settings: text scaling multiplies every text size, clamped, and nothing else" {
    const big = tokens(&.{ .text_scale = 2 }, &theme.dark);
    for (theme.dark.text_size, big.text_size) |a, b| try testing.expectEqual(a * 2, b);
    try testing.expectEqual(theme.dark.space, big.space);
    try testing.expectEqual(theme.dark.palette, big.palette);
    const md = theme.dark.textAt(.md);
    try testing.expectEqual(md * text_scale_max, tokens(&.{ .text_scale = 100 }, &theme.dark).textAt(.md));
    try testing.expectEqual(md * text_scale_min, tokens(&.{ .text_scale = 0 }, &theme.dark).textAt(.md));
    try testing.expectEqual(md * text_scale_min, tokens(&.{ .text_scale = std.math.nan(f32) }, &theme.dark).textAt(.md));
    try testing.expectEqual(md * 2, widgets(&.{ .text_scale = 2, .high_contrast = true }, &theme.dark).text_px);
}

test "settings: scaled text draws at the scaled size, behaviour unchanged" {
    // expectSwitch checks every text run is drawn at its theme's `text_px`, and that the same
    // script of pointer moves (aimed at last frame's rects) gives the same states.
    try theme.expectSwitch(comptime widgets(&.{}, &theme.dark), comptime widgets(&.{ .text_scale = 2 }, &theme.dark));
    try theme.expectSwitch(comptime widgets(&.{}, &theme.dark), comptime widgets(&.{ .text_scale = 0.75 }, &theme.dark));
}
