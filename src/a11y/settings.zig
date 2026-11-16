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
};

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
