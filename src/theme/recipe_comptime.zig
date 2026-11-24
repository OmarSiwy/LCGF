//! Recipe builders for the existing ComptimeUi. They call the same resolver and behavior as
//! runtime controls. Dynamic states, environment, token tables and recipes may live in the
//! application's state; no global registry or duplicated retained style tree is required.

const std = @import("std");
const types = @import("../core/types.zig");
const Input = @import("../core/input.zig").Input;
const style = @import("../style/style.zig");
const model = @import("recipe.zig");
const controls = @import("recipe_controls.zig");
const base = @import("../widgets/base.zig");
const spec_zig = @import("../comptime/spec.zig");
const events = @import("../comptime/events.zig");
const outline = @import("../draw/outline.zig");
const button_zig = @import("../widgets/button.zig");
const checkbox_zig = @import("../widgets/checkbox.zig");
const slider_zig = @import("../widgets/slider.zig");
const switch_zig = @import("../widgets/switch.zig");
const textfield_zig = @import("../widgets/textfield.zig");
const edit = @import("../text/edit/edit.zig");
const Parts = style.Parts;
const Spec = spec_zig.Spec;
pub const radio = @import("recipe_extra_controls.zig").ct.radio;
pub const range = @import("recipe_extra_controls.zig").ct.range;
pub const spinner = @import("recipe_extra_controls.zig").ct.spinner;

pub const Config = struct {
    recipe: ?model.Recipe = null,
    tokens: style.tokens.Table = .{},
    scope: u32 = 0,
    variants: []const types.Id = &.{},
    states: style.States = .{},
    environment: ?model.Environment = null,
    local: []const style.Declaration = &.{},
    focus_offset: f32 = 0,
    color_policy: model.ColorPolicy = .automatic,
    /// Optional fields of the application's State. Their types are checked by the builder.
    states_field: ?[]const u8 = null,
    environment_field: ?[]const u8 = null,
    tokens_field: ?[]const u8 = null,
    recipe_field: ?[]const u8 = null,
};

const Kind = enum { button, checkbox, switch_control, slider, input };

pub fn button(comptime id: @EnumLiteral(), comptime text: @EnumLiteral(), comptime config: Config) Spec {
    return build(.button, @tagName(id), @tagName(text), @tagName(text), .{}, config);
}
pub fn checkbox(comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime text: @EnumLiteral(), comptime config: Config) Spec {
    return build(.checkbox, @tagName(id), @tagName(bind), @tagName(text), .{}, config);
}
pub fn switchControl(comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime text: @EnumLiteral(), comptime config: Config) Spec {
    return build(.switch_control, @tagName(id), @tagName(bind), @tagName(text), .{}, config);
}
pub fn slider(comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime limits: slider_zig.Range, comptime config: Config) Spec {
    if (!(limits.lo < limits.hi)) @compileError("recipe slider requires lo below hi");
    return build(.slider, @tagName(id), @tagName(bind), "", limits, config);
}
pub fn textfield(comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime hint: @EnumLiteral(), comptime config: Config) Spec {
    return build(.input, @tagName(id), @tagName(bind), @tagName(hint), .{}, config);
}

fn stock(comptime kind: Kind) model.Recipe {
    return switch (kind) {
        .button => model.button,
        .checkbox => model.checkbox,
        .switch_control => model.switch_control,
        .slider => model.slider,
        .input => model.input,
    };
}

fn build(comptime kind: Kind, comptime name: [:0]const u8, comptime bind: []const u8, comptime text: []const u8, comptime limits: slider_zig.Range, comptime config: Config) Spec {
    const label_node: Spec = .{ .kind = .label, .bind = if (kind == .button or kind == .checkbox or kind == .switch_control) text else null };
    const mark: Spec = .{ .kind = .col, .children = &.{.{ .kind = .col }} };
    const children: []const Spec = switch (kind) {
        .button => &.{ label_node, .{ .kind = .col } },
        .checkbox, .switch_control => &.{ mark, label_node, .{ .kind = .col } },
        .slider => &.{ .{ .kind = .col }, .{ .kind = .col }, .{ .kind = .col }, .{ .kind = .col }, .{ .kind = .col } },
        .input => blk: {
            const bands: [textfield_zig.bands]Spec = @splat(.{ .kind = .col });
            const overlays: [controls.selection_sections]Spec = @splat(.{ .kind = .col, .children = &.{label_node} });
            const nodes = bands ++ [1]Spec{label_node} ++ overlays ++ [2]Spec{ .{ .kind = .col }, .{ .kind = .col } };
            break :blk &nodes;
        },
    };
    return .{
        .kind = .row,
        .id = name,
        .bind = bind,
        .children = children,
        .widget = Widget(kind, name, bind, text, limits, config),
    };
}

fn Widget(comptime kind: Kind, comptime name: [:0]const u8, comptime bind: []const u8, comptime text: []const u8, comptime limits: slider_zig.Range, comptime config: Config) type {
    return struct {
        pub const focusable = true;
        pub const Payload = switch (kind) {
            .slider => f32,
            .input => edit.Result,
            else => void,
        };

        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            _ = field;
            if (config.states_field) |f| if (base.fieldError(State, "recipe states", f, style.States)) |err| return err;
            if (config.environment_field) |f| if (base.fieldError(State, "recipe environment", f, model.Environment)) |err| return err;
            if (config.tokens_field) |f| if (base.fieldError(State, "recipe tokens", f, style.tokens.Table)) |err| return err;
            if (config.recipe_field) |f| if (base.fieldError(State, "recipe", f, model.Recipe)) |err| return err;
            if (kind == .input) return textfield_zig.bindError(State, bind, text);
            if (kind == .slider) return base.fieldError(State, "recipe slider", bind, f32);
            if (kind == .checkbox) {
                if (checkbox_zig.bindError(State, bind)) |err| return err;
            } else if (kind == .switch_control) {
                if (base.fieldError(State, "recipe switch", bind, bool)) |err| return err;
            }
            return base.fieldError(State, "recipe label", text, []const u8);
        }

        fn state(ui: anytype) style.States {
            return if (config.states_field) |field| @field(ui.signals.state, field) else config.states;
        }

        fn recipe(ui: anytype) model.Recipe {
            return if (config.recipe_field) |field| @field(ui.signals.state, field) else config.recipe orelse stock(kind);
        }

        fn useFor(ui: anytype, in: *const Input, response: types.Response) model.Use {
            const environment = if (config.environment_field) |field| @field(ui.signals.state, field) else config.environment orelse model.Environment.fromInput(in).withSettings(&ui.frame_settings);
            var states = controls.statesFor(state(ui), response, ui.focus_visible or (environment.always_show_focus orelse false));
            if (kind == .checkbox) {
                const value = checkbox_zig.Check.of(@field(ui.signals.state, bind));
                states.checked = value == .on;
                states.indeterminate = value == .mixed;
            } else if (kind == .switch_control) states.checked = @field(ui.signals.state, bind);
            return .{
                .tokens = if (config.tokens_field) |field| @field(ui.signals.state, field) else config.tokens,
                .scope = config.scope,
                .states = states,
                .environment = environment,
                .variants = config.variants,
                .local = config.local,
                .color_policy = config.color_policy,
            };
        }

        pub fn inputAvailability(ui: anytype, in: *const Input) events.Availability {
            const states = state(ui);
            const Ui = @TypeOf(ui.*);
            const target = @field(Ui.Events.Widget, name);
            var response = ui.response(@backingInt(target), in);
            response.focused = ui.focus == target;
            const root = recipe(ui).resolve(Parts.root, useFor(ui, in, response), null) catch |err| {
                ui.fail(err);
                return .{ .enabled = false, .activates = false };
            };
            return .{ .enabled = !states.disabled and root.box.participation.layout and root.box.participation.hit, .activates = !states.read_only or kind == .button or kind == .input };
        }

        fn resolvePart(ui: anytype, part: types.Id, use: model.Use) style.Computed {
            return recipe(ui).resolve(part, use, null) catch |err| {
                ui.fail(err);
                return recipe(ui).baseFor(part);
            };
        }

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            _ = n;
            const Ui = @TypeOf(ui.*);
            var response = ui.response(next.*, in);
            response.focused = ui.focus == @field(Ui.Events.Widget, name);
            const use = useFor(ui, in, response);
            var root = resolvePart(ui, Parts.root, use);
            var child = use;
            child.parent = &root;
            child.local = &.{};
            const label_part = resolvePart(ui, Parts.label, child);
            const focus_part = resolvePart(ui, Parts.focus, child);
            const tb = &ui.tables;
            var value: f32 = 0;
            switch (kind) {
                .button => root.box.role = .button,
                .checkbox => {
                    root.box.role = .checkbox;
                    value = checkbox_zig.Check.of(@field(ui.signals.state, bind)).value();
                },
                .switch_control => value = @floatFromInt(@intFromBool(@field(ui.signals.state, bind))),
                .slider => {
                    root.box.role = .slider;
                    root.box.cross = .center;
                    value = @field(ui.signals.state, bind);
                },
                .input => {
                    root.box.role = .text_input;
                    root.box.scroll = .{ @field(ui.signals.state, bind).scroll, 0 };
                },
            }
            root.box.value = value;
            const row = tb.t.push(parent, .hash(name), &root.box);
            if (kind == .button or kind == .input) ui.setCursor(tb.t.cursor(row) orelse if (kind == .input) .text else .pointer, response.hovered);
            switch (kind) {
                .button => {
                    pushText(ui, row, @field(ui.signals.state, text), label_part);
                    next.* += 3;
                },
                .checkbox, .switch_control => {
                    const background = resolvePart(ui, if (kind == .checkbox) Parts.background else Parts.track, child);
                    const indicator = resolvePart(ui, if (kind == .checkbox) Parts.indicator else Parts.thumb, child);
                    const mark = tb.t.push(row, .none, &background.box);
                    _ = tb.t.push(mark, .none, &indicator.box);
                    tb.t.seal(mark);
                    pushText(ui, row, @field(ui.signals.state, text), label_part);
                    if (kind == .switch_control) switch_zig.expose(&tb.t, row, @field(ui.signals.state, bind));
                    next.* += 5;
                },
                .slider => {
                    const fraction = base.fraction(value, limits.lo, limits.hi);
                    var fill = resolvePart(ui, Parts.fill, child);
                    fill.box.size[0] = .pct(fraction);
                    fill.box.float = true;
                    _ = tb.t.push(row, .none, &fill.box);
                    _ = tb.t.push(row, .none, &.{ .size = .{ .grow(fraction), .px(0) } });
                    var thumb = resolvePart(ui, Parts.thumb, child);
                    thumb.box.float = false;
                    _ = tb.t.push(row, .none, &thumb.box);
                    _ = tb.t.push(row, .none, &.{ .size = .{ .grow(1 - fraction), .px(0) } });
                    next.* += 6;
                },
                .input => {
                    const field = &@field(ui.signals.state, bind);
                    const content = resolvePart(ui, Parts.content, child);
                    const hint = resolvePart(ui, Parts.placeholder, child);
                    const selection = resolvePart(ui, Parts.selection, child);
                    const caret = resolvePart(ui, Parts.caret, child);
                    var th = model.metrics(root);
                    th.text_px = content.text.px;
                    th.text = content.text.color;
                    const shown = textfield_zig.shown(field, &th, @field(ui.signals.state, text));
                    for (shown.band) |band| {
                        var box = selection.box;
                        box.float = true;
                        box.offset = .{ band[0], 0 };
                        box.size = .{ .px(band[1] - band[0]), .px(textfield_zig.lineHeight(&th)) };
                        _ = tb.t.push(row, .none, &box);
                    }
                    const text_part = if (shown.hint) hint else content;
                    const selected = controls.selectionSections(text_part, selection, shown.band);
                    var original = text_part;
                    original.box.participation.paint = original.box.participation.paint and !selected.active;
                    pushText(ui, row, shown.str, original);
                    for (selected.sections) |section| {
                        const boxes = controls.selectionTextBoxes(text_part, section, 0, textfield_zig.lineHeight(&th), selected.active);
                        const clip = tb.t.push(row, .none, &boxes.clip);
                        var selected_text = if (section.selected) selection else text_part;
                        selected_text.box = boxes.text;
                        if (boxes.clip.participation.paint) pushText(ui, clip, shown.str, selected_text) else _ = tb.t.push(clip, .none, &boxes.text);
                        tb.t.seal(clip);
                    }
                    var box = caret.box;
                    box.float = true;
                    box.offset = .{ shown.caret, 0 };
                    box.size[1] = .px(textfield_zig.lineHeight(&th));
                    _ = tb.t.push(row, .none, &box);
                    next.* += textfield_zig.bands + controls.selection_sections * 2 + 4;
                },
            }
            _ = outline.append(&tb.t, row, @fromBackingInt(row), controls.outlineOptions(focus_part, config.focus_offset));
            tb.t.seal(row);
        }

        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) @TypeOf(event) {
            const Ui = @TypeOf(ui.*);
            const response = base.ctResponse(ui, row, event, in);
            const states = state(ui);
            switch (kind) {
                .button => {
                    if (!states.disabled and !response.clicked and button_zig.activated(false, response.focused, in)) return @unionInit(Ui.Events.Event, name, {});
                },
                .checkbox, .switch_control => {
                    const clicked = !states.disabled and !states.read_only and checkbox_zig.toggled(response.clicked, response.focused, in);
                    const value = @field(ui.signals.state, bind);
                    ui.signals.set(Ui.field(bind), checkbox_zig.flip(value, clicked));
                    if (clicked and !response.clicked) return @unionInit(Ui.Events.Event, name, {});
                },
                .slider => {
                    if (states.disabled or states.read_only) return null;
                    const before = @field(ui.signals.state, bind);
                    var value = before;
                    if (response.held and ui.built) {
                        const rect = ui.tables.t.rect(row + 1);
                        value = base.slide(value, true, (in.pointer[0] - rect.x0) / @max(rect.w(), 1), limits.lo, limits.hi);
                    }
                    if (response.focused) value = slider_zig.keyed(value, limits.lo, limits.hi, in) orelse value;
                    ui.signals.set(Ui.field(bind), value);
                    if (value != before) return @unionInit(Ui.Events.Event, name, value);
                },
                .input => {
                    const use = useFor(ui, in, response);
                    const root = resolvePart(ui, Parts.root, use);
                    var child = use;
                    child.parent = &root;
                    child.local = &.{};
                    const content = resolvePart(ui, Parts.content, child);
                    var th = model.metrics(root);
                    th.text_px = content.text.px;
                    th.text = content.text.color;
                    const field = &@field(ui.signals.state, bind);
                    const editor = field.editor();
                    const previous = editor.mode.read_only;
                    editor.mode.read_only = previous or states.read_only or states.disabled;
                    defer editor.mode.read_only = previous;
                    var last: types.Rect = if (ui.built) ui.tables.t.rect(row + 1) else .{};
                    last.x1 -= root.box.pad[2] - root.box.pad[0];
                    last.y0 += root.box.pad[1] - textfield_zig.padding(&th)[1];
                    textfield_zig.behave(field, &th, .hash(name), response, last, in);
                    if (field.result.changed or field.result.submitted) return @unionInit(Ui.Events.Event, name, field.result);
                },
            }
            return null;
        }
    };
}

fn pushText(ui: anytype, parent: u32, text: []const u8, computed: style.Computed) void {
    const tb = &ui.tables;
    const row = tb.t.push(parent, .none, &computed.box);
    tb.t.c.text[row] = tb.tx.push(row, tb.strings.add(text), &computed.text);
}

test {
    std.testing.refAllDecls(@This());
}
