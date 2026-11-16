//! Accessibility settings as plain data (tier 0): what the platform's accessibility preferences
//! say, with no theme or widget code, so the runtime front end (`Context.settings`) and the
//! animation code can read them. settings.zig (tier 2) re-exports these and turns them into
//! theme tokens.

const std = @import("std");
const simd = @import("../core/simd.zig");

/// What the user asked the platform for. Plain data the host sets, every frame or on change;
/// `Context.settings` holds the copy the runtime front end reads.
pub const Settings = struct {
    /// Use `high_contrast_palette` instead of the theme's colours.
    high_contrast: bool = false,
    /// Text size relative to the theme's, from the platform's text-size setting (Windows "Make
    /// text bigger", iOS Dynamic Type, Android font scale). Clamped to `text_scale_min` to
    /// `text_scale_max` (settings.zig); NaN reads as `text_scale_min`. Only text grows: layout fits it.
    text_scale: f32 = 1,
    /// The platform asks for less motion (`prefers-reduced-motion`, macOS and iOS "Reduce
    /// motion", Windows "Show animations" off). Transitions finish at once (`progress`), and
    /// springs, tweens, sequences and layout slides show their end state at once (src/anim,
    /// through `Context.settings`).
    reduced_motion: bool = false,
    /// Show the focus ring all the time, not only after a key (`Focus.visible`, CSS
    /// `:focus-visible`): for keyboard and switch users whose platform says so (macOS "Keyboard
    /// navigation", Windows "Always show focus indicators"), or whose clicks come from a
    /// pointer emulator.
    always_show_focus: bool = false,
};

/// How far through a transition of `seconds` the UI is, `elapsed` seconds after it started:
/// 0 to 1. Under reduced motion every transition is done (1) from its first frame, so the
/// host stops waking for it; a transition of 0 seconds is done at once either way.
pub fn progress(s: *const Settings, elapsed: f32, seconds: f32) f32 {
    const d = seconds * simd.b2f(!s.reduced_motion);
    const done = simd.b2f(!(d > 0));
    return @min(@max((@max(elapsed, 0) + done) / @max(d, std.math.floatMin(f32)), 0), 1);
}
