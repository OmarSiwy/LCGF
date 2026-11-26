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
const link_zig = @import("../widgets/link.zig");
const toggle_zig = @import("../widgets/toggle.zig");
const search_zig = @import("../widgets/search.zig");
const textarea_zig = @import("../widgets/textarea.zig");
const simd = @import("../core/simd.zig");
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
    /// Text controls only: `controls.Validation`.
    validation: controls.Validation = .{},
    /// CSS `transition` of the root; `fade_field` names the State's `controls.Fade` that
    /// keeps it between frames. Both or neither.
    transition: controls.Transition = .{},
    fade_field: ?[]const u8 = null,
    /// CSS `animation` of the root; `clock_field` names the State's `controls.Clock`.
    animation: controls.Animation = .{},
    clock_field: ?[]const u8 = null,
    /// Optional fields of the application's State. Their types are checked by the builder.
    states_field: ?[]const u8 = null,
    environment_field: ?[]const u8 = null,
    tokens_field: ?[]const u8 = null,
    recipe_field: ?[]const u8 = null,
};

/// A plain box, `controls.beginBox` in the comptime front end: its root style is
/// `config.recipe`'s, resolved each frame over the environment and, when `id` is an enum
/// literal, over hover and press of the widget `id` (not focusable). `id` null makes a box that
/// follows only the environment (`@media`) and is no widget. `children` as `spec.col` takes.
pub fn box(comptime id: anytype, comptime config: Config, comptime children: anytype) Spec {
    const name: ?[:0]const u8 = if (@TypeOf(id) == @TypeOf(null)) null else @tagName(id);
    var s = spec_zig.col(.{}, children);
    s.id = name;
    s.widget = FadingBox(config, Box(name, config));
    return s;
}

/// Eases `root` along `config.transition` and keeps the step in its fade field, if any.
fn stepFade(comptime config: Config, ui: anytype, root: *style.Computed, in: *const Input) void {
    if (config.fade_field) |field| {
        const fade = &@field(ui.signals.state, field);
        fade.* = fade.next(root, config.transition.under(ui.frame_settings.reduced_motion), in.dt);
    }
    if (config.clock_field) |field| {
        const clock = &@field(ui.signals.state, field);
        clock.* = clock.next(root, config.animation, in.dt, ui.frame_settings.reduced_motion);
    }
}

/// Seconds until `config`'s fade lands: 0 asks for the next frame while it moves.
fn fadeWake(comptime config: Config, ui: anytype) f32 {
    const fading = if (config.fade_field) |f| @field(ui.signals.state, f).remaining(config.transition.under(ui.frame_settings.reduced_motion)) > 0 else false;
    const playing = if (config.clock_field) |f| config.animation.running(@field(ui.signals.state, f).elapsed) else false;
    return if (fading or playing) 0 else types.inf;
}

/// Control `W` with a `wakeAfter` while `config`'s fade moves; `W` itself without a fade, so
/// a control without a transition adds no hook.
fn FadingControl(comptime config: Config, comptime W: type) type {
    if (config.fade_field == null and config.clock_field == null) return W;
    return struct {
        pub const focusable = W.focusable;
        pub const Payload = W.Payload;
        pub const push = W.push;
        pub const step = W.step;
        pub const bindError = W.bindError;
        pub const inputAvailability = W.inputAvailability;

        pub fn wakeAfter(ui: anytype, in: *const Input) f32 {
            _ = in;
            return fadeWake(config, ui);
        }
    };
}

/// As `FadingControl`, for a box.
fn FadingBox(comptime config: Config, comptime W: type) type {
    if (config.fade_field == null and config.clock_field == null) return W;
    return struct {
        pub const holds_content = true;
        pub const push = W.push;

        pub fn wakeAfter(ui: anytype, in: *const Input) f32 {
            _ = in;
            return fadeWake(config, ui);
        }
    };
}

fn Box(comptime name: ?[:0]const u8, comptime config: Config) type {
    return struct {
        pub const holds_content = true;

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            const row = next.*;
            next.* += 1;
            // `:focus-within`, and :hover and :active on an ancestor: the widget is one of
            // this box's spec rows.
            const rows = comptime @import("../comptime/flatten.zig").count(n);
            const inside = struct {
                fn is(w: anytype, first: u32) bool {
                    const x = w orelse return false;
                    return @backingInt(x) >= first and @backingInt(x) < first + rows;
                }
            }.is;
            var response = if (name != null) ui.response(row, in) else types.Response{};
            if (name != null and !config.states.disabled) {
                response.held = inside(ui.pointer.pressed, row);
                response.hovered = inside(ui.build_hit, row) and (ui.pointer.pressed == null or response.held);
            }
            const environment = config.environment orelse model.Environment.fromInput(in).withSettings(&ui.frame_settings);
            var states = controls.statesFor(config.states, response, false);
            states.focus_within = inside(ui.focus, row);
            const use: model.Use = .{ .tokens = config.tokens, .scope = config.scope, .states = states, .environment = environment, .variants = config.variants, .local = config.local, .color_policy = config.color_policy };
            const recipe = config.recipe orelse model.Recipe{};
            var root = recipe.resolve(Parts.root, use, null) catch |err| blk: {
                ui.fail(err);
                break :blk recipe.baseFor(Parts.root);
            };
            stepFade(config, ui, &root, in);
            const tb = &ui.tables;
            const i = tb.t.push(parent, if (name) |x| .hash(x) else .none, &root.box);
            inline for (n.children) |c| ui.push(c, i, next, in);
            tb.t.seal(i);
        }
    };
}

const Kind = enum { button, link, toggle, checkbox, switch_control, slider, input, search };

/// `text` is the caption: a `[]const u8` field of the State (`.save`) or a literal ("Save").
pub fn button(comptime id: @EnumLiteral(), comptime text: anytype, comptime config: Config) Spec {
    return build(.button, @tagName(id), if (comptime isLiteral(text)) "" else @tagName(text), captionName(text), .{}, config, isLiteral(text));
}
/// A link: a button with role link that Enter activates, not Space (`link.activated`).
pub fn link(comptime id: @EnumLiteral(), comptime text: anytype, comptime config: Config) Spec {
    return build(.link, @tagName(id), if (comptime isLiteral(text)) "" else @tagName(text), captionName(text), .{}, config, isLiteral(text));
}
/// A toggle button over the `bool` field `bind`: `States.toggled` while it is pressed.
pub fn toggle(comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime text: anytype, comptime config: Config) Spec {
    return build(.toggle, @tagName(id), @tagName(bind), captionName(text), .{}, config, isLiteral(text));
}
pub fn checkbox(comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime text: anytype, comptime config: Config) Spec {
    return build(.checkbox, @tagName(id), @tagName(bind), captionName(text), .{}, config, isLiteral(text));
}
pub fn switchControl(comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime text: anytype, comptime config: Config) Spec {
    return build(.switch_control, @tagName(id), @tagName(bind), captionName(text), .{}, config, isLiteral(text));
}

fn isLiteral(comptime text: anytype) bool {
    return @TypeOf(text) != @EnumLiteral();
}

/// The caption's field name, or the literal itself.
fn captionName(comptime text: anytype) []const u8 {
    return if (comptime isLiteral(text)) text else @tagName(text);
}
pub fn slider(comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime limits: slider_zig.Range, comptime config: Config) Spec {
    if (!(limits.lo < limits.hi)) @compileError("recipe slider requires lo below hi");
    return build(.slider, @tagName(id), @tagName(bind), "", limits, config, false);
}
/// `hint` is the placeholder: a `[]const u8` field of the State or a literal.
pub fn textfield(comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime hint: anytype, comptime config: Config) Spec {
    return build(.input, @tagName(id), @tagName(bind), captionName(hint), .{}, config, isLiteral(hint));
}
/// A search field, as `controls.search`: the box (the recipe's root) holds the field `id`
/// and the Clear button, the widget `<id>.clear`. Its events carry the field's `edit.Result`.
pub fn search(comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime hint: anytype, comptime config: Config) Spec {
    const name = @tagName(id);
    const W = Widget(.search, name, @tagName(bind), captionName(hint), .{}, config, isLiteral(hint));
    var field = build(.search, name, @tagName(bind), captionName(hint), .{}, config, isLiteral(hint));
    field.bind = null;
    field.widget = SearchField(W);
    const clear: Spec = .{ .kind = .row, .id = name ++ ".clear", .children = &.{.{ .kind = .label }} };
    return .{ .kind = .row, .bind = @tagName(bind), .children = &.{ field, clear }, .widget = SearchBox(name, @tagName(bind), W) };
}

/// The field inside a recipe search box: a focus stop the box pushes and steps.
fn SearchField(comptime W: type) type {
    return struct {
        pub const focusable = true;
        pub const Payload = edit.Result;
        pub const inputAvailability = W.inputAvailability;

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            _ = .{ ui, n, parent, next, in };
            unreachable; // pushed by the search box
        }
    };
}

/// Rows of a recipe text field: the field, its bands, text, selection copies, caret and outline.
const field_rows = textfield_zig.bands + controls.selection_sections * 2 + 4;

fn SearchBox(comptime name: [:0]const u8, comptime bind: []const u8, comptime W: type) type {
    return struct {
        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            _ = field;
            return W.bindError(State, bind);
        }

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            const Ui = @TypeOf(ui.*);
            const row = next.*;
            next.* += 1;
            var response = ui.response(row + 1, in);
            response.focused = ui.focus == @field(Ui.Events.Widget, name);
            const use = W.useFor(ui, in, response);
            const root = W.resolvePart(ui, Parts.root, use);
            var child = use;
            child.parent = &root;
            child.local = &.{};
            const th = controls.fieldMetrics(root, W.resolvePart(ui, Parts.content, child), true);
            const t = &ui.tables.t;
            const row_box = t.push(parent, .none, &root.box);
            W.push(ui, n.children[0], row_box, next, in);
            const some = @field(ui.signals.state, bind).text().len > 0;
            const b = t.push(row_box, search_zig.clearId(.hash(name)), &search_zig.clearStyle(&th, ui.response(next.*, in), some));
            const k = t.push(b, .none, &.{ .role = .label });
            t.c.text[k] = ui.tables.tx.push(k, ui.tables.strings.add(search_zig.clear_text), &search_zig.clearText(&th, some));
            t.seal(b);
            next.* += 2;
            t.seal(row_box);
            search_zig.expose(t, row_box, b, some);
        }

        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) @TypeOf(event) {
            const Ui = @TypeOf(ui.*);
            const states = W.state(ui);
            const live = !states.disabled and !states.read_only;
            const field = &@field(ui.signals.state, bind);
            const clear = base.ctResponse(ui, row + 1 + field_rows, event, in);
            if (live and clear.clicked and field.text().len > 0) ui.focus = @field(Ui.Events.Widget, name);
            const response = base.ctResponse(ui, row + 1, event, in);
            const use = W.useFor(ui, in, response);
            const root = W.resolvePart(ui, Parts.root, use);
            var child = use;
            child.parent = &root;
            child.local = &.{};
            const th = controls.fieldMetrics(root, W.resolvePart(ui, Parts.content, child), true);
            const editor = field.editor();
            const previous = editor.mode.read_only;
            editor.mode.read_only = previous or !live;
            defer editor.mode.read_only = previous;
            const last = ui.lastRect(row + 1);
            if (live) search_zig.behave(field, &th, .hash(name), response, clear.clicked, last, in) else textfield_zig.behave(field, &th, .hash(name), response, last, in);
            if (field.result.changed or field.result.submitted) return @unionInit(Ui.Events.Event, name, field.result);
            return null;
        }
    };
}

fn stock(comptime kind: Kind) model.Recipe {
    return switch (kind) {
        .button => model.button,
        .link => model.link,
        .toggle => model.toggle,
        .checkbox => model.checkbox,
        .switch_control => model.switch_control,
        .slider => model.slider,
        .input => model.input,
        .search => model.search,
    };
}

fn build(comptime kind: Kind, comptime name: [:0]const u8, comptime bind: []const u8, comptime text: []const u8, comptime limits: slider_zig.Range, comptime config: Config, comptime literal: bool) Spec {
    const captioned = kind != .slider and kind != .input and kind != .search;
    const label_node: Spec = if (literal) .{ .kind = .label, .text = text } else .{ .kind = .label, .bind = if (captioned) text else null };
    const mark: Spec = .{ .kind = .col, .children = &.{.{ .kind = .col }} };
    const children: []const Spec = switch (kind) {
        .button, .link, .toggle => &.{ label_node, .{ .kind = .col } },
        .checkbox, .switch_control => &.{ mark, label_node, .{ .kind = .col } },
        .slider => &.{ .{ .kind = .col }, .{ .kind = .col }, .{ .kind = .col }, .{ .kind = .col }, .{ .kind = .col } },
        .input, .search => blk: {
            const bands: [textfield_zig.bands]Spec = @splat(.{ .kind = .col });
            const overlays: [controls.selection_sections]Spec = @splat(.{ .kind = .col, .children = &.{label_node} });
            const nodes = bands ++ [1]Spec{label_node} ++ overlays ++ [2]Spec{ .{ .kind = .col }, .{ .kind = .col } };
            break :blk &nodes;
        },
    };
    return .{
        .kind = .row,
        .id = name,
        .bind = if (bind.len > 0) bind else null,
        .children = children,
        .widget = FadingControl(config, Widget(kind, name, bind, text, limits, config, literal)),
    };
}

fn Widget(comptime kind: Kind, comptime name: [:0]const u8, comptime bind: []const u8, comptime text: []const u8, comptime limits: slider_zig.Range, comptime config: Config, comptime literal: bool) type {
    return struct {
        pub const focusable = true;
        pub const Payload = switch (kind) {
            .slider => f32,
            .input, .search => edit.Result,
            else => void,
        };

        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            _ = field;
            if (config.states_field) |f| if (base.fieldError(State, "recipe states", f, style.States)) |err| return err;
            if (config.environment_field) |f| if (base.fieldError(State, "recipe environment", f, model.Environment)) |err| return err;
            if (config.tokens_field) |f| if (base.fieldError(State, "recipe tokens", f, style.tokens.Table)) |err| return err;
            if (config.recipe_field) |f| if (base.fieldError(State, "recipe", f, model.Recipe)) |err| return err;
            if (config.fade_field) |f| if (base.fieldError(State, "recipe fade", f, controls.Fade)) |err| return err;
            if (config.clock_field) |f| if (base.fieldError(State, "recipe clock", f, controls.Clock)) |err| return err;
            if (kind == .input or kind == .search) return if (literal) textfield_zig.textError(State, "textfield", bind) else textfield_zig.bindError(State, bind, text);
            if (kind == .slider) return base.fieldError(State, "recipe slider", bind, f32);
            if (kind == .toggle) {
                if (toggle_zig.bindError(State, bind)) |err| return err;
            } else if (kind == .checkbox) {
                if (checkbox_zig.bindError(State, bind)) |err| return err;
            } else if (kind == .switch_control) {
                if (base.fieldError(State, "recipe switch", bind, bool)) |err| return err;
            }
            if (literal) return null;
            return base.fieldError(State, "recipe label", text, []const u8);
        }

        fn caption(ui: anytype) []const u8 {
            return if (literal) text else @field(ui.signals.state, text);
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
            } else if (kind == .switch_control) {
                states.checked = @field(ui.signals.state, bind);
            } else if (kind == .toggle) {
                states.toggled = @field(ui.signals.state, bind);
            } else if (kind == .input or kind == .search) states = config.validation.states(states, @field(ui.signals.state, bind).text());
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
            return .{ .enabled = !states.disabled and root.box.participation.layout and root.box.participation.hit, .activates = !states.read_only or kind == .button or kind == .link or kind == .input or kind == .search };
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
            stepFade(config, ui, &root, in);
            var child = use;
            child.parent = &root;
            child.local = &.{};
            const label_part = resolvePart(ui, Parts.label, child);
            const focus_part = resolvePart(ui, Parts.focus, child);
            const tb = &ui.tables;
            var value: f32 = 0;
            switch (kind) {
                .button => root.box.role = .button,
                .toggle => {
                    root.box.role = .button;
                    value = simd.b2f(@field(ui.signals.state, bind));
                },
                .link => root.box.role = .link,
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
                .search => {},
            }
            root.box.value = value;
            // A search field's root is the box around it (`SearchBox`); the field keeps the text field's layout.
            const field_box = if (kind == .search) search_zig.inputStyle(&controls.fieldMetrics(root, resolvePart(ui, Parts.content, child), true), @field(ui.signals.state, bind).scroll) else root.box;
            const row = tb.t.push(parent, .hash(name), &field_box);
            if (kind != .checkbox and kind != .switch_control and kind != .slider) ui.setCursor(tb.t.cursor(row) orelse if (kind == .input) .text else .pointer, response.hovered);
            switch (kind) {
                .button, .link, .toggle => {
                    if (kind == .toggle) tb.t.c.role[row] = toggle_zig.role;
                    pushText(ui, row, caption(ui), label_part);
                    next.* += 3;
                },
                .checkbox, .switch_control => {
                    const background = resolvePart(ui, if (kind == .checkbox) Parts.background else Parts.track, child);
                    const indicator = resolvePart(ui, if (kind == .checkbox) Parts.indicator else Parts.thumb, child);
                    const mark = tb.t.push(row, .none, &background.box);
                    _ = tb.t.push(mark, .none, &indicator.box);
                    tb.t.seal(mark);
                    pushText(ui, row, caption(ui), label_part);
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
                .input, .search => {
                    const field = &@field(ui.signals.state, bind);
                    const content = resolvePart(ui, Parts.content, child);
                    const hint = resolvePart(ui, Parts.placeholder, child);
                    const selection = resolvePart(ui, Parts.selection, child);
                    const caret = resolvePart(ui, Parts.caret, child);
                    const th = controls.fieldMetrics(root, content, kind == .search);
                    const shown = textfield_zig.shown(field, &th, caption(ui));
                    for (shown.band) |band| {
                        var part = selection.box;
                        part.float = true;
                        part.offset = .{ band[0], 0 };
                        part.size = .{ .px(band[1] - band[0]), .px(textfield_zig.lineHeight(&th)) };
                        _ = tb.t.push(row, .none, &part);
                    }
                    pushSelected(ui, row, shown.str, if (shown.hint) hint else content, selection, shown.band, 0, textfield_zig.lineHeight(&th));
                    var part = caret.box;
                    part.float = true;
                    part.offset = .{ shown.caret, 0 };
                    part.size[1] = .px(textfield_zig.lineHeight(&th));
                    _ = tb.t.push(row, .none, &part);
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
                .search => unreachable, // stepped by the search box
                .button => {
                    if (!states.disabled and !response.clicked and button_zig.activated(false, response.focused, in)) return @unionInit(Ui.Events.Event, name, {});
                },
                .link => {
                    if (!states.disabled and !response.clicked and link_zig.activated(false, response.focused, in)) return @unionInit(Ui.Events.Event, name, {});
                },
                .toggle => {
                    if (states.disabled or states.read_only or !button_zig.activated(response.clicked, response.focused, in)) return null;
                    ui.signals.set(Ui.field(bind), base.toggle(@field(ui.signals.state, bind), true));
                    if (!response.clicked) return @unionInit(Ui.Events.Event, name, {});
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
                    const th = controls.fieldMetrics(root, content, false);
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

/// `controls.selectedText` in the comptime front end: the text, then a clipped copy per
/// section of it, the selected ones in the selection's colours.
fn pushSelected(ui: anytype, parent: u32, text: []const u8, content: style.Computed, selection: style.Computed, bands: [textfield_zig.bands][2]f32, top: f32, height: f32) void {
    const t = &ui.tables.t;
    const selected = controls.selectionSections(content, selection, bands);
    var original = content;
    original.box.participation.paint = original.box.participation.paint and !selected.active;
    pushText(ui, parent, text, original);
    for (selected.sections) |section| {
        const boxes = controls.selectionTextBoxes(content, section, top, height, selected.active);
        const clip = t.push(parent, .none, &boxes.clip);
        var selected_text = if (section.selected) selection else content;
        selected_text.box = boxes.text;
        if (boxes.clip.participation.paint) pushText(ui, clip, text, selected_text) else _ = t.push(clip, .none, &boxes.text);
        t.seal(clip);
    }
}

/// A text area, as `recipe_parts.textarea`: `rows` lines of the Text(cap) field `bind`,
/// `hint` (a string field or a literal) on the first while empty.
pub fn textarea(comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime rows: u32, comptime hint: anytype, comptime config: Config) Spec {
    if (rows == 0) @compileError("recipe textarea needs at least one row");
    const label_node: Spec = if (isLiteral(hint)) .{ .kind = .label, .text = hint } else .{ .kind = .label };
    const bands: [rows * textfield_zig.bands]Spec = @splat(.{ .kind = .col });
    const sections: [controls.selection_sections]Spec = @splat(.{ .kind = .col, .children = &.{label_node} });
    const line = [1]Spec{label_node} ++ sections;
    var lines: [rows * line.len]Spec = undefined;
    for (0..rows) |i| lines[i * line.len ..][0..line.len].* = line;
    const kids = bands ++ lines ++ [2]Spec{ .{ .kind = .col }, .{ .kind = .col } };
    const final = kids;
    return .{ .kind = .col, .id = @tagName(id), .bind = @tagName(bind), .children = &final, .widget = TextArea(@tagName(id), @tagName(bind), rows, captionName(hint), isLiteral(hint), config) };
}

fn TextArea(comptime name: [:0]const u8, comptime bind: []const u8, comptime rows: u32, comptime hint: []const u8, comptime literal: bool, comptime config: Config) type {
    // The stock recipe is the editor's, as `recipe_parts.textarea`.
    comptime var stocked = config;
    if (stocked.recipe == null) stocked.recipe = model.editor;
    const W = Widget(.input, name, bind, hint, .{}, stocked, literal);
    return struct {
        pub const focusable = true;
        pub const Payload = edit.Result;
        pub const inputAvailability = W.inputAvailability;

        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            _ = field;
            return textarea_zig.bindError(State, bind, rows) orelse W.bindError(State, bind);
        }

        const Resolved = struct { root: style.Computed, content: style.Computed, placeholder: style.Computed, selection: style.Computed, caret: style.Computed, focus: style.Computed, metrics: base.Theme };

        fn resolve(ui: anytype, in: *const Input, response: types.Response) Resolved {
            const use = W.useFor(ui, in, response);
            var r: Resolved = undefined;
            r.root = W.resolvePart(ui, Parts.root, use);
            var child = use;
            child.parent = &r.root;
            child.local = &.{};
            r.content = W.resolvePart(ui, Parts.content, child);
            r.placeholder = W.resolvePart(ui, Parts.placeholder, child);
            r.selection = W.resolvePart(ui, Parts.selection, child);
            r.caret = W.resolvePart(ui, Parts.caret, child);
            r.focus = W.resolvePart(ui, Parts.focus, child);
            r.metrics = controls.fieldMetrics(r.root, r.content, false);
            return r;
        }

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            _ = n;
            const Ui = @TypeOf(ui.*);
            var response = ui.response(next.*, in);
            response.focused = ui.focus == @field(Ui.Events.Widget, name);
            var r = resolve(ui, in, response);
            const t = &ui.tables.t;
            const field = &@field(ui.signals.state, bind);
            const editor = field.editor();
            r.root.box.role = .text_input;
            r.root.box.scroll = .{ 0, 0 }; // textarea.behave already selects the visible line window.
            const row = t.push(parent, .hash(name), &r.root.box);
            ui.setCursor(t.cursor(row) orelse .text, response.hovered);
            const value = editor.text();
            const scroll: u32 = @intFromFloat(field.scroll);
            const selected = editor.selection();
            const advance = textfield_zig.advance(&r.metrics);
            const height = textfield_zig.lineHeight(&r.metrics);
            const fresh = textfield_zig.fresh(field);
            for (0..rows) |i| {
                const line = textarea_zig.shownLine(value, scroll, @intCast(i), selected, advance);
                for (textarea_zig.lineBands(fresh, scroll + @as(u32, @intCast(i)), selected, line.sel)) |band| {
                    var b = r.selection.box;
                    b.float = true;
                    b.offset = .{ band[0], @as(f32, @floatFromInt(i)) * height };
                    b.size = .{ .px(band[1] - band[0]), .px(height) };
                    _ = t.push(row, .none, &b);
                }
            }
            for (0..rows) |i| {
                const line = textarea_zig.shownLine(value, scroll, @intCast(i), selected, advance);
                const show_hint = value.len == 0 and i == 0;
                var part = if (show_hint) r.placeholder else r.content;
                part.box.size[1] = .px(height);
                const bands = textarea_zig.lineBands(fresh, scroll + @as(u32, @intCast(i)), selected, line.sel);
                pushSelected(ui, row, if (show_hint) (if (literal) hint else @field(ui.signals.state, hint)) else line.str, part, r.selection, bands, @as(f32, @floatFromInt(i)) * height, height);
            }
            const at = textarea_zig.caretAt(value, editor.shownCaret(), scroll, rows, &r.metrics, fresh);
            var caret_box = r.caret.box;
            caret_box.float = true;
            caret_box.offset = .{ at.x, at.y };
            caret_box.size[1] = .px(height);
            if (!at.shown) caret_box.fill = .transparent;
            _ = t.push(row, .none, &caret_box);
            _ = outline.append(t, row, @fromBackingInt(row), controls.outlineOptions(r.focus, config.focus_offset));
            next.* += 1 + rows * (textfield_zig.bands + 1 + controls.selection_sections * 2) + 2;
            t.seal(row);
        }

        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) @TypeOf(event) {
            const Ui = @TypeOf(ui.*);
            const response = base.ctResponse(ui, row, event, in);
            const states = W.state(ui);
            const r = resolve(ui, in, response);
            const field = &@field(ui.signals.state, bind);
            const editor = field.editor();
            const previous = editor.mode.read_only;
            editor.mode.read_only = previous or states.read_only or states.disabled;
            defer editor.mode.read_only = previous;
            var last = ui.lastRect(row);
            last.y0 += r.root.box.pad[1] - textfield_zig.padding(&r.metrics)[1];
            textarea_zig.behave(field, &r.metrics, .hash(name), response, last, rows, in);
            if (editor.mode.read_only) field.input.reset();
            if (field.result.changed or field.result.submitted) return @unionInit(Ui.Events.Event, name, field.result);
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
