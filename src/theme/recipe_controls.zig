//! Runtime conveniences over existing widget behavior and the plain recipe resolver. The
//! open/content/end calls let an application replace content without copying input behavior.

const std = @import("std");
const types = @import("../core/types.zig");
const style = @import("../style/style.zig");
const model = @import("recipe.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const a11y = @import("../a11y/tree.zig");
const base = @import("../widgets/base.zig");
const button_zig = @import("../widgets/button.zig");
const checkbox_zig = @import("../widgets/checkbox.zig");
const slider_zig = @import("../widgets/slider.zig");
const switch_zig = @import("../widgets/switch.zig");
const progress_zig = @import("../widgets/progress.zig");
const textfield_zig = @import("../widgets/textfield.zig");
const Parts = style.Parts;

pub const Options = struct {
    recipe: ?model.Recipe = null,
    tokens: style.tokens.Table = .{},
    scope: u32 = 0,
    variants: []const types.Id = &.{},
    /// One authoritative input: disabled/read_only affect behavior and accessibility too.
    /// Hover, held, focused and focus-visible come from the actual interaction each frame.
    states: style.States = .{},
    environment: ?model.Environment = null,
    /// Local root overrides. Named child parts are customized in the recipe's rules.
    local: []const style.Declaration = &.{},
    semantics: ?*a11y.Semantics = null,
    /// Gap between the control's border box and its independently painted focus outline.
    focus_offset: f32 = 0,
    color_policy: model.ColorPolicy = .automatic,
};

pub const OpenControl = struct {
    node: types.Node,
    response: types.Response,
    states: style.States,
    root: style.Computed,
    label: style.Computed,
    focus: style.Computed,
    recipe: model.Recipe,
    use: model.Use,
    focus_offset: f32 = 0,

    /// Resolve any standard or application-defined part with this control's state and theme.
    pub fn part(control: *const OpenControl, id: types.Id, trace: ?[]style.Origin) style.Error!style.Computed {
        var use = control.use;
        use.parent = &control.root;
        use.local = &.{};
        return control.recipe.resolve(id, use, trace);
    }
};

/// Cancel capture when a control becomes disabled so re-enabling it during the same press
/// cannot resurrect a click. These are the public interaction rows the caller already owns.
pub fn responseFor(f: *Frame, id: types.Id, disabled: bool) types.Response {
    if (!disabled) return f.ctx.inter.response(id);
    const interaction = &f.ctx.inter;
    const value = @backingInt(id);
    if (interaction.hot == value) interaction.hot_node = types.none;
    if (interaction.active == value) interaction.active_node = types.none;
    inline for (.{ "hot", "under", "active", "focus", "pressed", "released", "clicked", "double_clicked", "long_pressed", "dragging", "hover_intent" }) |name| {
        if (@field(interaction, name) == value) @field(interaction, name) = 0;
    }
    return .{};
}

pub fn environmentFor(f: *const Frame, options: Options) model.Environment {
    return options.environment orelse model.Environment.fromInput(f.in).withSettings(&f.ctx.settings);
}

pub fn visibleFocus(f: *const Frame, options: Options) bool {
    return f.ctx.focus.visible or (environmentFor(f, options).always_show_focus orelse false);
}

/// Resolve the pre-action participation before a control changes application state. The
/// parent already exists in this frame, so a newly hidden ancestor cancels input too.
pub fn policyResponse(f: *Frame, id: types.Id, recipe: model.Recipe, options: Options, authoritative: style.States) style.Error!types.Response {
    const response = responseFor(f, id, authoritative.disabled);
    if (authoritative.disabled) return response;
    const states = statesFor(authoritative, response, visibleFocus(f, options));
    const root = try recipe.resolve(Parts.root, useFor(f, options, states), null);
    const parent = f.tree().participation(f.ctx.stack[f.ctx.depth - 1]);
    if (!root.box.participation.layout or !root.box.participation.hit or !parent.layout or !parent.hit) return responseFor(f, id, true);
    return response;
}

pub fn statesFor(authoritative: style.States, response: types.Response, visible_focus: bool) style.States {
    var states = authoritative;
    states.hovered = response.hovered;
    states.held = response.held;
    states.focused = response.focused;
    states.focus_visible = response.focused and visible_focus;
    return states;
}

pub fn useFor(f: *const Frame, options: Options, states: style.States) model.Use {
    return .{ .tokens = options.tokens, .scope = options.scope, .variants = options.variants, .states = states, .environment = environmentFor(f, options), .local = options.local, .color_policy = options.color_policy };
}

fn checkSemantics(f: *const Frame, options: Options) style.Error!void {
    if (options.semantics) |semantics| if (f.tree().len >= semantics.cap) return error.NoSpace;
}

/// The same source of truth is copied into an optional semantic side table. Existing fields
/// such as multiline and explicit expandable are retained.
pub fn expose(semantics: ?*a11y.Semantics, node: types.Node, states: style.States) void {
    if (semantics) |s| {
        var value: a11y.State = @bitCast(s.c.state[node.ix()]);
        value.disabled = states.disabled;
        value.read_only = states.read_only;
        value.selected = states.selected;
        value.checked = states.checked;
        value.mixed = states.indeterminate;
        value.expanded = states.expanded;
        value.current = states.current;
        value.pressed = states.toggled;
        value.focused = states.focused;
        value.invalid = states.invalid;
        value.required = states.required;
        value.busy = states.busy;
        s.c.state[node.ix()] = value.bitsOf();
    }
}

fn resolvedControl(f: *const Frame, recipe: model.Recipe, options: Options, states: style.States) style.Error!OpenControl {
    const use = useFor(f, options, states);
    const root = try recipe.resolve(Parts.root, use, null);
    var child = use;
    child.parent = &root;
    child.local = &.{};
    return .{
        .node = .none,
        .response = .{},
        .states = states,
        .root = root,
        .label = try recipe.resolve(Parts.label, child, null),
        .focus = try recipe.resolve(Parts.focus, child, null),
        .recipe = recipe,
        .use = use,
        .focus_offset = options.focus_offset,
    };
}

/// Leaves the control open for arbitrary children. All style resolution happens before
/// opening, so a bad token or property cannot leave an unmatched Frame.open behind.
pub fn beginButton(f: *Frame, id: types.Id, options: Options) style.Error!OpenControl {
    try checkSemantics(f, options);
    var response = try policyResponse(f, id, options.recipe orelse model.button, options, options.states);
    response.clicked = !options.states.disabled and button_zig.activated(response.clicked, response.focused, f.in);
    const visible = visibleFocus(f, options);
    var control = try resolvedControl(f, options.recipe orelse model.button, options, statesFor(options.states, response, visible));
    control.root.box.role = .button;
    control.node = f.open(id, control.root.box);
    _ = f.interact(control.node, if (options.states.disabled) .{} else .button);
    control.response = response;
    f.setCursor(f.tree().cursor(control.node.ix()) orelse .pointer, response.hovered);
    expose(options.semantics, control.node, control.states);
    return control;
}

pub fn label(f: *Frame, control: *const OpenControl, text: []const u8) types.Node {
    return f.textStyled(text, control.label.text, control.label.box);
}

/// Emits an independently styled icon/image part. White is the existing texture's no-tint
/// convention; the caller can override fill in its icon rule to tint it.
pub fn icon(f: *Frame, control: *const OpenControl, texture: types.Texture, uv: [4]f32) style.Error!types.Node {
    var computed = try control.part(Parts.icon, null);
    computed.box.texture = texture;
    computed.box.uv = uv;
    return f.leaf(.none, computed.box);
}

/// Explicit directional metadata: photos, logos and other non-directional icons keep their
/// authored UV orientation. Only marked directional icons mirror when the locale is RTL.
pub fn directionalIcon(f: *Frame, control: *const OpenControl, texture: types.Texture, uv: [4]f32, mirror_in_rtl: bool) style.Error!types.Node {
    const coordinates = if (mirror_in_rtl and (control.use.environment.rtl orelse false)) [4]f32{ uv[2], uv[1], uv[0], uv[3] } else uv;
    return icon(f, control, texture, coordinates);
}

pub fn end(f: *Frame, control: *const OpenControl) void {
    _ = f.outline(control.node, outlineOptions(control.focus, control.focus_offset));
    f.close();
}

pub fn outlineOptions(computed: style.Computed, offset: f32) @import("../draw/outline.zig").Outline {
    var radii = computed.box.radii;
    for (&radii) |*radius| radius.* = if (radius.* < 0) computed.box.radius else radius.*;
    return .{ .width = computed.box.border, .color = computed.box.border_color, .offset = offset, .radii = radii };
}

pub fn button(f: *Frame, id: types.Id, text: []const u8, options: Options) style.Error!types.Response {
    const control = try beginButton(f, id, options);
    _ = label(f, &control, text);
    end(f, &control);
    return control.response;
}

/// Boolean and tri-state controls use the stock toggle behavior; style cannot re-enable a
/// disabled/read-only control. Value changes commit only after all parts resolve.
pub fn checkbox(f: *Frame, id: types.Id, value: anytype, text: []const u8, options: Options) style.Error!types.Response {
    try checkSemantics(f, options);
    var before = options.states;
    const previous = checkbox_zig.Check.of(value.*);
    before.checked = previous == .on;
    before.indeterminate = previous == .mixed;
    var response = try policyResponse(f, id, options.recipe orelse model.checkbox, options, before);
    response.clicked = !options.states.disabled and !options.states.read_only and checkbox_zig.toggled(response.clicked, response.focused, f.in);
    const next = checkbox_zig.flip(value.*, response.clicked);
    const check = checkbox_zig.Check.of(next);
    var states = statesFor(options.states, response, visibleFocus(f, options));
    states.checked = check == .on;
    states.indeterminate = check == .mixed;
    var control = try resolvedControl(f, options.recipe orelse model.checkbox, options, states);
    const background = try control.part(Parts.background, null);
    const indicator = try control.part(Parts.indicator, null);
    control.root.box.role = .checkbox;
    control.root.box.value = check.value();
    control.node = f.open(id, control.root.box);
    _ = f.interact(control.node, if (states.disabled) .{} else .button);
    _ = f.open(.none, background.box);
    _ = f.leaf(.none, indicator.box);
    f.close();
    _ = label(f, &control, text);
    end(f, &control);
    value.* = next;
    expose(options.semantics, control.node, states);
    return response;
}

pub fn switchControl(f: *Frame, id: types.Id, value: *bool, text: []const u8, options: Options) style.Error!types.Response {
    try checkSemantics(f, options);
    var before = options.states;
    before.checked = value.*;
    var response = try policyResponse(f, id, options.recipe orelse model.switch_control, options, before);
    response.clicked = !options.states.disabled and !options.states.read_only and checkbox_zig.toggled(response.clicked, response.focused, f.in);
    const next = base.toggle(value.*, response.clicked);
    var states = statesFor(options.states, response, visibleFocus(f, options));
    states.checked = next;
    var control = try resolvedControl(f, options.recipe orelse model.switch_control, options, states);
    const track = try control.part(Parts.track, null);
    const thumb = try control.part(Parts.thumb, null);
    control.node = f.open(id, control.root.box);
    _ = f.interact(control.node, if (states.disabled) .{} else .button);
    _ = f.open(.none, track.box);
    _ = f.leaf(.none, thumb.box);
    f.close();
    _ = label(f, &control, text);
    end(f, &control);
    value.* = next;
    switch_zig.expose(f.tree(), control.node.ix(), next);
    expose(options.semantics, control.node, states);
    return response;
}

pub fn slider(f: *Frame, id: types.Id, value: *f32, lo: f32, hi: f32, options: Options) style.Error!types.Response {
    if (!std.math.isFinite(lo) or !std.math.isFinite(hi) or !(lo < hi)) return error.InvalidValue;
    try checkSemantics(f, options);
    const response = try policyResponse(f, id, options.recipe orelse model.slider, options, options.states);
    const state = statesFor(options.states, response, visibleFocus(f, options));
    var next = value.*;
    if (!state.disabled and !state.read_only) {
        const rect = f.heldRect();
        next = base.slide(next, response.held, (f.in.pointer[0] - rect.x0) / @max(rect.w(), 1), lo, hi);
        if (response.focused) next = slider_zig.keyed(next, lo, hi, f.in) orelse next;
    }
    var control = try resolvedControl(f, options.recipe orelse model.slider, options, state);
    var fill = try control.part(Parts.fill, null);
    const thumb = try control.part(Parts.thumb, null);
    const fraction = base.fraction(next, lo, hi);
    fill.box.size[0] = .pct(fraction);
    fill.box.float = true;
    control.root.box.cross = .center;
    control.root.box.role = .slider;
    control.root.box.value = next;
    control.node = f.open(id, control.root.box);
    _ = f.interact(control.node, if (state.disabled) .{} else .{ .hover = true, .click = true, .drag = true, .focus = true });
    _ = f.leaf(.none, fill.box);
    _ = f.leaf(.none, .{ .size = .{ .grow(fraction), .px(0) } });
    var thumb_box = thumb.box;
    thumb_box.float = false;
    _ = f.leaf(.none, thumb_box);
    _ = f.leaf(.none, .{ .size = .{ .grow(1 - fraction), .px(0) } });
    end(f, &control);
    value.* = next;
    expose(options.semantics, control.node, state);
    if (options.semantics) |semantics| slider_zig.semantics(f.tree(), semantics, id, lo, hi);
    return response;
}

/// Opens a plain box whose style is the recipe's root resolved this frame, over the
/// environment and, when `interactive`, over hover and press of `id` (CSS `.card:hover`,
/// `@media` on a `<div>`). It takes no focus and has no role of its own; children go before
/// `endBox`. A box that is not interactive takes `.none` or any id.
pub fn beginBox(f: *Frame, id: types.Id, interactive: bool, options: Options) style.Error!types.Node {
    const recipe = options.recipe orelse model.Recipe{};
    const response = if (interactive) responseFor(f, id, options.states.disabled) else types.Response{};
    const root = try recipe.resolve(Parts.root, useFor(f, options, statesFor(options.states, response, false)), null);
    const node = f.open(id, root.box);
    if (interactive) _ = f.interact(node, .{ .hover = true, .click = true });
    return node;
}

pub fn endBox(f: *Frame) void {
    f.close();
}

pub fn progress(f: *Frame, value: f32, options: Options) style.Error!types.Node {
    const control = try resolvedControl(f, options.recipe orelse model.progress, options, options.states);
    var fill = try control.part(Parts.fill, null);
    fill.box.size[0] = .pct(progress_zig.progressValue(value));
    var root = control.root.box;
    root.value = progress_zig.progressValue(value);
    const node = f.open(.none, root);
    _ = f.leaf(.none, fill.box);
    f.close();
    progress_zig.setRole(f.tree(), node.ix());
    return node;
}

/// Uses the existing editor and shaping view. Only paint/layout parts are replaced. The
/// caller's existing read-only policy is retained; options may restrict it further.
pub fn textfield(f: *Frame, id: types.Id, field: anytype, placeholder: []const u8, options: Options) style.Error!types.Response {
    try checkSemantics(f, options);
    const response = try policyResponse(f, id, options.recipe orelse model.input, options, options.states);
    const states = statesFor(options.states, response, visibleFocus(f, options));
    var control = try resolvedControl(f, options.recipe orelse model.input, options, states);
    const content = try control.part(Parts.content, null);
    const hint = try control.part(Parts.placeholder, null);
    const selection = try control.part(Parts.selection, null);
    const caret = try control.part(Parts.caret, null);
    var th = model.metrics(control.root);
    th.text_px = content.text.px;
    th.text = content.text.color;
    const editor = field.editor();
    const was_read_only = editor.mode.read_only;
    editor.mode.read_only = was_read_only or states.read_only or states.disabled;
    defer editor.mode.read_only = was_read_only;
    var last = f.lastRect(id);
    last.x1 -= control.root.box.pad[2] - control.root.box.pad[0];
    last.y0 += control.root.box.pad[1] - textfield_zig.padding(&th)[1];
    textfield_zig.behave(field, &th, id, response, last, f.in);
    textfield_zig.platform(f, field);
    control.root.box.role = .text_input;
    control.root.box.scroll = .{ field.scroll, 0 };
    control.node = f.open(id, control.root.box);
    _ = f.interact(control.node, if (states.disabled) .{} else types.Sense.any);
    f.setCursor(f.tree().cursor(control.node.ix()) orelse .text, response.hovered);
    const shown = textfield_zig.shown(field, &th, placeholder);
    for (shown.band) |band| {
        var box = selection.box;
        box.float = true;
        box.offset = .{ band[0], 0 };
        box.size = .{ .px(band[1] - band[0]), .px(textfield_zig.lineHeight(&th)) };
        _ = f.leaf(.none, box);
    }
    const text_part = if (shown.hint) hint else content;
    selectedText(f, shown.str, text_part, selection, shown.band, 0, textfield_zig.lineHeight(&th));
    var caret_box = caret.box;
    caret_box.float = true;
    caret_box.offset = .{ shown.caret, 0 };
    caret_box.size[1] = .px(textfield_zig.lineHeight(&th));
    _ = f.leaf(.none, caret_box);
    end(f, &control);
    expose(options.semantics, control.node, states);
    return response;
}

pub const selection_sections = textfield_zig.bands * 2 + 1;
pub const Section = struct { from: f32, to: ?f32, selected: bool };
pub const Selected = struct { active: bool, sections: [selection_sections]Section };

/// Disjoint visual intervals prevent double-painted glyph antialiasing and keep ligatures
/// shaped across a selection boundary. Full-text copies are clipped, never substring-shaped.
pub fn selectionSections(content: style.Computed, selection: style.Computed, bands: [textfield_zig.bands][2]f32) Selected {
    var sorted = bands;
    var n: usize = 0;
    for (bands) |band| if (band[1] > band[0]) {
        sorted[n] = band;
        n += 1;
    };
    for (1..@max(n, 1)) |i| {
        const value = sorted[i];
        var at = i;
        while (at > 0 and sorted[at - 1][0] > value[0]) : (at -= 1) sorted[at] = sorted[at - 1];
        sorted[at] = value;
    }
    var result: Selected = .{ .active = n > 0 and !std.meta.eql(content.text.color, selection.text.color), .sections = @splat(.{ .from = 0, .to = 0, .selected = false }) };
    var limit: f32 = 0;
    for (sorted[0..n], 0..) |band, i| {
        const from = @max(limit, band[0]);
        result.sections[i * 2] = .{ .from = limit, .to = from, .selected = false };
        result.sections[i * 2 + 1] = .{ .from = from, .to = @max(from, band[1]), .selected = true };
        limit = @max(limit, band[1]);
    }
    result.sections[selection_sections - 1] = .{ .from = limit, .to = null, .selected = false };
    return result;
}

pub fn selectedText(f: *Frame, text: []const u8, content: style.Computed, selection: style.Computed, bands: [textfield_zig.bands][2]f32, top: f32, height: f32) void {
    const selected = selectionSections(content, selection, bands);
    var original = content.box;
    original.participation.paint = original.participation.paint and !selected.active;
    _ = f.textStyled(text, content.text, original);
    for (selected.sections) |section| {
        const boxes = selectionTextBoxes(content, section, top, height, selected.active);
        _ = f.open(.none, boxes.clip);
        if (boxes.clip.participation.paint) _ = f.textStyled(text, if (section.selected) selection.text else content.text, boxes.text) else _ = f.leaf(.none, boxes.text);
        f.close();
    }
}

pub fn selectionTextBoxes(content: style.Computed, section: Section, top: f32, height: f32, active: bool) struct { clip: types.Style, text: types.Style } {
    var text = content.box;
    text.float = true;
    text.offset = .{ content.box.offset[0] - section.from, content.box.offset[1] };
    text.size = .{ .fit, .fit };
    text.fill = .transparent;
    text.border = 0;
    text.participation.hit = false;
    text.participation.semantics = false;
    return .{ .clip = .{ .float = true, .offset = .{ section.from, top }, .size = .{ if (section.to) |limit| .px(@max(limit - section.from, 0)) else .fill, .px(height) }, .clip = true, .participation = .{ .paint = active and (section.to == null or section.to.? > section.from), .hit = false, .semantics = false } }, .text = text };
}

const context = @import("../runtime/context.zig");
const Input = @import("../core/input.zig").Input;
const test_limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 12, .anims = 1, .tweens = 1, .flips = 1, .signals = 1, .timers = 1 };
const test_bytes = blk: {
    @setEvalBranchQuota(100_000);
    break :blk context.Context.requiredBytes(test_limits);
};

test "caller usage: custom icon/label retains button activation and disabled prevents it" {
    var buffer: [test_bytes]u8 align(64) = undefined;
    var ctx = try context.Context.init(&buffer, test_limits);
    var input: Input = .{ .viewport = .{ 320, 100 } };
    var f = ctx.begin(&input);
    var control = try beginButton(&f, .from("save"), .{});
    _ = try icon(&f, &control, .white, .{ 0, 0, 1, 1 });
    _ = label(&f, &control, "Save");
    end(&f, &control);
    var output = f.end(.{});
    const row = output.tree.find(.from("save"));
    const rect = output.tree.rect(row);
    input.pointer = .{ (rect.x0 + rect.x1) / 2, (rect.y0 + rect.y1) / 2 };
    input.buttons.left = true;
    f = ctx.begin(&input);
    _ = try button(&f, .from("save"), "Save", .{});
    _ = f.end(.{});
    input.buttons.left = false;
    f = ctx.begin(&input);
    const clicked = try button(&f, .from("save"), "Save", .{});
    output = f.end(.{});
    try std.testing.expect(clicked.clicked);
    try std.testing.expectEqual(@backingInt(types.Role.button), output.tree.c.role[row]);
    input.events = &.{.{ .kind = .press, .code = @import("../widgets/keys.zig").enter }};
    f = ctx.begin(&input);
    const disabled = try button(&f, .from("save"), "Save", .{ .states = .{ .disabled = true } });
    output = f.end(.{});
    try std.testing.expect(!disabled.clicked);
    try std.testing.expectEqual(@as(u8, 0), output.tree.c.sense[row]);
}

test "caller usage: combined states keep independent border/focus and failed resolution leaves frame balanced" {
    var buffer: [test_bytes]u8 align(64) = undefined;
    var ctx = try context.Context.init(&buffer, test_limits);
    const input: Input = .{ .viewport = .{ 320, 100 } };
    var f = ctx.begin(&input);
    const before = ctx.depth;
    const invalid_rules = [_]style.Rule{.{ .declarations = &.{style.token(.fill, .from("missing"))} }};
    try std.testing.expectError(error.MissingToken, beginButton(&f, .from("bad"), .{ .recipe = .{ .rules = &invalid_rules } }));
    try std.testing.expectEqual(before, ctx.depth);
    _ = try button(&f, .from("good"), "Good", .{ .states = .{ .selected = true }, .variants = &.{.from("small")} });
    const output = f.end(.{});
    const row = output.tree.find(.from("good"));
    const extra = output.tree.c.extra[row];
    try std.testing.expectEqual(@as(f32, 1), output.tree.x.row[extra].border);
    try std.testing.expectEqual(@as(f32, 12), output.texts.c.px[0]);
}

test "caller usage: read-only slider and textfield preserve application values" {
    var buffer: [test_bytes]u8 align(64) = undefined;
    var ctx = try context.Context.init(&buffer, test_limits);
    var field = textfield_zig.Text(64).init("unchanged");
    var value: f32 = 0.5;
    const input: Input = .{ .viewport = .{ 320, 100 } };
    var f = ctx.begin(&input);
    _ = try slider(&f, .from("volume"), &value, 0, 1, .{ .states = .{ .read_only = true } });
    _ = try textfield(&f, .from("name"), &field, "Name", .{ .states = .{ .read_only = true } });
    const output = f.end(.{});
    try std.testing.expectEqual(@as(f32, 0.5), value);
    try std.testing.expectEqualStrings("unchanged", field.text());
    try std.testing.expect(output.status.ok());
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(OpenControl);
}
