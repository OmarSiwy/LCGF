//! Environment conditions are inputs, not platform queries. Unknown preferences stay unknown;
//! a condition asking for false does not match a host that has supplied no information.

const std = @import("std");
const Input = @import("../core/input.zig").Input;
const Settings = @import("../a11y/settings_data.zig").Settings;

pub const Environment = struct {
    viewport: [2]f32 = .{ 0, 0 },
    container: ?[2]f32 = null,
    scale: f32 = 1,
    text_scale: f32 = 1,
    dark: ?bool = null,
    high_contrast: ?bool = null,
    forced_colors: ?bool = null,
    reduced_motion: ?bool = null,
    reduced_transparency: ?bool = null,
    always_show_focus: ?bool = null,
    coarse_pointer: ?bool = null,
    hover: ?bool = null,
    rtl: ?bool = null,

    pub fn fromInput(input: *const Input) Environment {
        return .{ .viewport = input.viewport, .scale = input.scale, .dark = input.appearance.dark };
    }

    /// Read existing accessibility settings without overwriting unrelated preference inputs.
    pub fn withSettings(environment: Environment, preferences: *const Settings) Environment {
        var out = environment;
        out.high_contrast = preferences.high_contrast;
        out.text_scale = preferences.text_scale;
        out.reduced_motion = preferences.reduced_motion;
        out.always_show_focus = preferences.always_show_focus;
        return out;
    }

    /// Hosts can hand this back to Context.settings. Unknown fields preserve the host's
    /// existing decisions, instead of turning an unknown preference into a negative one.
    pub fn settings(environment: Environment, previous: Settings) Settings {
        var out = previous;
        out.high_contrast = environment.high_contrast orelse previous.high_contrast;
        out.text_scale = environment.textFactor();
        out.reduced_motion = environment.reduced_motion orelse previous.reduced_motion;
        out.always_show_focus = environment.always_show_focus orelse previous.always_show_focus;
        return out;
    }

    pub fn textFactor(environment: Environment) f32 {
        if (!std.math.isFinite(environment.text_scale)) return 1;
        return std.math.clamp(environment.text_scale, 0.5, 4);
    }

    /// A caller-controlled motion policy; essential motion is an explicit decision. The
    /// returned duration works with the existing tween/keyframe functions.
    pub fn duration(environment: Environment, seconds: f32, essential: bool) f32 {
        if (!std.math.isFinite(seconds) or seconds < 0) return 0;
        if ((environment.reduced_motion orelse false) and !essential) return 0;
        return seconds;
    }

    /// Use for decorative surface alpha only. Content/group opacity can carry meaning, so
    /// those callers choose their own fallback instead of being forcibly made opaque.
    pub fn surfaceAlpha(environment: Environment, requested: f32) f32 {
        if (environment.reduced_transparency orelse false) return 1;
        if (!std.math.isFinite(requested)) return 1;
        return std.math.clamp(requested, 0, 1);
    }
};

pub const Range = struct {
    min: f32 = 0,
    max: f32 = std.math.inf(f32),

    pub fn contains(range: Range, value: f32) bool {
        return value >= range.min and value <= range.max;
    }
};

pub const Conditions = struct {
    width: Range = .{},
    height: Range = .{},
    scale: Range = .{},
    container_width: ?Range = null,
    container_height: ?Range = null,
    dark: ?bool = null,
    high_contrast: ?bool = null,
    forced_colors: ?bool = null,
    reduced_motion: ?bool = null,
    reduced_transparency: ?bool = null,
    always_show_focus: ?bool = null,
    coarse_pointer: ?bool = null,
    hover: ?bool = null,
    rtl: ?bool = null,

    pub fn matches(conditions: Conditions, environment: Environment) bool {
        if (!conditions.width.contains(environment.viewport[0]) or !conditions.height.contains(environment.viewport[1]) or !conditions.scale.contains(environment.scale)) return false;
        if (conditions.container_width) |range| {
            const size = environment.container orelse return false;
            if (!range.contains(size[0])) return false;
        }
        if (conditions.container_height) |range| {
            const size = environment.container orelse return false;
            if (!range.contains(size[1])) return false;
        }
        inline for (.{ "dark", "high_contrast", "forced_colors", "reduced_motion", "reduced_transparency", "always_show_focus", "coarse_pointer", "hover", "rtl" }) |name| {
            if (@field(conditions, name)) |wanted| {
                const actual = @field(environment, name) orelse return false;
                if (actual != wanted) return false;
            }
        }
        return true;
    }
};

test "unknown preferences do not match false; viewport and container conditions stay separate" {
    const not_dark: Conditions = .{ .dark = false };
    try std.testing.expect(!not_dark.matches(.{}));
    try std.testing.expect(not_dark.matches(.{ .dark = false }));
    const compact: Conditions = .{ .width = .{ .min = 800 }, .container_width = .{ .max = 300 } };
    try std.testing.expect(!compact.matches(.{ .viewport = .{ 1024, 768 } }));
    try std.testing.expect(compact.matches(.{ .viewport = .{ 1024, 768 }, .container = .{ 240, 500 } }));
}

test "known accessibility inputs consume existing settings and explicit effect choices" {
    const environment: Environment = .{ .reduced_motion = true, .reduced_transparency = true, .text_scale = 2 };
    const settings = environment.settings(.{ .high_contrast = true });
    try std.testing.expect(settings.high_contrast and settings.reduced_motion);
    try std.testing.expectEqual(@as(f32, 2), settings.text_scale);
    try std.testing.expectEqual(@as(f32, 0), environment.duration(0.3, false));
    try std.testing.expectEqual(@as(f32, 0.3), environment.duration(0.3, true));
    try std.testing.expectEqual(@as(f32, 1), environment.surfaceAlpha(0.2));
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Environment);
    std.testing.refAllDecls(Conditions);
}
