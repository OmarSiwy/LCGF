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
const link_zig = @import("../widgets/link.zig");
pub const Parts = style.Parts;
pub const Id = types.Id;
pub const States = style.States;
pub const Environment = style.environment.Environment;
pub const Rule = style.Rule;
pub const Declaration = style.Declaration;
pub const ColorPolicy = style.system_colors.Policy;

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
    if ((environment.high_contrast orelse false) or (environment.forced_colors orelse false)) {
        const colors = environment.system_colors orelse style.system_colors.highContrast(environment.dark orelse true);
        tok.palette = .{ colors.get(.canvas_text), colors.get(.canvas), colors.get(.button_face), colors.get(.button_border), colors.get(.field), colors.get(.accent) };
    }
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
    color_policy: ColorPolicy = .automatic,
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
        if (use.color_policy == .automatic and ((use.environment.high_contrast orelse false) or (use.environment.forced_colors orelse false))) {
            if (use.environment.system_colors) |colors| if (!colors.isOpaque()) return error.InvalidValue;
        }
        var default_tokens = if (use.environment.dark orelse true) theme.dark else theme.light;
        if (use.environment.accent) |accent| default_tokens.palette[@backingInt(theme.Role.accent)] = accent;
        var token_environment = use.environment;
        if (use.color_policy == .preserve) {
            token_environment.high_contrast = false;
            token_environment.forced_colors = false;
        }
        const default_rows = tokenRows(default_tokens, token_environment);
        const default_scopes = [_]style.tokens.Scope{.{ .entries = &default_rows }};
        const table = if (use.tokens.scopes.len == 0) style.tokens.Table{ .scopes = &default_scopes } else use.tokens;
        var computed = try style.resolve(.{
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
        if (use.color_policy == .automatic and ((use.environment.high_contrast orelse false) or (use.environment.forced_colors orelse false))) {
            const colors = use.environment.system_colors orelse style.system_colors.highContrast(use.environment.dark orelse true);
            applySystem(&computed, part, use, colors, trace);
        }
        return computed;
    }
};

fn systemWrite(computed: *style.Computed, comptime property: style.Property, value: style.properties.Type(property), trace: ?[]style.Origin) void {
    style.properties.write(property, computed, value);
    if (trace) |rows| rows[@backingInt(property)] = .{ .mode = .literal, .source = .from("system.colors") };
}

/// A final semantic paint policy, after authored declarations. The explicit preserve
/// exception is per component; layout, spacing, typography and input state are untouched.
fn applySystem(computed: *style.Computed, part: Id, use: Use, colors: style.system_colors.Colors, trace: ?[]style.Origin) void {
    const states = use.states;
    const inherited = if (use.parent) |parent| parent.text.color else colors.get(.canvas_text);
    if (part == Parts.root) {
        const role = computed.box.role;
        const input_control = role == .text_input;
        const button_control = role == .button;
        const face = colors.get(if (input_control) .field else if (button_control) .button_face else .canvas);
        if (computed.box.fill.a > 0 or input_control or button_control) systemWrite(computed, .fill, face, trace);
        systemWrite(computed, .text_color, colors.get(if (states.disabled) .gray_text else if (input_control) .field_text else if (button_control) .button_text else .canvas_text), trace);
        if (input_control or button_control or computed.box.border > 0) {
            systemWrite(computed, .border_width, @max(computed.box.border, 1), trace);
            systemWrite(computed, .border_color, colors.get(if (states.focused or states.hovered or states.selected) .highlight else .button_border), trace);
        }
        if (button_control and states.held and !states.disabled) {
            systemWrite(computed, .fill, colors.get(.highlight), trace);
            systemWrite(computed, .text_color, colors.get(.highlight_text), trace);
        }
    } else if (part == Parts.focus) {
        systemWrite(computed, .border_color, colors.get(.highlight), trace);
    } else if (part == Parts.selection) {
        systemWrite(computed, .fill, colors.get(.highlight), trace);
        systemWrite(computed, .text_color, colors.get(.highlight_text), trace);
    } else if (part == Parts.background or part == Parts.track) {
        systemWrite(computed, .fill, colors.get(if (states.checked or states.indeterminate) .accent else .button_face), trace);
        systemWrite(computed, .border_width, @max(computed.box.border, 1), trace);
        systemWrite(computed, .border_color, colors.get(.button_border), trace);
    } else if (part == Parts.indicator or part == Parts.thumb) {
        if (computed.box.fill.a > 0) systemWrite(computed, .fill, colors.get(if (states.checked or states.indeterminate) .accent_text else .button_text), trace);
    } else if (part == Parts.fill) {
        systemWrite(computed, .fill, colors.get(.accent), trace);
    } else if (part == Parts.caret or part == Parts.tick or part == Parts.separator or part == Parts.disclosure) {
        if (computed.box.fill.a > 0) systemWrite(computed, .fill, inherited, trace);
    } else if (part == Parts.row or part == Parts.cell) {
        if (states.selected) {
            systemWrite(computed, .fill, colors.get(.selected_item), trace);
            systemWrite(computed, .text_color, colors.get(.selected_item_text), trace);
        } else {
            if (computed.box.fill.a > 0) systemWrite(computed, .fill, colors.get(.canvas), trace);
            systemWrite(computed, .text_color, inherited, trace);
        }
        if (computed.box.border > 0) systemWrite(computed, .border_color, colors.get(.button_border), trace);
    } else {
        systemWrite(computed, .text_color, if (states.disabled) colors.get(.gray_text) else inherited, trace);
        if (computed.box.fill.a > 0) systemWrite(computed, .fill, colors.get(if (part == Parts.icon) .button_text else .canvas), trace);
    }
}

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

/// A pressed toggle button (`States.toggled`) takes the accent, and the held colour while held,
/// as `toggle.toggleFills`.
pub const toggle_rules = button_rules ++ [_]Rule{
    .{ .part = Parts.root, .require = .{ .toggled = true }, .forbid = .{ .disabled = true }, .declarations = &.{style.token(.fill, Names.accent)}, .source = .from("toggle.pressed") },
    .{ .part = Parts.root, .require = .{ .toggled = true, .held = true }, .forbid = .{ .disabled = true }, .declarations = &.{style.token(.fill, Names.held)}, .source = .from("toggle.held") },
};
pub const toggle: Recipe = .{ .parts = button.parts, .rules = &toggle_rules };

/// A link: no fill at rest, the control's hover and held colours, its text in the accent
/// (`link.linkFill`, `link.linkText`).
pub const link_rules = text_rules ++ [_]Rule{
    .{ .part = Parts.root, .declarations = &.{ style.set(.fill, .transparent), style.token(.text_color, Names.accent) }, .source = .from("link.base") },
    .{ .part = Parts.root, .require = .{ .hovered = true }, .forbid = .{ .disabled = true }, .declarations = &.{style.token(.fill, Names.hot)}, .source = .from("link.hovered") },
    .{ .part = Parts.root, .require = .{ .held = true }, .forbid = .{ .disabled = true }, .declarations = &.{style.token(.fill, Names.held)}, .source = .from("link.held") },
};
pub const link: Recipe = .{
    .parts = &.{ .{ .id = Parts.root, .base = .{ .box = link_zig.linkStyle(&.default) } }, label_part, icon_part, focus_part },
    .rules = &link_rules,
};

pub const checkbox_rules = text_rules ++ [_]Rule{
    .{ .part = Parts.root, .declarations = &.{style.token(.gap, Names.space[2])} },
    .{ .part = Parts.background, .declarations = &.{ style.token(.fill, Names.control), style.token(.border_color, Names.hot) } },
    .{ .part = Parts.background, .require = .{ .checked = true }, .declarations = &.{style.token(.fill, Names.accent)} },
    .{ .part = Parts.background, .require = .{ .indeterminate = true }, .declarations = &.{style.token(.fill, Names.accent)} },
    .{ .part = Parts.indicator, .declarations = &.{style.set(.fill, .transparent)} },
    .{ .part = Parts.indicator, .require = .{ .checked = true }, .declarations = &.{ style.token(.fill, Names.text), style.set(.height, .px(8)) }, .source = .from("checked.shape") },
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

pub const navigation_rules = button_rules ++ [_]Rule{
    .{ .part = Parts.root, .declarations = &.{ style.set(.padding_top, 6), style.set(.padding_bottom, 6), style.token(.gap, Names.space[2]) } },
    .{ .part = Parts.root, .require = .{ .current = true }, .declarations = &.{ style.token(.fill, Names.surface), style.token(.text_color, Names.accent) } },
    .{ .part = Parts.indicator, .declarations = &.{style.set(.fill, .transparent)} },
    .{ .part = Parts.indicator, .require = .{ .selected = true }, .declarations = &.{style.token(.fill, Names.accent)} },
    .{ .part = Parts.indicator, .require = .{ .expanded = true }, .declarations = &.{style.token(.fill, Names.text)} },
};
/// The item, label, optional icon, state indicator and outside focus are separate parts.
pub const navigation: Recipe = .{
    .parts = &.{
        .{ .id = Parts.root, .base = .{ .box = .{ .dir = .x, .cross = .center, .size = .{ .fit, .fit } } } },
        .{ .id = Parts.indicator, .base = .{ .box = .{ .size = .{ .px(6), .px(6) }, .radius = 3 } } },
        label_part,
        icon_part,
        focus_part,
    },
    .rules = &navigation_rules,
};

pub const data_rules = text_rules ++ [_]Rule{
    .{ .part = Parts.root, .declarations = &.{style.token(.fill, Names.surface)} },
    .{ .part = Parts.header, .declarations = &.{style.token(.fill, Names.control)} },
    .{ .part = Parts.row, .require = .{ .selected = true }, .declarations = &.{style.token(.fill, Names.held)} },
    .{ .part = Parts.cell, .require = .{ .selected = true }, .declarations = &.{ style.token(.fill, Names.accent), style.token(.text_color, Names.text) } },
    .{ .part = Parts.cell, .require = .{ .invalid = true }, .declarations = &.{ style.set(.border_width, 1), style.token(.border_color, Names.danger) } },
    .{ .part = Parts.disclosure, .declarations = &.{style.token(.fill, Names.muted)} },
    .{ .part = Parts.disclosure, .require = .{ .expanded = true }, .declarations = &.{style.token(.fill, Names.accent)} },
    .{ .part = Parts.separator, .declarations = &.{style.token(.fill, Names.control)} },
};
/// Passive table/tree/list parts. Existing data widgets' sorting, navigation and selection
/// functions remain independently callable; callers assign their resulting states here.
pub const data: Recipe = .{
    .parts = &.{
        .{ .id = Parts.root, .base = .{ .box = .{ .dir = .y, .size = .{ .fill, .fit }, .role = .group } } },
        .{ .id = Parts.header, .base = .{ .box = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(6) } } },
        .{ .id = Parts.row, .base = .{ .box = .{ .dir = .x, .size = .{ .fill, .fit } } } },
        .{ .id = Parts.cell, .base = .{ .box = .{ .dir = .y, .size = .{ .fill, .fit }, .pad = @splat(6), .clip = true } } },
        .{ .id = Parts.disclosure, .base = .{ .box = .{ .size = .{ .px(8), .px(8) }, .radius = 2 } } },
        .{ .id = Parts.separator, .base = .{ .box = .{ .size = .{ .fill, .px(1) } } } },
        label_part,
        icon_part,
        focus_part,
    },
    .rules = &data_rules,
};

pub const gutter = Id.from("gutter");
pub const line_number = Id.from("line-number");
pub const editor_rules = input_rules ++ [_]Rule{
    .{ .part = gutter, .declarations = &.{style.token(.fill, Names.surface)} },
    .{ .part = line_number, .declarations = &.{style.token(.text_color, Names.muted)} },
};
/// Multiline editing shares the text input's error/placeholder/selection/caret/support rules.
pub const editor: Recipe = .{
    .parts = &.{
        .{ .id = Parts.root, .base = .{ .box = blk: {
            var box = textfield_zig.fieldStyle(&.default, false, 0);
            box.dir = .y;
            break :blk box;
        } } },
        .{ .id = Parts.content },
        .{ .id = Parts.placeholder },
        .{ .id = Parts.selection, .base = .{ .box = textfield_zig.selectionStyle(&.default, .{ 0, 0 }, 0) } },
        .{ .id = Parts.caret, .base = .{ .box = textfield_zig.caretStyle(&.default, 0, 0, false) } },
        .{ .id = Parts.support, .base = .{ .box = .{ .role = .label } } },
        .{ .id = gutter, .base = .{ .box = .{ .dir = .y, .size = .{ .fit, .fill }, .pad = .{ 6, 0, 6, 0 } } } },
        .{ .id = line_number, .base = .{ .box = .{ .role = .label, .size = .{ .fit, .fit } } } },
        label_part,
        icon_part,
        focus_part,
    },
    .rules = &editor_rules,
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

test "system colors override authored paint with provenance and explicit component exceptions" {
    var system = style.system_colors.highContrast(false);
    system.set(.button_face, .rgb(240, 250, 255));
    system.set(.button_text, .rgb(10, 20, 30));
    system.set(.button_border, .rgb(20, 40, 60));
    const use: Use = .{ .environment = .{ .dark = false, .forced_colors = true, .system_colors = system }, .local = &.{style.set(.fill, .rgb(220, 40, 30))} };
    var trace: [style.properties.count]style.Origin = undefined;
    const system_button = try button.resolve(Parts.root, use, &trace);
    try std.testing.expectEqual(system.get(.button_face), system_button.box.fill);
    try std.testing.expectEqual(system.get(.button_text), system_button.text.color);
    try std.testing.expect(system_button.box.border >= 1);
    try std.testing.expectEqual(Id.from("system.colors"), trace[@backingInt(style.Property.fill)].source);
    var exception = use;
    exception.color_policy = .preserve;
    try std.testing.expectEqual(types.Color.rgb(220, 40, 30), (try button.resolve(Parts.root, exception, null)).box.fill);
    for ([_]bool{ false, true }) |dark| {
        const profile: Use = .{ .environment = .{ .dark = dark, .high_contrast = true } };
        const root = try button.resolve(Parts.root, profile, null);
        try std.testing.expect(accessibility.contrast(root.text.color, root.box.fill) >= 7);
        try std.testing.expect(accessibility.contrast(root.box.border_color, root.box.fill) >= 3);
        var checked = profile;
        checked.states.checked = true;
        const mark = try checkbox.resolve(Parts.indicator, checked, null);
        const surface = try checkbox.resolve(Parts.background, checked, null);
        try std.testing.expect(mark.box.fill.a > 0 and mark.box.size[1].v == 8);
        try std.testing.expect(accessibility.contrast(mark.box.fill, surface.box.fill) >= 3);
    }
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Recipe);
}
