//! Style diagnostics over explicit known samples and semantic inputs. This is diagnostic
//! data, not a compliance certification. Unknown image/filter backdrops remain unknown.
//! Hosts can supply sampled final colors instead of guessing from a complex paint graph.

const std = @import("std");
const types = @import("../core/types.zig");
const properties = @import("properties.zig");
const resolution = @import("resolve.zig");
const settings = @import("../a11y/settings.zig");

pub const Kind = enum { missing_name, unknown_text_background, low_text_contrast, missing_focus_indicator, unknown_focus_background, low_focus_contrast, small_target };
pub const Issue = struct { kind: Kind, actual: f32 = 0, required: f32 = 0 };
pub const Sample = struct {
    foreground: types.Color,
    /// Must be opaque. The supplied foreground is composited onto this known background.
    background: types.Color,
};
pub const Input = struct {
    computed: *const properties.Computed,
    states: resolution.States = .{},
    /// Null means the host has not supplied a semantic name; an explicit empty name is a
    /// diagnostic for an enabled interactive control. The source may be semantics export.
    accessible_name: ?[]const u8 = null,
    interactive: bool = false,
    has_text: bool = true,
    /// Final paint samples; native style fallback is safe only when a host knows the surface.
    text_sample: ?Sample = null,
    text_minimum: f32 = settings.aa,
    focus: ?*const properties.Computed = null,
    focus_sample: ?Sample = null,
    focus_minimum: f32 = settings.non_text,
    bounds: ?types.Rect = null,
    /// Application policy, zero disables this optional geometry diagnostic. This check does
    /// not infer spacing or exception rules for neighboring hit targets.
    minimum_target: f32 = 0,
};
pub const Error = error{ NoSpace, InvalidSample };

/// WCAG 2 contrast of an alpha-composited foreground against a known opaque surface. Alpha
/// blending uses the renderer's encoded-sRGB convention, then luminance uses linear sRGB.
pub fn contrast(sample: Sample) Error!f32 {
    if (sample.background.a != 255) return error.InvalidSample;
    const alpha = @as(f32, @floatFromInt(sample.foreground.a)) / 255;
    const foreground = [3]u8{ sample.foreground.r, sample.foreground.g, sample.foreground.b };
    const background = [3]u8{ sample.background.r, sample.background.g, sample.background.b };
    const weights = [3]f32{ 0.2126, 0.7152, 0.0722 };
    var a: f32 = 0;
    var b: f32 = 0;
    for (foreground, background, weights) |fg, bg, weight| {
        const x = @as(f32, @floatFromInt(bg)) / 255;
        const y = @as(f32, @floatFromInt(fg)) / 255 * alpha + x * (1 - alpha);
        a += weight * linear(y);
        b += weight * linear(x);
    }
    return (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
}

fn linear(value: f32) f32 {
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

/// At most six issues. No allocation and no hidden writes to the widget or its semantics.
/// Disabled controls skip text/focus/target requirements; style cannot make them actionable.
pub fn check(input: Input, destination: []Issue) Error![]const Issue {
    if (!std.math.isFinite(input.text_minimum) or input.text_minimum < 1 or !std.math.isFinite(input.focus_minimum) or input.focus_minimum < 1 or !std.math.isFinite(input.minimum_target) or input.minimum_target < 0) return error.InvalidSample;
    var issues: [6]Issue = undefined;
    var count: usize = 0;
    if (!input.states.disabled and input.computed.box.participation.layout and input.computed.box.participation.semantics) {
        if (input.interactive) {
            if (input.accessible_name) |name| if (std.mem.trim(u8, name, " \t\r\n").len == 0) {
                issues[count] = .{ .kind = .missing_name };
                count += 1;
            };
        }
        if (input.has_text) {
            if (input.text_sample) |sample| {
                const ratio = try contrast(sample);
                if (ratio < input.text_minimum) {
                    issues[count] = .{ .kind = .low_text_contrast, .actual = ratio, .required = input.text_minimum };
                    count += 1;
                }
            } else {
                issues[count] = .{ .kind = .unknown_text_background };
                count += 1;
            }
        }
        if (input.interactive and input.states.focus_visible) {
            const visible = if (input.focus) |focus| focus.box.border > 0 and focus.box.border_color.a > 0 and focus.box.opacity > 0 and focus.box.participation.paint else false;
            if (!visible) {
                issues[count] = .{ .kind = .missing_focus_indicator };
                count += 1;
            } else if (input.focus_sample) |sample| {
                const ratio = try contrast(sample);
                if (ratio < input.focus_minimum) {
                    issues[count] = .{ .kind = .low_focus_contrast, .actual = ratio, .required = input.focus_minimum };
                    count += 1;
                }
            } else {
                issues[count] = .{ .kind = .unknown_focus_background };
                count += 1;
            }
        }
        if (input.interactive and input.minimum_target > 0) {
            if (input.bounds) |bounds| {
                const size = @min(bounds.w(), bounds.h());
                if (!std.math.isFinite(size) or size < 0) return error.InvalidSample;
                if (size < input.minimum_target) {
                    issues[count] = .{ .kind = .small_target, .actual = size, .required = input.minimum_target };
                    count += 1;
                }
            }
        }
    }
    if (destination.len < count) return error.NoSpace;
    @memcpy(destination[0..count], issues[0..count]);
    return destination[0..count];
}

test "diagnostics consume resolved high contrast recipes and keep unknown backgrounds explicit" {
    const recipes = @import("../theme/recipe.zig");
    const use: recipes.Use = .{ .states = .{ .focus_visible = true }, .environment = .{ .high_contrast = true, .reduced_transparency = true } };
    const root = try recipes.button.resolve(.from("root"), use, null);
    const focus = try recipes.button.resolve(.from("focus"), use, null);
    var issues: [6]Issue = undefined;
    const known = try check(.{ .computed = &root, .states = use.states, .interactive = true, .accessible_name = "Save", .text_sample = .{ .foreground = root.text.color, .background = root.box.fill }, .focus = &focus, .focus_sample = .{ .foreground = focus.box.border_color, .background = .black } }, &issues);
    try std.testing.expectEqual(@as(usize, 0), known.len);
    const unknown = try check(.{ .computed = &root }, &issues);
    try std.testing.expectEqual(Kind.unknown_text_background, unknown[0].kind);
    const invisible: properties.Computed = .{};
    const failed = try check(.{ .computed = &root, .interactive = true, .accessible_name = "", .states = use.states, .focus = &invisible, .text_sample = .{ .foreground = .rgba(255, 255, 255, 0), .background = .black } }, &issues);
    try std.testing.expectEqual(@as(usize, 3), failed.len);
    try std.testing.expectEqual(Kind.missing_name, failed[0].kind);
    try std.testing.expectEqual(Kind.low_text_contrast, failed[1].kind);
    try std.testing.expectEqual(Kind.missing_focus_indicator, failed[2].kind);
    try std.testing.expectError(error.NoSpace, check(.{ .computed = &root }, issues[0..0]));
}

test {
    std.testing.refAllDecls(@This());
}
