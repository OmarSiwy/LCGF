//! Style diagnostics over explicit known samples and semantic inputs. This is diagnostic
//! data, not a compliance certification. Unknown image/filter backdrops remain unknown.
//! Hosts can supply sampled final colors instead of guessing from a complex paint graph.

const std = @import("std");
const types = @import("../core/types.zig");
const properties = @import("properties.zig");
const resolution = @import("resolve.zig");
const settings = @import("../a11y/settings.zig");
const a11y = @import("../a11y/tree.zig");

pub const Kind = enum { missing_name, unknown_text_background, low_text_contrast, missing_focus_indicator, unknown_focus_background, low_focus_contrast, small_target, semantic_mismatch, insufficient_focus_area };
/// These labels identify the evaluated condition, not certification of the whole criterion.
/// Text thresholds remain caller policy because text size, weight and exceptions matter.
pub const Criterion = enum { application_policy, text_contrast, focus_visible_aa, non_text_contrast_aa, focus_appearance_aaa, semantic_consistency };
pub const SemanticField = enum { disabled, read_only, selected, checked, mixed, expanded, current, pressed, focused, invalid, required, busy };
pub const Issue = struct {
    kind: Kind,
    criterion: Criterion = .application_policy,
    field: ?SemanticField = null,
    actual: f32 = 0,
    required: f32 = 0,
};
pub const Sample = struct {
    foreground: types.Color,
    /// Must be opaque. The supplied foreground is composited onto this known background.
    background: types.Color,
};
pub const Input = struct {
    computed: *const properties.Computed,
    states: resolution.States = .{},
    /// Actual exported semantics, when available. A mismatch is reported even when visual
    /// requirements are skipped for a disabled control. Null means no comparison was made.
    semantic_state: ?a11y.State = null,
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
pub const max_issues = 6 + @typeInfo(SemanticField).@"enum".field_names.len;

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

/// At most `max_issues` rows. No allocation and no writes to the widget or its semantics.
/// Disabled controls skip text/focus/target requirements; style cannot make them actionable.
pub fn check(input: Input, destination: []Issue) Error![]const Issue {
    if (!std.math.isFinite(input.text_minimum) or input.text_minimum < 1 or !std.math.isFinite(input.focus_minimum) or input.focus_minimum < 1 or !std.math.isFinite(input.minimum_target) or input.minimum_target < 0) return error.InvalidSample;
    var issues: [max_issues]Issue = undefined;
    var count: usize = 0;
    if (input.semantic_state) |semantic| {
        inline for (@typeInfo(SemanticField).@"enum".field_names) |name| {
            const actual = @field(semantic, name);
            const expected = if (comptime std.mem.eql(u8, name, "mixed")) input.states.indeterminate else if (comptime std.mem.eql(u8, name, "pressed")) input.states.toggled else @field(input.states, name);
            if (actual != expected) {
                issues[count] = .{ .kind = .semantic_mismatch, .criterion = .semantic_consistency, .field = @field(SemanticField, name), .actual = @floatFromInt(@intFromBool(actual)), .required = @floatFromInt(@intFromBool(expected)) };
                count += 1;
            }
        }
    }
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
                    issues[count] = .{ .kind = .low_text_contrast, .criterion = .text_contrast, .actual = ratio, .required = input.text_minimum };
                    count += 1;
                }
            } else {
                issues[count] = .{ .kind = .unknown_text_background, .criterion = .text_contrast };
                count += 1;
            }
        }
        if (input.interactive and input.states.focus_visible) {
            const visible = if (input.focus) |focus| focus.box.border > 0 and focus.box.border_color.a > 0 and focus.box.opacity > 0 and focus.box.participation.paint else false;
            if (!visible) {
                issues[count] = .{ .kind = .missing_focus_indicator, .criterion = .focus_visible_aa };
                count += 1;
            } else if (input.focus_sample) |sample| {
                const ratio = try contrast(sample);
                if (ratio < input.focus_minimum) {
                    issues[count] = .{ .kind = .low_focus_contrast, .criterion = .non_text_contrast_aa, .actual = ratio, .required = input.focus_minimum };
                    count += 1;
                }
            } else {
                issues[count] = .{ .kind = .unknown_focus_background, .criterion = .non_text_contrast_aa };
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

/// Perceived unfocused component geometry in logical CSS-equivalent pixels. Use a host's
/// logical-to-CSS conversion before calling when those units differ. Complex shapes may use
/// their minimum bounding rectangle. Shadows and glow are excluded from the component.
pub const FocusShape = union(enum) {
    rectangle: types.Rect,
    circle: f32,
    rounded_rectangle: struct { bounds: types.Rect, radius: f32 },

    pub fn minimumArea(shape: FocusShape) Error!f32 {
        const value = switch (shape) {
            .rectangle => |bounds| try rectangleArea(bounds),
            .circle => |radius| blk: {
                if (!std.math.isFinite(radius) or radius <= 0) return error.InvalidSample;
                break :blk 4 * std.math.pi * radius;
            },
            .rounded_rectangle => |rounded| blk: {
                const rectangle = try rectangleArea(rounded.bounds);
                if (!std.math.isFinite(rounded.radius) or rounded.radius < 0 or rounded.radius > @min(rounded.bounds.w(), rounded.bounds.h()) / 2) return error.InvalidSample;
                break :blk rectangle - (16 - 4 * std.math.pi) * rounded.radius;
            },
        };
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidSample;
        return value;
    }
};

fn rectangleArea(bounds: types.Rect) Error!f32 {
    if (!std.math.isFinite(bounds.w()) or !std.math.isFinite(bounds.h()) or bounds.w() <= 0 or bounds.h() <= 0) return error.InvalidSample;
    return 4 * bounds.w() + 4 * bounds.h();
}

/// A non-overlapping region of the same pixels before and after focus. Supply final opaque
/// colors and logical area after clipping/occlusion; overlapping rows must not double-count.
/// This is deliberately different from the adjacent-background pair used by `check`.
pub const ChangedRegion = struct { area: f32, before: types.Color, after: types.Color };
pub const FocusExemption = enum { none, unadjustable_user_agent, unmodified_user_agent_indicator_and_background };
pub const FocusAppearance = struct {
    minimum_area: f32,
    qualifying_area: f32,
    exempt: bool,
    passes: bool,
    issue: ?Issue,
};

/// WCAG 2.2 2.4.13 (AAA) changed-pixel area, separately from 2.4.7 (AA) visibility and
/// 1.4.11 (AA) adjacent contrast. Caller observations determine regions and exceptions.
/// https://www.w3.org/WAI/WCAG22/Understanding/focus-appearance.html
pub fn focusAppearance(shape: FocusShape, regions: []const ChangedRegion, exemption: FocusExemption) Error!FocusAppearance {
    const minimum = try shape.minimumArea();
    var qualifying: f32 = 0;
    for (regions) |region| {
        if (!std.math.isFinite(region.area) or region.area < 0 or region.before.a != 255 or region.after.a != 255) return error.InvalidSample;
        if (try contrast(.{ .foreground = region.after, .background = region.before }) >= settings.non_text) qualifying += region.area;
        if (!std.math.isFinite(qualifying)) return error.InvalidSample;
    }
    const exempt = exemption != .none;
    const passes = exempt or qualifying >= minimum;
    return .{
        .minimum_area = minimum,
        .qualifying_area = qualifying,
        .exempt = exempt,
        .passes = passes,
        .issue = if (passes) null else .{ .kind = .insufficient_focus_area, .criterion = .focus_appearance_aaa, .actual = qualifying, .required = minimum },
    };
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
    try std.testing.expectEqual(Criterion.focus_visible_aa, failed[2].criterion);
    try std.testing.expectError(error.NoSpace, check(.{ .computed = &root }, issues[0..0]));
}

test "diagnostics compare recipe state with actual exported semantics including validation and busy" {
    const mem = @import("../core/mem.zig");
    const tree = @import("../core/tree.zig");
    const Texts = @import("../core/texts.zig").Texts;
    const controls = @import("../theme/recipe_controls.zig");
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = tree.Tree.init(&carver, 8);
    const tx = Texts.init(&carver, 1);
    var semantic = a11y.Semantics.init(&carver, 8);
    semantic.clear();
    var exported = a11y.Export.init(&carver, 8);
    const root = t.push(0, .from("email"), &.{ .role = .text_input });
    t.seal(root);
    const state: resolution.States = .{ .disabled = true, .read_only = true, .invalid = true, .required = true, .busy = true };
    controls.expose(&semantic, @fromBackingInt(root), state);
    a11y.names(&t, &semantic);
    a11y.states(&t, &semantic);
    a11y.flatten(&t, &tx, "", &semantic, &exported);
    const actual: a11y.State = @bitCast(exported.c.state[0]);
    var issues: [max_issues]Issue = undefined;
    const good = try check(.{ .computed = &.{}, .states = state, .semantic_state = actual, .has_text = false }, &issues);
    try std.testing.expectEqual(@as(usize, 0), good.len);
    var missing = actual;
    missing.busy = false;
    const bad = try check(.{ .computed = &.{}, .states = state, .semantic_state = missing, .has_text = false }, &issues);
    try std.testing.expectEqual(@as(usize, 1), bad.len);
    try std.testing.expectEqual(Kind.semantic_mismatch, bad[0].kind);
    try std.testing.expectEqual(SemanticField.busy, bad[0].field.?);
    try std.testing.expectEqual(Criterion.semantic_consistency, bad[0].criterion);
    try std.testing.expectEqual(@as(f32, 1), bad[0].required);
}

test "native outline can satisfy AA focus visibility while failing the separate AAA area diagnostic" {
    const mem = @import("../core/mem.zig");
    const tree = @import("../core/tree.zig");
    const Texts = @import("../core/texts.zig").Texts;
    const Customs = @import("../core/customs.zig").Customs;
    const DrawList = @import("../draw/draw_list.zig").DrawList;
    var raw: [64 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    var t = tree.Tree.init(&carver, 8);
    var tx = Texts.init(&carver, 1);
    const customs = Customs.init(&carver, 1);
    var draw = DrawList.init(&carver, 8, 1, 1);
    const root = t.push(0, .none, &.{ .size = .{ .px(200), .px(100) }, .pad = @splat(10) });
    const button = t.push(root, .from("save"), &.{ .size = .{ .px(80), .px(40) }, .fill = .white });
    _ = @import("../draw/outline.zig").append(&t, button, @fromBackingInt(button), .{ .width = 1, .color = .black });
    t.seal(button);
    t.seal(root);
    @import("../layout/layout.zig").run(&t, &tx, .{ 200, 100 });
    @import("../draw/paint.zig").emit(&t, &tx, &customs, "", &draw);
    const outer = draw.quads[draw.quad_len - 1].rect;
    const bounds = t.rect(button);
    const area = (outer[2] - outer[0]) * (outer[3] - outer[1]) - bounds.w() * bounds.h();
    const indicator: properties.Computed = .{ .box = .{ .border = 1, .border_color = .black } };
    var issues: [max_issues]Issue = undefined;
    const visible = try check(.{ .computed = &.{}, .interactive = true, .states = .{ .focus_visible = true }, .has_text = false, .focus = &indicator, .focus_sample = .{ .foreground = .black, .background = .white } }, &issues);
    try std.testing.expectEqual(@as(usize, 0), visible.len);
    const appearance = try focusAppearance(.{ .rectangle = bounds }, &.{.{ .area = area, .before = .white, .after = .black }}, .none);
    try std.testing.expectEqual(@as(f32, 480), appearance.minimum_area);
    try std.testing.expectEqual(@as(f32, 244), appearance.qualifying_area);
    try std.testing.expect(!appearance.passes);
    try std.testing.expectEqual(Criterion.focus_appearance_aaa, appearance.issue.?.criterion);
    const sufficient = try focusAppearance(.{ .rectangle = bounds }, &.{ .{ .area = 480, .before = .white, .after = .black }, .{ .area = 1000, .before = .white, .after = .white } }, .none);
    try std.testing.expect(sufficient.passes);
    try std.testing.expectEqual(@as(f32, 480), sufficient.qualifying_area);
    try std.testing.expect((try focusAppearance(.{ .rectangle = bounds }, &.{}, .unadjustable_user_agent)).exempt);
    try std.testing.expectError(error.InvalidSample, focusAppearance(.{ .rectangle = bounds }, &.{.{ .area = 480, .before = .white, .after = .rgba(0, 0, 0, 128) }}, .none));
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(FocusShape);
}
