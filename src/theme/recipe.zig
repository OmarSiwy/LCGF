//! Component recipes are plain part defaults and ordered rules. The same resolver is usable
//! before runtime Frame calls, in comptime builders, and in caller-authored widgets.

const std = @import("std");
const types = @import("../core/types.zig");
const style = @import("../style/style.zig");
const theme = @import("theme.zig");
const accessibility = @import("../a11y/settings.zig");
const base = @import("../widgets/base.zig");
const button_zig = @import("../widgets/button.zig");
const checkbox_zig = @import("../widgets/checkbox.zig");
const slider_zig = @import("../widgets/slider.zig");
const switch_zig = @import("../widgets/switch.zig");
const progress_zig = @import("../widgets/progress.zig");
const textfield_zig = @import("../widgets/textfield.zig");
pub const Parts = style.Parts;
pub const Id = types.Id;
pub const States = style.States;
pub const Environment = style.environment.Environment;
pub const Rule = style.Rule;
pub const Declaration = style.Declaration;

pub const Names = struct {
    pub const text = Id.from("color.text");
    pub const surface = Id.from("color.surface");
    pub const control = Id.from("color.control");
    pub const hot = Id.from("color.control.hovered");
    pub const held = Id.from("color.control.held");
    pub const accent = Id.from("color.accent");
    pub const muted = Id.from("color.text.muted");
    pub const selection = Id.from("color.selection");
    pub const danger = Id.from("color.danger");
    pub const space = [5]Id{ .from("space.xs"), .from("space.sm"), .from("space.md"), .from("space.lg"), .from("space.xl") };
    pub const radius = [5]Id{ .from("radius.xs"), .from("radius.sm"), .from("radius.md"), .from("radius.lg"), .from("radius.xl") };
    pub const text_size = [5]Id{ .from("text.xs"), .from("text.sm"), .from("text.md"), .from("text.lg"), .from("text.xl") };
};
pub const token_count = 24;

/// Bridge existing theme tokens to semantic identifiers, with existing accessibility inputs.
/// The caller owns the returned array. Custom applications may supply any token table instead.
pub fn tokenRows(source_tokens: theme.Tokens, environment: Environment) [token_count]style.tokens.Entry {
    var tok = source_tokens;
    if ((environment.high_contrast orelse false) or (environment.forced_colors orelse false)) tok.palette = accessibility.high_contrast_palette;
    const roles = [6]Id{ Names.text, Names.surface, Names.control, Names.hot, Names.held, Names.accent };
    var rows: [token_count]style.tokens.Entry = undefined;
    for (roles, tok.palette, 0..) |id, value, i| {
        var color = value;
        if (i > 0 and i < 5 and (environment.reduced_transparency orelse false)) color.a = 255;
        rows[i] = style.tokens.literal(.fill, id, color);
    }
    const text = tok.color(.text);
    const accent = tok.color(.accent);
    rows[6] = style.tokens.literal(.text_color, Names.muted, .rgba(text.r, text.g, text.b, if (environment.high_contrast orelse false) 255 else 160));
    rows[7] = style.tokens.literal(.fill, Names.selection, .rgba(accent.r, accent.g, accent.b, if (environment.reduced_transparency orelse false) 255 else 96));
    rows[8] = style.tokens.literal(.fill, Names.danger, .rgb(220, 54, 68));
    for (0..5) |i| {
        rows[9 + i] = style.tokens.literal(.gap, Names.space[i], tok.space[i]);
        rows[14 + i] = style.tokens.literal(.radius, Names.radius[i], tok.radius[i]);
        rows[19 + i] = style.tokens.literal(.text_size, Names.text_size[i], tok.text_size[i] * environment.textFactor());
    }
    return rows;
}

pub const Part = struct { id: Id, base: style.Computed = .{} };
pub const Use = struct {
    tokens: style.tokens.Table = .{},
    scope: u32 = 0,
    variants: []const Id = &.{},
    states: States = .{},
    environment: Environment = .{},
    parent: ?*const style.Computed = null,
    local: []const Declaration = &.{},
};

pub const Recipe = struct {
    parts: []const Part = &.{},
    rules: []const Rule = &.{},

    pub fn baseFor(recipe: Recipe, part: Id) style.Computed {
        var computed: style.Computed = .{};
        for (recipe.parts) |row| if (row.id == part) {
            computed = row.base;
        };
        return computed;
    }

    pub fn resolve(recipe: Recipe, part: Id, use: Use, trace: ?[]style.Origin) style.Error!style.Computed {
        var default_tokens = if (use.environment.dark orelse true) theme.dark else theme.light;
        if (use.environment.accent) |accent| default_tokens.palette[@backingInt(theme.Role.accent)] = accent;
        const default_rows = tokenRows(default_tokens, use.environment);
        const default_scopes = [_]style.tokens.Scope{.{ .entries = &default_rows }};
        const table = if (use.tokens.scopes.len == 0) style.tokens.Table{ .scopes = &default_scopes } else use.tokens;
        return style.resolve(.{
            .base = recipe.baseFor(part),
            .parent = use.parent,
            .tokens = table,
            .scope = use.scope,
            .part = part,
            .variants = use.variants,
            .states = use.states,
            .environment = use.environment,
            .rules = recipe.rules,
            .local = use.local,
        }, trace);
    }
};

const text_rules = [_]Rule{
    .{ .part = Parts.root, .declarations = &.{ style.token(.text_color, Names.text), style.token(.text_size, Names.text_size[2]) }, .source = .from("control.typography") },
    .{ .part = Parts.label, .declarations = &.{style.inherit(.text_color)}, .source = .from("label.inherit") },
    .{ .part = Parts.placeholder, .declarations = &.{style.token(.text_color, Names.muted)}, .source = .from("placeholder") },
    .{ .part = Parts.focus, .declarations = &.{ style.set(.border_width, 0), style.token(.border_color, Names.accent), style.token(.radius, Names.radius[2]) } },
    .{ .part = Parts.focus, .require = .{ .focus_visible = true }, .declarations = &.{style.set(.border_width, 2)}, .source = .from("keyboard.focus") },
    .{ .part = Parts.root, .require = .{ .disabled = true }, .declarations = &.{style.token(.text_color, Names.muted)}, .source = .from("disabled.text") },
    .{ .part = Parts.root, .variants = &.{.from("small")}, .declarations = &.{style.token(.text_size, Names.text_size[1])}, .source = .from("size.small") },
    .{ .part = Parts.root, .variants = &.{.from("large")}, .declarations = &.{style.token(.text_size, Names.text_size[3])}, .source = .from("size.large") },
};

pub const button_rules = text_rules ++ [_]Rule{
    .{ .part = Parts.root, .declarations = &.{
        style.token(.fill, Names.control),           style.token(.radius, Names.radius[2]),
        style.token(.padding_left, Names.space[3]),  style.token(.padding_top, Names.space[3]),
        style.token(.padding_right, Names.space[3]), style.token(.padding_bottom, Names.space[3]),
    }, .source = .from("button.base") },
    .{ .part = Parts.root, .require = .{ .hovered = true }, .forbid = .{ .disabled = true }, .declarations = &.{style.token(.fill, Names.hot)}, .source = .from("button.hovered") },
    .{ .part = Parts.root, .require = .{ .held = true }, .forbid = .{ .disabled = true }, .declarations = &.{style.token(.fill, Names.held)}, .source = .from("button.held") },
    .{ .part = Parts.root, .require = .{ .selected = true }, .declarations = &.{ style.set(.border_width, 1), style.token(.border_color, Names.accent) }, .source = .from("button.selected") },
    .{ .part = Parts.root, .variants = &.{.from("destructive")}, .declarations = &.{ style.set(.border_width, 1), style.token(.border_color, Names.danger) }, .source = .from("intent.destructive") },
    .{ .part = Parts.root, .variants = &.{.from("compact")}, .declarations = &.{
        style.token(.padding_left, Names.space[1]),  style.token(.padding_top, Names.space[1]),
        style.token(.padding_right, Names.space[1]), style.token(.padding_bottom, Names.space[1]),
    }, .source = .from("density.compact") },
};

const label_part: Part = .{ .id = Parts.label, .base = .{ .box = .{ .role = .label } } };
const icon_part: Part = .{ .id = Parts.icon, .base = .{ .box = .{ .size = .{ .px(16), .px(16) } } } };
const focus_part: Part = .{ .id = Parts.focus, .base = .{ .box = .{ .float = true, .size = .{ .pct(1), .pct(1) } } } };

pub const button: Recipe = .{
    .parts = &.{ .{ .id = Parts.root, .base = .{ .box = button_zig.buttonStyle(&.default) } }, label_part, icon_part, focus_part },
    .rules = &button_rules,
};

pub const checkbox_rules = text_rules ++ [_]Rule{
    .{ .part = Parts.root, .declarations = &.{style.token(.gap, Names.space[2])} },
    .{ .part = Parts.background, .declarations = &.{ style.token(.fill, Names.control), style.token(.border_color, Names.hot) } },
    .{ .part = Parts.background, .require = .{ .checked = true }, .declarations = &.{style.token(.fill, Names.accent)} },
    .{ .part = Parts.background, .require = .{ .indeterminate = true }, .declarations = &.{style.token(.fill, Names.accent)} },
    .{ .part = Parts.indicator, .declarations = &.{style.set(.fill, .transparent)} },
    .{ .part = Parts.indicator, .require = .{ .indeterminate = true }, .declarations = &.{style.token(.fill, Names.text)} },
};
pub const checkbox: Recipe = .{
    .parts = &.{
        .{ .id = Parts.root, .base = .{ .box = checkbox_zig.checkboxStyle(&.default) } },
        .{ .id = Parts.background, .base = .{ .box = checkbox_zig.checkboxBox(&.default, .off) } },
        .{ .id = Parts.indicator, .base = .{ .box = checkbox_zig.checkboxDash(&.default, .off) } },
        label_part,
        icon_part,
        focus_part,
    },
    .rules = &checkbox_rules,
};

pub const switch_rules = text_rules ++ [_]Rule{
    .{ .part = Parts.root, .declarations = &.{style.token(.gap, Names.space[2])} },
    .{ .part = Parts.track, .declarations = &.{ style.token(.fill, Names.control), style.set(.main_align, .start) } },
    .{ .part = Parts.track, .require = .{ .checked = true }, .declarations = &.{ style.token(.fill, Names.accent), style.set(.main_align, .end) } },
    .{ .part = Parts.thumb, .declarations = &.{style.token(.fill, Names.text)} },
};
pub const switch_control: Recipe = .{
    .parts = &.{
        .{ .id = Parts.root, .base = .{ .box = switch_zig.switchStyle(&.default) } },
        .{ .id = Parts.track, .base = .{ .box = switch_zig.trackStyle(&.default, false) } },
        .{ .id = Parts.thumb, .base = .{ .box = switch_zig.knobStyle(&.default) } },
        label_part,
        icon_part,
        focus_part,
    },
    .rules = &switch_rules,
};

pub const slider_rules = text_rules ++ [_]Rule{
    .{ .part = Parts.root, .declarations = &.{style.token(.fill, Names.control)} },
    .{ .part = Parts.fill, .declarations = &.{style.token(.fill, Names.accent)} },
    .{ .part = Parts.thumb, .declarations = &.{style.token(.fill, Names.text)} },
    .{ .part = Parts.tick, .declarations = &.{style.token(.fill, Names.muted)} },
};
pub const slider: Recipe = .{
    .parts = &.{
        .{ .id = Parts.root, .base = .{ .box = slider_zig.sliderTrack(&.default) } },
        .{ .id = Parts.fill, .base = .{ .box = slider_zig.sliderThumb(&.default, 0) } },
        .{ .id = Parts.thumb, .base = .{ .box = .{ .size = .{ .px(12), .px(12) }, .radius = 6, .float = true } } },
        .{ .id = Parts.tick, .base = .{ .box = .{ .size = .{ .px(1), .px(8) }, .float = true } } },
        label_part,
        icon_part,
        focus_part,
    },
    .rules = &slider_rules,
};

pub const progress: Recipe = .{
    .parts = &.{
        .{ .id = Parts.root, .base = .{ .box = progress_zig.trackStyle(&.default) } },
        .{ .id = Parts.fill, .base = .{ .box = progress_zig.barStyle(&.default, 0) } },
        label_part,
        icon_part,
    },
    .rules = &slider_rules,
};

pub const input_rules = text_rules ++ [_]Rule{
    .{ .part = Parts.root, .declarations = &.{ style.token(.fill, Names.held), style.token(.border_color, Names.hot), style.token(.radius, Names.radius[2]) } },
    .{ .part = Parts.root, .require = .{ .focused = true }, .declarations = &.{style.token(.border_color, Names.accent)} },
    .{ .part = Parts.root, .require = .{ .invalid = true }, .declarations = &.{style.token(.border_color, Names.danger)} },
    .{ .part = Parts.selection, .declarations = &.{style.token(.fill, Names.selection)} },
    .{ .part = Parts.caret, .declarations = &.{style.set(.fill, .transparent)} },
    .{ .part = Parts.caret, .require = .{ .focused = true }, .forbid = .{ .disabled = true }, .declarations = &.{style.token(.fill, Names.text)} },
    .{ .part = Parts.support, .declarations = &.{ style.token(.text_color, Names.muted), style.token(.text_size, Names.text_size[1]) } },
    .{ .part = Parts.support, .require = .{ .invalid = true }, .declarations = &.{style.token(.text_color, Names.danger)} },
};
pub const input: Recipe = .{
    .parts = &.{
        .{ .id = Parts.root, .base = .{ .box = textfield_zig.fieldStyle(&.default, false, 0) } },
        .{ .id = Parts.content },
        .{ .id = Parts.placeholder },
        .{ .id = Parts.selection, .base = .{ .box = textfield_zig.selectionStyle(&.default, .{ 0, 0 }, 0) } },
        .{ .id = Parts.caret, .base = .{ .box = textfield_zig.caretStyle(&.default, 0, 0, false) } },
        .{ .id = Parts.support, .base = .{ .box = .{ .role = .label } } },
        label_part,
        icon_part,
        focus_part,
    },
    .rules = &input_rules,
};

/// Adapt a computed root to widgets whose existing behavior uses Theme for metrics. Visual
/// part values still come from the recipe; this does not reduce recipes to Theme's palette.
pub fn metrics(computed: style.Computed) base.Theme {
    var th: base.Theme = .default;
    th.text = computed.text.color;
    th.text_px = computed.text.px;
    th.pad = computed.box.pad[0];
    th.gap = computed.box.gap;
    th.radius = computed.box.radius;
    return th;
}

test "recipe caller: custom thumb and app-defined part use direct data, no registry" {
    const custom_rules = slider_rules ++ [_]Rule{
        .{ .part = Parts.thumb, .declarations = &.{ style.set(.fill, .rgb(250, 180, 20)), style.set(.radius, 0) } },
        .{ .part = .from("wire.port"), .declarations = &.{style.set(.fill, .rgb(10, 200, 150))} },
    };
    const custom: Recipe = .{ .parts = slider.parts, .rules = &custom_rules };
    const thumb = try custom.resolve(Parts.thumb, .{}, null);
    try std.testing.expectEqual(types.Color.rgb(250, 180, 20), thumb.box.fill);
    try std.testing.expectEqual(@as(f32, 0), thumb.box.radius);
    try std.testing.expectEqual(types.Color.rgb(10, 200, 150), (try custom.resolve(.from("wire.port"), .{}, null)).box.fill);
}

test "default recipe respects environment text scale and keeps focus separate from selected border" {
    const root = try button.resolve(Parts.root, .{ .states = .{ .selected = true, .hovered = true, .focus_visible = true }, .environment = .{ .text_scale = 2 } }, null);
    const focus = try button.resolve(Parts.focus, .{ .states = .{ .focus_visible = true } }, null);
    try std.testing.expectEqual(@as(f32, 28), root.text.px);
    try std.testing.expectEqual(@as(f32, 1), root.box.border);
    try std.testing.expectEqual(@as(f32, 2), focus.box.border);
    try std.testing.expect(focus.box.float);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Recipe);
}
