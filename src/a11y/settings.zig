//! Accessibility settings (tier 2): the platform's accessibility preferences as plain inputs,
//! and what they change. Shells read the platform (Windows high contrast, `prefers-contrast`,
//! ...) and set the fields; this file turns them into theme tokens (src/theme/theme.zig), so
//! honouring a setting needs no per-widget code.

const std = @import("std");
const types = @import("../core/types.zig");
const simd = @import("../core/simd.zig");
const theme = @import("../theme/theme.zig");
const base = @import("../widgets/base.zig");
const Color = types.Color;
const Tokens = theme.Tokens;
const Focus = @import("../interact/focus.zig").Focus;

/// What the user asked the platform for. Plain data the host sets, every frame or on change.
pub const Settings = struct {
    /// Use `high_contrast_palette` instead of the theme's colours.
    high_contrast: bool = false,
    /// Text size relative to the theme's, from the platform's text-size setting (Windows "Make
    /// text bigger", iOS Dynamic Type, Android font scale). Clamped to `text_scale_min` to
    /// `text_scale_max`; NaN reads as `text_scale_min`. Only text grows: layout fits it.
    text_scale: f32 = 1,
    /// The platform asks for less motion (`prefers-reduced-motion`, macOS and iOS "Reduce
    /// motion", Windows "Show animations" off). Transitions finish at once (`progress`); the
    /// animation system (lane anim, C0724) reads this field.
    reduced_motion: bool = false,
    /// Show the focus ring all the time, not only after a key (`Focus.visible`, CSS
    /// `:focus-visible`): for keyboard and switch users whose platform says so (macOS "Keyboard
    /// navigation", Windows "Always show focus indicators"), or whose clicks come from a
    /// pointer emulator.
    always_show_focus: bool = false,
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

/// How far through a transition of `seconds` the UI is, `elapsed` seconds after it started:
/// 0 to 1. Under reduced motion every transition is done (1) from its first frame, so the
/// host stops waking for it; a transition of 0 seconds is done at once either way.
pub fn progress(s: *const Settings, elapsed: f32, seconds: f32) f32 {
    const d = seconds * simd.b2f(!s.reduced_motion);
    const done = simd.b2f(!(d > 0));
    return base.unit((@max(elapsed, 0) + done) / @max(d, std.math.floatMin(f32)));
}

/// Applies `always_show_focus` to this frame's ring: call after `Focus.step`, before
/// `Focus.ring`. Without the setting the ring follows keys and the pointer as before.
pub fn showFocus(s: *const Settings, fo: *Focus) void {
    fo.visible = simd.orB(fo.visible, s.always_show_focus);
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

test "settings: reduced motion finishes every transition on its first frame" {
    const calm: Settings = .{ .reduced_motion = true };
    try testing.expectEqual(@as(f32, 0), progress(&.{}, 0, 0.3));
    try testing.expectApproxEqAbs(@as(f32, 0.5), progress(&.{}, 0.15, 0.3), 1e-6);
    try testing.expectEqual(@as(f32, 1), progress(&.{}, 0.3, 0.3));
    try testing.expectEqual(@as(f32, 1), progress(&.{}, 9, 0.3));
    try testing.expectEqual(@as(f32, 0), progress(&.{}, -1, 0.3));
    for ([_]f32{ 0, 0.01, 0.15, 5 }) |t| try testing.expectEqual(@as(f32, 1), progress(&calm, t, 0.3));
    // A zero-length transition is done at once, with or without the setting.
    try testing.expectEqual(@as(f32, 1), progress(&.{}, 0, 0));
    try testing.expectEqual(@as(f32, 1), progress(&calm, 0, 0));
}

/// Ring per frame for a two-button row, as `Interaction`, `Focus` and `showFocus` give it
/// for `src`.
fn rings(s: *const Settings, src: []const u8) ![5]types.Rect {
    const mem = @import("../core/mem.zig");
    const Tree = @import("../core/tree.zig").Tree;
    const Texts = @import("../core/texts.zig").Texts;
    const focus = @import("../interact/focus.zig");
    const Interaction = @import("../interact/interaction.zig").Interaction;
    const Input = @import("../core/input.zig").Input;
    var raw: [16 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = Tree.init(&carver, 4);
    var tx = Texts.init(&carver, 1);
    var sc = focus.Scopes.init(&carver, 4);
    const root = t.push(0, .none, &.{ .dir = .x, .size = .{ .px(200), .px(20) } });
    for ([_]types.Id{ .from("a"), .from("b") }) |id| {
        const n = t.push(root, id, &.{ .size = .{ .px(100), .px(20) } });
        t.seal(n);
        t.c.sense[n] = @bitCast(types.Sense.button);
    }
    t.seal(root);
    @import("../layout/layout.zig").run(&t, &tx, .{ 200, 20 });
    focus.scan(&t, &sc);
    var it: Interaction = .{};
    var fo: Focus = .{};
    var out: [5]types.Rect = @splat(.{});
    var text: [4]u8 = undefined;
    var evs: [4]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    var r: @import("../core/input.zig").Replay = .{ .src = src };
    var k: usize = 0;
    while (try r.next(.{ .text = &text, .events = &evs, .contacts = &contacts })) |in| : (k += 1) {
        it.step(&t, in);
        fo.step(&it, &t, &sc, in);
        showFocus(s, &fo);
        out[k] = fo.ring(&it, &t);
    }
    try testing.expectEqual(5, k);
    return out;
}

test "settings: always show focus keeps the ring on after the pointer, wherever focus goes" {
    // Tab focuses "a"; a click on "b" moves focus there; the release keeps it; a click on
    // nothing clears it.
    const src =
        \\frame
        \\press 43
        \\frame
        \\release 43
        \\frame
        \\pointer 150 10
        \\buttons left
        \\frame
        \\buttons
        \\pointer 150 50
        \\frame
        \\buttons left
    ;
    const a: types.Rect = .{ .x0 = -2, .y0 = -2, .x1 = 102, .y1 = 22 };
    const b: types.Rect = .{ .x0 = 98, .y0 = -2, .x1 = 202, .y1 = 22 };
    // Without the setting the click hides the ring (`:focus-visible`).
    try testing.expectEqualSlices(types.Rect, &.{ a, a, .{}, .{}, .{} }, &try rings(&.{}, src));
    // With it the ring follows focus through the click; nothing focused still draws nothing.
    try testing.expectEqualSlices(types.Rect, &.{ a, a, b, b, .{} }, &try rings(&.{ .always_show_focus = true }, src));
}
