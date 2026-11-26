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
const link_zig = @import("../widgets/link.zig");
const search_zig = @import("../widgets/search.zig");
const number_zig = @import("../widgets/number.zig");
const select_zig = @import("../widgets/select.zig");
const menu_zig = @import("../widgets/menu.zig");
const popover_zig = @import("../widgets/popover.zig");
const a11y_tree = @import("../a11y/tree.zig");
const toggle_zig = @import("../widgets/toggle.zig");
const simd = @import("../core/simd.zig");
const tweens = @import("../anim/tweens.zig");
const keyframes = @import("../anim/keyframes.zig");
const Parts = style.Parts;

/// HTML constraint validation of a text control (`required`, `minlength`, `maxlength`): it
/// sets `States.required`, and `States.invalid` from the text, so `:invalid`, `:valid` and
/// `:required` rules can match. Lengths count code points. The default validates nothing.
pub const Validation = struct {
    required: bool = false,
    min_length: u32 = 0,
    max_length: u32 = std.math.maxInt(u32),
    /// A number field's `min` and `max`: typed text that is not a number, or one outside
    /// them, is invalid (HTML's bad input, underflow and overflow); empty text is not.
    range: ?[2]f32 = null,

    pub fn invalid(v: Validation, text: []const u8) bool {
        const n = std.unicode.utf8CountCodepoints(text) catch text.len;
        return (v.required and n == 0) or (n > 0 and n < v.min_length) or n > v.max_length or (v.range != null and outside(text, v.range.?));
    }

    fn outside(text: []const u8, range: [2]f32) bool {
        const trimmed = std.mem.trim(u8, text, " ");
        if (trimmed.len == 0) return false;
        const value = std.fmt.parseFloat(f32, trimmed) catch return true;
        return !(value >= range[0] and value <= range[1]);
    }

    /// `base` with the validation's states for `text`.
    pub fn states(v: Validation, base_states: style.States, text: []const u8) style.States {
        var out = base_states;
        out.required = out.required or v.required;
        out.invalid = out.invalid or v.invalid(text);
        return out;
    }
};

/// CSS `transition` on a recipe control: which root properties ease to a new value, and how.
/// The default moves nothing.
pub const Transition = struct {
    seconds: f32 = 0,
    ease: tweens.Ease = .in_out,
    fill: bool = false,
    border_color: bool = false,
    text_color: bool = false,
    opacity: bool = false,

    /// `t` under the platform's reduced motion: no time, so every change lands at once.
    pub fn under(t: Transition, reduced_motion: bool) Transition {
        var out = t;
        if (reduced_motion) out.seconds = 0;
        return out;
    }
};

/// What a transitioning control painted: the eased properties' last leg, which the caller
/// keeps (a field of the State, a variable of the app). Both front ends step it once a frame
/// by the input's `dt`, so they paint the same values.
pub const Fade = struct {
    /// Fill, border and text colours as 0 to 255 channels, then opacity.
    from: [channels]f32 = @splat(0),
    to: [channels]f32 = @splat(0),
    elapsed: f32 = 0,
    live: bool = false,

    pub const channels = 13;

    /// The next state toward `target`, whose transitioned properties it eases in place: a new
    /// target starts a leg from the value painted now.
    pub fn next(fade: Fade, target: *style.Computed, t: Transition, dt: f32) Fade {
        const want = read(target.*);
        if (!fade.live) return .{ .from = want, .to = want, .elapsed = t.seconds, .live = true };
        var out = fade;
        if (!std.mem.eql(f32, &want, &fade.to)) {
            out.from = fade.value(t);
            out.to = want;
            out.elapsed = 0;
        }
        out.elapsed = @min(out.elapsed + dt, t.seconds);
        write(target, out.value(t), t);
        return out;
    }

    /// Seconds until the leg lands; 0 at rest.
    pub fn remaining(fade: Fade, t: Transition) f32 {
        return if (fade.live) t.seconds - fade.elapsed else 0;
    }

    fn value(fade: Fade, t: Transition) [channels]f32 {
        const u = if (t.seconds > 0) fade.elapsed / t.seconds else 1;
        const k = tweens.ease_table[@backingInt(t.ease)];
        const e = ((k[0] * u + k[1]) * u + k[2]) * u;
        var out: [channels]f32 = undefined;
        for (&out, fade.from, fade.to) |*o, a, b| o.* = a + (b - a) * e;
        return out;
    }

    pub fn read(c: style.Computed) [channels]f32 {
        var out: [channels]f32 = undefined;
        inline for (.{ c.box.fill, c.box.border_color, c.text.color }, 0..) |col, k| {
            out[k * 4 ..][0..4].* = .{ @floatFromInt(col.r), @floatFromInt(col.g), @floatFromInt(col.b), @floatFromInt(col.a) };
        }
        out[12] = c.box.opacity;
        return out;
    }

    pub fn write(c: *style.Computed, v: [channels]f32, t: Transition) void {
        if (t.fill) c.box.fill = color(v[0..4].*);
        if (t.border_color) c.box.border_color = color(v[4..8].*);
        if (t.text_color) c.text.color = color(v[8..12].*);
        if (t.opacity) c.box.opacity = v[12];
    }

    fn color(v: [4]f32) types.Color {
        return .rgba(@intFromFloat(@round(v[0])), @intFromFloat(@round(v[1])), @intFromFloat(@round(v[2])), @intFromFloat(@round(v[3])));
    }
};

/// CSS `animation` on a recipe control: keyframes over its root's colours and opacity, by
/// `Fade` channel (fill 0-3, border colour 4-7, text colour 8-11 as 0 to 255, opacity 12),
/// `at` in seconds of one iteration. The animated channels override the resolved values.
pub const Animation = struct {
    tracks: []const Track = &.{},
    /// One iteration.
    seconds: f32 = 0,
    /// `inf` repeats for ever.
    iterations: f32 = 1,
    /// Odd iterations play backwards.
    alternate: bool = false,

    pub const Track = struct { channel: u8, keys: []const keyframes.Key };

    /// Seconds into the current iteration at `elapsed`: the last iteration holds at its end.
    pub fn local(a: Animation, elapsed: f32) f32 {
        if (a.seconds <= 0) return 0;
        const total = a.seconds * a.iterations;
        const t = @min(elapsed, total);
        var n = @floor(t / a.seconds);
        var u = t - n * a.seconds;
        if (t >= total) {
            n = a.iterations - 1;
            u = a.seconds;
        }
        const back = a.alternate and @mod(n, 2) == 1;
        return if (back) a.seconds - u else u;
    }

    /// Whether frames are still needed at `elapsed`.
    pub fn running(a: Animation, elapsed: f32) bool {
        return a.tracks.len > 0 and elapsed < a.seconds * a.iterations;
    }
};

/// How far an `Animation` has played; the caller keeps it, as a `Fade`. Both front ends
/// advance it once a frame by the input's `dt`. Under reduced motion it holds the first
/// frame of an endless animation and the end of a finite one.
pub const Clock = struct {
    elapsed: f32 = 0,

    /// The next clock, with `a`'s channels sampled into `target`.
    pub fn next(clock: Clock, target: *style.Computed, a: Animation, dt: f32, reduced_motion: bool) Clock {
        var out = clock;
        out.elapsed = if (reduced_motion) (if (std.math.isInf(a.iterations)) 0 else a.seconds * a.iterations) else clock.elapsed + dt;
        var v = Fade.read(target.*);
        const t = a.local(out.elapsed);
        for (a.tracks) |track| v[track.channel] = keyframes.sample(track.keys, t);
        Fade.write(target, v, .{ .fill = true, .border_color = true, .text_color = true, .opacity = true });
        return out;
    }
};

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
    /// Text controls only.
    validation: Validation = .{},
    /// CSS `transition` of the root, and the state it keeps between frames; both or neither.
    transition: Transition = .{},
    fade: ?*Fade = null,
    /// CSS `animation` of the root, and its clock; both or neither.
    animation: Animation = .{},
    clock: ?*Clock = null,
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
    /// The transition's next state, which `end` keeps.
    fade: ?*Fade = null,
    fade_next: Fade = .{},
    transition: Transition = .{},
    clock: ?*Clock = null,
    clock_next: Clock = .{},
    animation: Animation = .{},

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
    var root = try recipe.resolve(Parts.root, use, null);
    // The eased root is what the parts inherit; `end` keeps the step, so resolving twice in
    // a frame (a text field's edit) steps once.
    const transition = options.transition.under(f.ctx.settings.reduced_motion);
    const fade_next = if (options.fade) |fade| fade.next(&root, transition, f.in.dt) else Fade{};
    const clock_next = if (options.clock) |clock| clock.next(&root, options.animation, f.in.dt, f.ctx.settings.reduced_motion) else Clock{};
    var child = use;
    child.parent = &root;
    child.local = &.{};
    return .{
        .fade = options.fade,
        .fade_next = fade_next,
        .transition = transition,
        .clock = options.clock,
        .clock_next = clock_next,
        .animation = options.animation,
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
    return beginPressable(f, id, options, model.button, .button, button_zig.activated);
}

/// A link (role link, `link.activated`: Enter, not Space) open for its children, as
/// `beginButton`.
pub fn beginLink(f: *Frame, id: types.Id, options: Options) style.Error!OpenControl {
    return beginPressable(f, id, options, model.link, .link, link_zig.activated);
}

fn beginPressable(f: *Frame, id: types.Id, options: Options, stock: model.Recipe, role: types.Role, comptime activated: fn (bool, bool, *const Input) bool) style.Error!OpenControl {
    try checkSemantics(f, options);
    var response = try policyResponse(f, id, options.recipe orelse stock, options, options.states);
    response.clicked = !options.states.disabled and activated(response.clicked, response.focused, f.in);
    const visible = visibleFocus(f, options);
    var control = try resolvedControl(f, options.recipe orelse stock, options, statesFor(options.states, response, visible));
    control.root.box.role = role;
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
    if (control.clock) |clock| {
        clock.* = control.clock_next;
        if (control.animation.running(clock.elapsed)) f.ctx.motion = @max(f.ctx.motion, f.in.dt);
    }
    if (control.fade) |fade| {
        fade.* = control.fade_next;
        f.ctx.motion = @max(f.ctx.motion, control.fade_next.remaining(control.transition));
    }
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

pub fn link(f: *Frame, id: types.Id, text: []const u8, options: Options) style.Error!types.Response {
    const control = try beginLink(f, id, options);
    _ = label(f, &control, text);
    end(f, &control);
    return control.response;
}

/// The button of select `name` (`select.button`) in the recipe's look (`model.select`); its
/// list is `select.list` or `listGrouped`, as for the theme select.
pub fn select(f: *Frame, comptime name: []const u8, comptime def: menu_zig.Def, st: *select_zig.SelectState, texts: []const []const u8, options: Options) style.Error!types.Response {
    std.debug.assert(texts.len == def.items.len);
    try checkSemantics(f, options);
    const recipe = options.recipe orelse model.select;
    const inter = &f.ctx.inter;
    // Every response before anything is built, as `select.button` asks them.
    const response = try policyResponse(f, .from(name), recipe, options, options.states);
    var hits: menu_zig.Hits = .{ .toggle = response.clicked, .outside = inter.response(.from(popover_zig.partName(name, "scrim"))).pressed };
    inline for (def.items, 0..) |o, k| hits.add(k, inter.response(.from(popover_zig.partName(name, o))));
    st.* = select_zig.advance(def, st.*, hits, f.in.events);
    const states = statesFor(options.states, response, visibleFocus(f, options));
    var control = try resolvedControl(f, recipe, options, states);
    control.node = f.open(.from(name), select_zig.valued(control.root.box, st.*));
    _ = f.interact(control.node, .button);
    f.tree().c.role[control.node.ix()] = @backingInt(a11y_tree.Role.combobox);
    _ = label(f, &control, texts[st.selected]);
    control.response = response;
    end(f, &control);
    expose(options.semantics, control.node, states);
    return response;
}

/// A toggle button over `value`, `States.toggled` while pressed; it flips as a button fires
/// (`toggle.toggle`).
pub fn toggle(f: *Frame, id: types.Id, value: *bool, text: []const u8, options: Options) style.Error!types.Response {
    try checkSemantics(f, options);
    const recipe = options.recipe orelse model.toggle;
    var before = options.states;
    before.toggled = value.*;
    var response = try policyResponse(f, id, recipe, options, before);
    response.clicked = !options.states.disabled and !options.states.read_only and button_zig.activated(response.clicked, response.focused, f.in);
    const next = base.toggle(value.*, response.clicked);
    var states = statesFor(options.states, response, visibleFocus(f, options));
    states.toggled = next;
    var control = try resolvedControl(f, recipe, options, states);
    control.root.box.role = .button;
    control.root.box.value = simd.b2f(next);
    control.node = f.open(id, control.root.box);
    _ = f.interact(control.node, if (states.disabled) .{} else .button);
    f.setCursor(f.tree().cursor(control.node.ix()) orelse .pointer, response.hovered);
    f.tree().c.role[control.node.ix()] = toggle_zig.role;
    _ = label(f, &control, text);
    end(f, &control);
    value.* = next;
    expose(options.semantics, control.node, states);
    return response;
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
    var response = if (interactive) responseFor(f, id, options.states.disabled) else types.Response{};
    if (interactive and !options.states.disabled) {
        // CSS :hover and :active hold on every ancestor of what the pointer is over or holds.
        const inter = &f.ctx.inter;
        const held = inSubtree(f, id, inter.active);
        response.held = held;
        response.hovered = inSubtree(f, id, inter.hot) and (inter.active == 0 or held);
    }
    var states = statesFor(options.states, response, false);
    states.focus_within = inSubtree(f, id, f.ctx.inter.focus);
    var root = try recipe.resolve(Parts.root, useFor(f, options, states), null);
    if (options.fade) |fade| {
        const transition = options.transition.under(f.ctx.settings.reduced_motion);
        fade.* = fade.next(&root, transition, f.in.dt);
        f.ctx.motion = @max(f.ctx.motion, fade.remaining(transition));
    }
    if (options.clock) |clock| {
        clock.* = clock.next(&root, options.animation, f.in.dt, f.ctx.settings.reduced_motion);
        if (options.animation.running(clock.elapsed)) f.ctx.motion = @max(f.ctx.motion, f.in.dt);
    }
    const node = f.open(id, root.box);
    if (interactive) _ = f.interact(node, .{ .hover = true, .click = true });
    return node;
}

/// Whether interaction id `k` is `id`'s node or in its subtree, as the previous frame laid
/// it out (CSS `:focus-within`, and :hover on an ancestor); false for 0 or `.none`.
pub fn inSubtree(f: *const Frame, id: types.Id, k: u32) bool {
    if (k == 0 or id == .none) return false;
    const t = f.prevTree();
    const at = t.find(id);
    const r = t.find(@fromBackingInt(k));
    return at != types.none and r != types.none and r >= at and r < t.c.end[at];
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
    return textControl(f, id, field, placeholder, options, .field, null, .{});
}

/// A number field over `value` (`number.Number`), running `range`, as `number.number`: a
/// recipe text field over its text. Give `Options.validation.range` the ends for `:invalid`.
pub fn number(f: *Frame, id: types.Id, value: *number_zig.Number, range: number_zig.Range, options: Options) style.Error!types.Response {
    return textControl(f, id, &value.text, "", options, .number, value, range);
}

/// A search field: a text field and a Clear button in one box, which takes the recipe's root
/// (`model.search`). Escape or the button clears it and the button gives focus back
/// (`search.behave`); the field is `id`, the button `search.clearId(id)`.
pub fn search(f: *Frame, id: types.Id, field: anytype, placeholder: []const u8, options: Options) style.Error!types.Response {
    return textControl(f, id, field, placeholder, options, .search, null, .{});
}

/// The text field's metrics from its resolved root and content; a search field's own field
/// keeps the stock padding, its root being the box around it.
pub fn fieldMetrics(root: style.Computed, content: style.Computed, comptime in_box: bool) base.Theme {
    var th = model.metrics(root);
    th.text_px = content.text.px;
    th.text = content.text.color;
    if (in_box) th.pad = base.Theme.default.pad;
    return th;
}

pub const TextKind = enum { field, search, number };

fn textControl(f: *Frame, id: types.Id, field: anytype, placeholder: []const u8, options: Options, comptime kind: TextKind, value: ?*number_zig.Number, range: number_zig.Range) style.Error!types.Response {
    const in_box = kind == .search;
    try checkSemantics(f, options);
    const recipe = options.recipe orelse if (in_box) model.search else model.input;
    var response = try policyResponse(f, id, recipe, options, options.states);
    const live = !options.states.disabled and !options.states.read_only;
    const clear = if (in_box) f.ctx.inter.response(search_zig.clearId(id)) else types.Response{};
    if (in_box and live and clear.clicked and field.text().len > 0) {
        f.ctx.inter.focus = @backingInt(id);
        response.focused = true;
    }
    var states = options.validation.states(statesFor(options.states, response, visibleFocus(f, options)), field.text());
    var control = try resolvedControl(f, recipe, options, states);
    var content = try control.part(Parts.content, null);
    var hint = try control.part(Parts.placeholder, null);
    var selection = try control.part(Parts.selection, null);
    var caret = try control.part(Parts.caret, null);
    var th = fieldMetrics(control.root, content, in_box);
    const editor = field.editor();
    const was_read_only = editor.mode.read_only;
    editor.mode.read_only = was_read_only or states.read_only or states.disabled;
    defer editor.mode.read_only = was_read_only;
    var last = f.lastRect(id);
    if (!in_box) {
        last.x1 -= control.root.box.pad[2] - control.root.box.pad[0];
        last.y0 += control.root.box.pad[1] - textfield_zig.padding(&th)[1];
    }
    const was_invalid = options.validation.invalid(field.text());
    switch (kind) {
        .field => textfield_zig.behave(field, &th, id, response, last, f.in),
        .search => if (live) search_zig.behave(field, &th, id, response, clear.clicked, last, f.in) else textfield_zig.behave(field, &th, id, response, last, f.in),
        .number => if (live) {
            _ = number_zig.behave(value.?, &th, id, response, last, range, f.in);
        } else number_zig.commit(value.?, range),
    }
    // The comptime front end resolves after this frame's edit: validity follows the new text.
    if (options.validation.invalid(field.text()) != was_invalid) {
        states.invalid = options.states.invalid or options.validation.invalid(field.text());
        control = try resolvedControl(f, recipe, options, states);
        content = try control.part(Parts.content, null);
        hint = try control.part(Parts.placeholder, null);
        selection = try control.part(Parts.selection, null);
        caret = try control.part(Parts.caret, null);
        th = fieldMetrics(control.root, content, in_box);
    }
    textfield_zig.platform(f, field);
    const box = if (in_box) f.open(.none, control.root.box) else types.Node.none;
    if (in_box) {
        control.node = f.open(id, search_zig.inputStyle(&th, field.scroll));
    } else {
        control.root.box.role = .text_input;
        control.root.box.scroll = .{ field.scroll, 0 };
        control.node = f.open(id, control.root.box);
    }
    _ = f.interact(control.node, if (states.disabled) .{} else types.Sense.any);
    f.setCursor(f.tree().cursor(control.node.ix()) orelse .text, response.hovered);
    const shown = textfield_zig.shown(field, &th, placeholder);
    for (shown.band) |band| {
        var b = selection.box;
        b.float = true;
        b.offset = .{ band[0], 0 };
        b.size = .{ .px(band[1] - band[0]), .px(textfield_zig.lineHeight(&th)) };
        _ = f.leaf(.none, b);
    }
    const text_part = if (shown.hint) hint else content;
    selectedText(f, shown.str, text_part, selection, shown.band, 0, textfield_zig.lineHeight(&th));
    var caret_box = caret.box;
    caret_box.float = true;
    caret_box.offset = .{ shown.caret, 0 };
    caret_box.size[1] = .px(textfield_zig.lineHeight(&th));
    _ = f.leaf(.none, caret_box);
    end(f, &control);
    if (in_box) {
        const some = field.text().len > 0;
        const b = f.open(search_zig.clearId(id), search_zig.clearStyle(&th, clear, some));
        // Hidden or disabled, it still senses (a click then clears nothing), as the comptime
        // front end's rects do.
        _ = f.interact(b, .{ .hover = true, .click = true });
        _ = f.textStyled(search_zig.clear_text, search_zig.clearText(&th, some), .{ .role = .label });
        f.close();
        f.close();
        search_zig.expose(f.tree(), box.ix(), b.ix(), some);
    }
    if (kind == .number) number_zig.expose(f.tree(), control.node.ix(), value.?.value);
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
