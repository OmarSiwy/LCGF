//! Shared recipes for radio groups, two-thumb ranges and busy indicators. Behavior remains
//! radio.step/range.step/spinner.phase; both front ends call the same bounded row builders.

const std = @import("std");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Strings = @import("../core/strings.zig").Strings;
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const a11y = @import("../a11y/tree.zig");
const outline = @import("../draw/outline.zig");
const geometry = @import("../draw/geometry.zig");
const base = @import("../widgets/base.zig");
const radio_native = @import("../widgets/radio.zig");
const range_native = @import("../widgets/range.zig");
const slider_native = @import("../widgets/slider.zig");
const spinner_native = @import("../widgets/spinner.zig");
const specs = @import("../comptime/spec.zig");
const events = @import("../comptime/events.zig");
const style = @import("../style/style.zig");
const model = @import("recipe.zig");
const controls = @import("recipe_controls.zig");
const Config = @import("recipe_comptime.zig").Config;
const Parts = style.Parts;
const none = types.none;

pub const radio_recipe = model.radio;
pub const range_recipe: model.Recipe = .{
    .parts = &.{
        .{ .id = Parts.root, .base = .{ .box = range_native.trackStyle(&.default) } },
        .{ .id = Parts.row, .base = .{ .box = .{ .dir = .x, .cross = .center } } },
        .{ .id = Parts.fill },
        .{ .id = Parts.thumb, .base = .{ .box = .{ .size = .{ .px(12), .px(12) }, .radius = 6 } } },
        .{ .id = Parts.tick, .base = .{ .box = .{ .size = .{ .px(1), .px(8) } } } },
        .{ .id = Parts.focus },
    },
    .rules = &model.slider_rules,
};
pub const spinner_recipe: model.Recipe = .{
    .parts = &.{
        .{ .id = Parts.root, .base = .{ .box = spinner_native.spinnerStyle(&.default) } },
        .{ .id = Parts.indicator, .base = .{ .box = .{ .size = .{ .px(4), .px(4) }, .radius = 2 } } },
    },
    .rules = &.{.{ .part = Parts.indicator, .declarations = &.{style.token(.fill, model.Names.accent)} }},
};

pub const radio_rows = 5;
pub const range_half_rows = 6;
pub const range_rows = 1 + 2 * range_half_rows;

const Visual = struct {
    hovered: u32 = none,
    held: u32 = none,
    focused: u32 = none,
    focus_visible: bool = false,

    fn add(visual: *Visual, index: u32, response: types.Response) void {
        if (response.hovered) visual.hovered = index;
        if (response.held) visual.held = index;
        if (response.focused) visual.focused = index;
    }
    fn states(visual: Visual, inherited: style.States, index: u32) style.States {
        var result = inherited;
        result.hovered = visual.hovered == index;
        result.held = visual.held == index;
        result.focused = visual.focused == index;
        result.focus_visible = result.focused and visual.focus_visible;
        return result;
    }
};

const Target = struct {
    tree: *Tree,
    texts: *Texts,
    strings: *Strings,
    parent: u32,

    fn frame(f: *Frame) Target {
        return .{ .tree = f.tree(), .texts = f.texts(), .strings = &f.ctx.strings[f.ctx.cur], .parent = f.ctx.stack[f.ctx.depth - 1] };
    }
    fn reserve(target: Target, nodes: usize, texts: usize, bytes: usize, semantic: ?*a11y.Semantics) style.Error!void {
        if (nodes > target.tree.cap -| target.tree.len or texts > target.texts.cap -| target.texts.len or bytes > target.strings.buf.len -| target.strings.len) return error.NoSpace;
        if (semantic) |s| if (nodes > s.cap -| target.tree.len) return error.NoSpace;
    }
    fn text(target: Target, parent: u32, bytes: []const u8, computed: style.Computed) u32 {
        const row = target.tree.push(parent, .none, &computed.box);
        target.tree.c.text[row] = target.texts.push(row, target.strings.add(bytes), &computed.text);
        return row;
    }
};

/// Resolution failures discard only this helper's new rows. Borrowed tables and caller
/// application values are untouched; no hidden allocation or retained renderer is involved.
const Mark = struct {
    nodes: u32,
    extras: u32,
    texts: u32,
    strings: u32,
    kids: f32,

    fn take(target: Target) Mark {
        return .{ .nodes = target.tree.len, .extras = target.tree.xlen, .texts = target.texts.len, .strings = target.strings.len, .kids = target.tree.c.nkids[target.parent] };
    }
    fn restore(mark: Mark, target: Target) void {
        target.tree.truncate(mark.nodes);
        target.tree.xlen = mark.extras;
        target.texts.len = mark.texts;
        target.strings.len = mark.strings;
        target.tree.c.nkids[target.parent] = mark.kids;
    }
};

fn childUse(use: model.Use, parent: *const style.Computed) model.Use {
    var child = use;
    child.parent = parent;
    child.local = &.{};
    return child;
}

/// Root policy uses the group's authoritative state; each interactive row uses its
/// actual response and selection state, just as the shared row builder does.
fn rowEnabled(recipe: model.Recipe, use: model.Use, states: style.States) style.Error!bool {
    if (states.disabled) return false;
    const root = try recipe.resolve(Parts.root, use, null);
    var inside = childUse(use, &root);
    inside.states = states;
    const item = try recipe.resolve(Parts.row, inside, null);
    return root.box.participation.layout and root.box.participation.hit and item.box.participation.layout and item.box.participation.hit;
}

fn rowResponse(f: *Frame, id: types.Id, recipe: model.Recipe, use: model.Use, states: style.States, focus_visible: bool) style.Error!types.Response {
    const response = controls.responseFor(f, id, states.disabled);
    const parent = f.tree().participation(f.ctx.stack[f.ctx.depth - 1]);
    if (!parent.layout or !parent.hit or !try rowEnabled(recipe, use, controls.statesFor(states, response, focus_visible))) return controls.responseFor(f, id, true);
    return response;
}

/// `fades`, one per option or none, ease each option's row along `transition` by `dt`.
fn radioBuild(target: Target, id: types.Id, selected: u32, captions: []const []const u8, recipe: model.Recipe, use: model.Use, visual: Visual, focus_offset: f32, semantic: ?*a11y.Semantics, transition: controls.Transition, fades: []controls.Fade, dt: f32) style.Error!types.Node {
    if (captions.len == 0 or captions.len > std.math.maxInt(u32) or selected >= captions.len) return error.InvalidValue;
    const nodes = std.math.mul(usize, captions.len, radio_rows) catch return error.NoSpace;
    var bytes: usize = 0;
    for (captions) |caption| bytes = std.math.add(usize, bytes, caption.len) catch return error.NoSpace;
    try target.reserve(std.math.add(usize, nodes, 1) catch return error.NoSpace, captions.len, bytes, semantic);
    const mark = Mark.take(target);
    errdefer mark.restore(target);
    const root = try recipe.resolve(Parts.root, use, null);
    const t = target.tree;
    const group = t.push(target.parent, id, &root.box);
    t.c.role[group] = @backingInt(a11y.Role.radio_group);
    controls.expose(semantic, @fromBackingInt(group), use.states);
    for (captions, 0..) |caption, index| {
        var item_use = childUse(use, &root);
        item_use.states = visual.states(use.states, @intCast(index));
        item_use.states.checked = selected == index;
        item_use.states.selected = selected == index;
        var option = try recipe.resolve(Parts.row, item_use, null);
        if (index < fades.len) fades[index] = fades[index].next(&option, transition, dt);
        const inside = childUse(item_use, &option);
        const background = try recipe.resolve(Parts.background, inside, null);
        const indicator = try recipe.resolve(Parts.indicator, inside, null);
        const label = try recipe.resolve(Parts.label, inside, null);
        const focus = try recipe.resolve(Parts.focus, inside, null);
        const row = t.push(group, radio_native.optionId(id, @intCast(index)), &option.box);
        t.c.role[row] = @backingInt(a11y.Role.radio);
        t.c.value[row] = @floatFromInt(@intFromBool(selected == index));
        t.c.sense[row] = if (use.states.disabled) 0 else @as(u8, @bitCast(types.Sense.button));
        const ring = t.push(row, .none, &background.box);
        _ = t.push(ring, .none, &indicator.box);
        t.seal(ring);
        _ = target.text(row, caption, label);
        _ = outline.append(t, row, @fromBackingInt(row), controls.outlineOptions(focus, focus_offset));
        t.seal(row);
        controls.expose(semantic, @fromBackingInt(row), item_use.states);
    }
    t.seal(group);
    return @fromBackingInt(group);
}

fn fixedDimension(box: types.Style, comptime axis: usize) style.Error!f32 {
    if (box.size[axis].kind != .px or box.min[axis] > box.max[axis]) return error.InvalidValue;
    const dimension = std.math.clamp(box.size[axis].v, box.min[axis], box.max[axis]);
    if (!std.math.isFinite(dimension) or dimension < 0) return error.InvalidValue;
    return dimension;
}

fn rangeBuild(target: Target, id: types.Id, value: [2]f32, lo: f32, hi: f32, recipe: model.Recipe, use: model.Use, visual: Visual, focus_offset: f32, semantic: ?*a11y.Semantics) style.Error!types.Node {
    try validRange(value, lo, hi);
    try target.reserve(range_rows, 0, 0, semantic);
    const mark = Mark.take(target);
    errdefer mark.restore(target);
    var root = try recipe.resolve(Parts.root, use, null);
    root.box.dir = .x;
    root.box.role = .none;
    root.box.gap = 0;
    const t = target.tree;
    const track = t.push(target.parent, id, &root.box);
    const f0 = base.fraction(value[0], lo, hi);
    const f1 = base.fraction(value[1], lo, hi);
    const mid = (f0 + f1) * 0.5;
    const half_sizes = [2]f32{ mid, 1 - mid };
    const fractions = [2]f32{ f0 / @max(mid, 1e-6), (f1 - mid) / @max(1 - mid, 1e-6) };
    for (0..2) |i| {
        var half_use = childUse(use, &root);
        half_use.states = visual.states(use.states, @intCast(i));
        var half = try recipe.resolve(Parts.row, half_use, null);
        const inside = childUse(half_use, &half);
        const fill = try recipe.resolve(Parts.fill, inside, null);
        var thumb = try recipe.resolve(Parts.thumb, inside, null);
        const focus = try recipe.resolve(Parts.focus, inside, null);
        const width = try fixedDimension(thumb.box, 0);
        const height = try fixedDimension(thumb.box, 1);
        half.box.dir = .x;
        half.box.cross = .center;
        half.box.gap = 0;
        half.box.size = .{ .pct(half_sizes[i]), .fill };
        half.box.role = .slider;
        half.box.value = value[i];
        const row = t.push(track, range_native.thumbId(id, @intCast(i)), &half.box);
        t.c.sense[row] = if (use.states.disabled) 0 else @as(u8, @bitCast(types.Sense.any));
        var before: types.Style = if (i == 0) .{} else fill.box;
        before.float = false;
        before.size = .{ .pct(fractions[i]), .fill };
        _ = t.push(row, .none, &before);
        const anchor = t.push(row, .none, &.{ .size = .{ .px(0), .px(0) } });
        thumb.box.float = true;
        thumb.box.offset[0] -= width / 2;
        thumb.box.offset[1] -= height / 2;
        const knob = t.push(anchor, .none, &thumb.box);
        t.seal(anchor);
        var after: types.Style = if (i == 0) fill.box else .{};
        after.float = false;
        after.size = .{ .pct(1 - fractions[i]), .fill };
        _ = t.push(row, .none, &after);
        _ = outline.append(t, row, @fromBackingInt(knob), controls.outlineOptions(focus, focus_offset));
        t.seal(row);
        controls.expose(semantic, @fromBackingInt(row), half_use.states);
    }
    t.seal(track);
    controls.expose(semantic, @fromBackingInt(track), use.states);
    if (semantic) |s| range_native.semantics(t, s, id, value, lo, hi);
    return @fromBackingInt(track);
}

fn spinnerBuild(target: Target, busy: bool, time: f64, recipe: model.Recipe, use_in: model.Use, semantic: ?*a11y.Semantics) style.Error!types.Node {
    try target.reserve(1 + spinner_native.dots, 0, 0, semantic);
    if (!std.math.isFinite(time) or time >= @as(f64, @floatFromInt(std.math.maxInt(u64))) / spinner_native.steps_per_second) return error.InvalidValue;
    const mark = Mark.take(target);
    errdefer mark.restore(target);
    var use = use_in;
    use.states.busy = busy;
    var root = try recipe.resolve(Parts.root, use, null);
    const width = try fixedDimension(root.box, 0);
    const height = try fixedDimension(root.box, 1);
    const head = if (use.environment.reduced_motion orelse false) 0 else spinner_native.phase(time);
    root.box.value = spinner_native.spinnerValue(busy);
    const t = target.tree;
    const row = t.push(target.parent, .none, &root.box);
    spinner_native.setRole(t, row);
    for (0..spinner_native.dots) |i| {
        var inside = childUse(use, &root);
        inside.states.selected = i == head;
        var dot = try recipe.resolve(Parts.indicator, inside, null);
        const native = spinner_native.dotStyle(&.default, @intCast(i), head, busy);
        dot.box.float = true;
        dot.box.offset[0] += native.offset[0] * width / spinner_native.size_px;
        dot.box.offset[1] += native.offset[1] * height / spinner_native.size_px;
        const fade: u32 = if (use.environment.reduced_transparency orelse false) 255 * @as(u32, @intFromBool(busy)) else native.fill.a;
        dot.box.fill.a = @intCast((@as(u32, dot.box.fill.a) * fade + 127) / 255);
        _ = t.push(row, .none, &dot.box);
    }
    t.seal(row);
    controls.expose(semantic, @fromBackingInt(row), use.states);
    return @fromBackingInt(row);
}

pub fn radio(f: *Frame, id: types.Id, selected: *u32, captions: []const []const u8, options: controls.Options) style.Error!types.Response {
    if (captions.len == 0 or captions.len > std.math.maxInt(u32) or selected.* >= captions.len) return error.InvalidValue;
    const recipe = options.recipe orelse radio_recipe;
    const use = controls.useFor(f, options, options.states);
    var visual: Visual = .{ .focus_visible = controls.visibleFocus(f, options) };
    var clicked: u32 = none;
    var combined: u8 = 0;
    for (captions, 0..) |_, i| {
        var states = use.states;
        states.checked = selected.* == i;
        states.selected = selected.* == i;
        const response = try rowResponse(f, radio_native.optionId(id, @intCast(i)), recipe, use, states, visual.focus_visible);
        visual.add(@intCast(i), response);
        if (response.clicked) clicked = @intCast(i);
        combined |= @bitCast(response);
    }
    const moved = if (!options.states.disabled and !options.states.read_only) radio_native.step(@intCast(captions.len), clicked, visual.focused, f.in) else null;
    var next = selected.*;
    if (moved) |move| {
        next = move.value;
        visual.focused = move.focus;
    }
    const transition = options.transition.under(f.ctx.settings.reduced_motion);
    const group = try radioBuild(Target.frame(f), id, next, captions, recipe, use, visual, options.focus_offset, options.semantics, transition, options.fades, f.in.dt);
    for (options.fades) |fade| f.ctx.motion = @max(f.ctx.motion, fade.remaining(transition));
    selected.* = next;
    if (moved) |move| f.ctx.inter.focus = @backingInt(radio_native.optionId(id, move.focus));
    if (visual.hovered != none) f.setCursor(f.tree().cursor(group.ix() + 1 + radio_rows * visual.hovered) orelse .pointer, true);
    var response: types.Response = @bitCast(combined);
    response.clicked = moved != null;
    return response;
}

pub fn range(f: *Frame, id: types.Id, value: *[2]f32, lo: f32, hi: f32, options: controls.Options) style.Error!types.Response {
    try validRange(value.*, lo, hi);
    const recipe = options.recipe orelse range_recipe;
    const use = controls.useFor(f, options, options.states);
    var visual: Visual = .{ .focus_visible = controls.visibleFocus(f, options) };
    var next = value.*;
    var combined: u8 = 0;
    const previous = f.prevTree();
    const along = alongAt(previous, previous.find(id), f.in.pointer);
    for (0..2) |i| {
        const response = try rowResponse(f, range_native.thumbId(id, @intCast(i)), recipe, use, use.states, visual.focus_visible);
        visual.add(@intCast(i), response);
        combined |= @bitCast(response);
        if (!options.states.disabled and !options.states.read_only) next = range_native.step(next, @intCast(i), response.held, along, response.focused, lo, hi, f.in);
    }
    const node = try rangeBuild(Target.frame(f), id, next, lo, hi, recipe, use, visual, options.focus_offset, options.semantics);
    value.* = next;
    if (visual.hovered != none) f.setCursor(f.tree().cursor(node.ix() + 1 + range_half_rows * visual.hovered) orelse .pointer, true);
    return @bitCast(combined);
}

fn validRange(value: [2]f32, lo: f32, hi: f32) style.Error!void {
    if (!std.math.isFinite(lo) or !std.math.isFinite(hi) or !(lo < hi) or !std.math.isFinite(value[0]) or !std.math.isFinite(value[1]) or value[0] > value[1] or value[0] < lo or value[1] > hi) return error.InvalidValue;
}

fn alongAt(t: *const Tree, node: u32, pointer: [2]f32) f32 {
    if (node == none or node >= t.len) return 0;
    const inverse = geometry.inverse(geometry.worldAt(t, node)) orelse return 0;
    const local = geometry.point(inverse, pointer);
    const bounds = t.rect(node);
    const start = bounds.x0 + t.c.pad_lo[0][node];
    const width = bounds.w() - t.c.pad_lo[0][node] - t.c.pad_hi[0][node];
    return (local[0] - start) / @max(width, 1);
}

pub fn spinner(f: *Frame, timer_id: types.Id, busy: bool, options: controls.Options) style.Error!types.Node {
    const use = controls.useFor(f, options, options.states);
    const node = try spinnerBuild(Target.frame(f), busy, f.in.time, options.recipe orelse spinner_recipe, use, options.semantics);
    if (busy and !(use.environment.reduced_motion orelse false) and f.tree().participation(node.ix()).paint) _ = f.timer(timer_id, 1.0 / @as(f32, spinner_native.steps_per_second), .repeat);
    return node;
}

const Kind = enum { radio, range, spinner };
fn defaults(comptime kind: Kind) model.Recipe {
    return switch (kind) {
        .radio => radio_recipe,
        .range => range_recipe,
        .spinner => spinner_recipe,
    };
}

fn Binding(comptime kind: Kind, comptime config: Config) type {
    return struct {
        fn check(comptime State: type) ?[]const u8 {
            if (config.states_field) |field| if (base.fieldError(State, "recipe states", field, style.States)) |err| return err;
            if (config.environment_field) |field| if (base.fieldError(State, "recipe environment", field, model.Environment)) |err| return err;
            if (config.tokens_field) |field| if (base.fieldError(State, "recipe tokens", field, style.tokens.Table)) |err| return err;
            if (config.recipe_field) |field| if (base.fieldError(State, "recipe", field, model.Recipe)) |err| return err;
            return null;
        }
        fn recipe(ui: anytype) model.Recipe {
            return if (config.recipe_field) |field| @field(ui.signals.state, field) else config.recipe orelse defaults(kind);
        }
        fn use(ui: anytype, in: *const Input) model.Use {
            return .{
                .tokens = if (config.tokens_field) |field| @field(ui.signals.state, field) else config.tokens,
                .scope = config.scope,
                .variants = config.variants,
                .states = if (config.states_field) |field| @field(ui.signals.state, field) else config.states,
                .environment = if (config.environment_field) |field| @field(ui.signals.state, field) else config.environment orelse model.Environment.fromInput(in).withSettings(&ui.frame_settings),
                .local = config.local,
                .color_policy = config.color_policy,
            };
        }
        fn visible(ui: anytype, in: *const Input) bool {
            return ui.focus_visible or (use(ui, in).environment.always_show_focus orelse false);
        }
    };
}

fn childName(comptime name: []const u8, comptime index: u32) [:0]const u8 {
    return std.fmt.comptimePrint("{s}.{d}", .{ name, index });
}

fn Gate(comptime kind: Kind, comptime name: []const u8, comptime bind: []const u8, comptime index: u32, comptime config: Config) type {
    return struct {
        const B = Binding(kind, config);
        pub const focusable = true;
        pub const push = base.FocusStop.push;
        pub fn inputAvailability(ui: anytype, in: *const Input) events.Availability {
            const use = B.use(ui, in);
            const Ui = @TypeOf(ui.*);
            const target = @field(Ui.Events.Widget, name);
            var response = ui.response(@backingInt(target), in);
            response.focused = ui.focus == target;
            var states = controls.statesFor(use.states, response, B.visible(ui, in));
            if (comptime kind == .radio) {
                states.checked = @field(ui.signals.state, bind) == index;
                states.selected = states.checked;
            }
            const enabled = rowEnabled(B.recipe(ui), use, states) catch |err| {
                ui.fail(err);
                return .{ .enabled = false, .activates = false };
            };
            return .{ .enabled = enabled, .activates = !use.states.read_only };
        }
    };
}

fn targetUi(ui: anytype, parent: u32) Target {
    return .{ .tree = &ui.tables.t, .texts = &ui.tables.tx, .strings = &ui.tables.strings, .parent = parent };
}

/// A failed optional composite still owns every descriptor row. Preserve its topology and
/// native tree ids with inert rows so later siblings retain their event/geometry indices.
/// Radio/range child ids derive from the group id; hashing the descriptor's dotted spelling
/// would produce a different tree id from the successful shared builder.
fn failedRows(ui: anytype, comptime node: specs.Spec, parent: u32, next: *u32, id: types.Id) void {
    const t = &ui.tables.t;
    const row = t.push(parent, id, &.{ .participation = .collapsed });
    next.* += 1;
    inline for (node.children, 0..) |child, i| failedRows(ui, child, row, next, if (child.id != null) id.with(i) else .none);
    t.seal(row);
}

pub const ct = struct {
    /// `captions` is a tuple of `[]const u8` State fields (`.first`) or literals ("First").
    pub fn radio(comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime captions: anytype, comptime config: Config) specs.Spec {
        if (captions.len == 0) @compileError("recipe radio needs at least one caption");
        const name = @tagName(id);
        var children: [captions.len]specs.Spec = undefined;
        inline for (&children, captions, 0..) |*child, caption, i| {
            const label: specs.Spec = if (@TypeOf(caption) == @EnumLiteral()) .{ .kind = .label, .bind = @tagName(caption) } else .{ .kind = .label, .text = caption };
            const ring: specs.Spec = .{ .kind = .col, .children = &.{.{ .kind = .col }} };
            child.* = .{ .kind = .row, .id = childName(name, i), .widget = Gate(.radio, childName(name, i), @tagName(bind), i, config), .children = &.{ ring, label, .{ .kind = .col } } };
        }
        const final = children;
        return .{ .kind = .col, .bind = @tagName(bind), .children = &final, .widget = RadioWidget(name, @tagName(bind), captions, config) };
    }
    pub fn range(comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime range_: slider_native.Range, comptime config: Config) specs.Spec {
        if (!(range_.lo < range_.hi)) @compileError("recipe range requires lo below hi");
        const name = @tagName(id);
        const anchor: specs.Spec = .{ .kind = .col, .children = &.{.{ .kind = .col }} };
        const children = [4]specs.Spec{ .{ .kind = .col }, anchor, .{ .kind = .col }, .{ .kind = .col } };
        var halves: [2]specs.Spec = undefined;
        for (&halves, 0..) |*half, i| half.* = .{ .kind = .row, .id = childName(name, i), .widget = Gate(.range, childName(name, i), @tagName(bind), i, config), .children = &children };
        const final = halves;
        return .{ .kind = .row, .bind = @tagName(bind), .children = &final, .widget = RangeWidget(name, @tagName(bind), range_, config) };
    }
    pub fn spinner(comptime busy: @EnumLiteral(), comptime config: Config) specs.Spec {
        const dots: [spinner_native.dots]specs.Spec = @splat(.{ .kind = .col });
        return .{ .kind = .col, .bind = @tagName(busy), .children = &dots, .widget = SpinnerWidget(@tagName(busy), config) };
    }
};

fn RadioWidget(comptime name: []const u8, comptime bind: []const u8, comptime captions: anytype, comptime config: Config) type {
    return struct {
        const B = Binding(.radio, config);
        pub const wakeAfter = if (config.fade_field != null) wake else {};

        /// The options' fades: `config.fade_field` names a `[captions.len]controls.Fade`.
        fn fades(ui: anytype) []controls.Fade {
            const f = config.fade_field orelse return &.{};
            return &@field(ui.signals.state, f);
        }

        fn wake(ui: anytype, in: *const Input) f32 {
            _ = in;
            const transition = config.transition.under(ui.frame_settings.reduced_motion);
            for (fades(ui)) |fade| if (fade.remaining(transition) > 0) return 0;
            return types.inf;
        }
        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            if (B.check(State)) |err| return err;
            return radio_native.bindError(State, field);
        }
        pub fn push(ui: anytype, comptime node: specs.Spec, parent: u32, next: *u32, in: *const Input) void {
            const Ui = @TypeOf(ui.*);
            var labels: [captions.len][]const u8 = undefined;
            var visual: Visual = .{ .focus_visible = B.visible(ui, in) };
            inline for (captions, 0..) |caption, i| {
                labels[i] = if (@TypeOf(caption) == @EnumLiteral()) @field(ui.signals.state, @tagName(caption)) else caption;
                var response = ui.response(next.* + 1 + radio_rows * @as(u32, @intCast(i)), in);
                response.focused = ui.focus == @field(Ui.Events.Widget, childName(name, i));
                visual.add(i, response);
            }
            const group = radioBuild(targetUi(ui, parent), .hash(name), @field(ui.signals.state, bind), &labels, B.recipe(ui), B.use(ui, in), visual, config.focus_offset, null, config.transition.under(ui.frame_settings.reduced_motion), fades(ui), in.dt) catch |err| {
                ui.fail(err);
                failedRows(ui, node, parent, next, .hash(name));
                return;
            };
            if (visual.hovered != none) ui.setCursor(ui.tables.t.cursor(group.ix() + 1 + radio_rows * visual.hovered) orelse .pointer, true);
            next.* += 1 + radio_rows * captions.len;
        }
        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) @TypeOf(event) {
            const use = B.use(ui, in);
            if (use.states.disabled or use.states.read_only) return null;
            const Ui = @TypeOf(ui.*);
            var clicked: u32 = none;
            var focused: u32 = none;
            inline for (0..captions.len) |i| {
                const response = base.ctResponse(ui, row + 1 + radio_rows * i, event, in);
                if (response.clicked) clicked = i;
                if (response.focused) focused = i;
            }
            const move = radio_native.step(captions.len, clicked, focused, in) orelse return null;
            ui.signals.set(Ui.field(bind), move.value);
            inline for (0..captions.len) |i| if (move.focus == i) {
                ui.focus = @field(Ui.Events.Widget, childName(name, i));
                if (clicked == none) return @unionInit(Ui.Events.Event, childName(name, i), {});
            };
            return null;
        }
    };
}

fn RangeWidget(comptime name: []const u8, comptime bind: []const u8, comptime ends: slider_native.Range, comptime config: Config) type {
    return struct {
        const B = Binding(.range, config);
        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            if (B.check(State)) |err| return err;
            return range_native.bindError(State, field);
        }
        pub fn push(ui: anytype, comptime node: specs.Spec, parent: u32, next: *u32, in: *const Input) void {
            const Ui = @TypeOf(ui.*);
            var visual: Visual = .{ .focus_visible = B.visible(ui, in) };
            inline for (0..2) |i| {
                var response = ui.response(next.* + 1 + range_half_rows * @as(u32, @intCast(i)), in);
                response.focused = ui.focus == @field(Ui.Events.Widget, childName(name, i));
                visual.add(i, response);
            }
            const track = rangeBuild(targetUi(ui, parent), .hash(name), @field(ui.signals.state, bind), ends.lo, ends.hi, B.recipe(ui), B.use(ui, in), visual, config.focus_offset, null) catch |err| {
                ui.fail(err);
                failedRows(ui, node, parent, next, .hash(name));
                return;
            };
            if (visual.hovered != none) ui.setCursor(ui.tables.t.cursor(track.ix() + 1 + range_half_rows * visual.hovered) orelse .pointer, true);
            next.* += range_rows;
        }
        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
            const use = B.use(ui, in);
            if (use.states.disabled or use.states.read_only) return;
            const Ui = @TypeOf(ui.*);
            const previous: [2]f32 = @field(ui.signals.state, bind);
            var value = previous;
            const along = if (ui.built) alongAt(&ui.tables.t, row + 1, in.pointer) else 0;
            inline for (0..2) |i| {
                const response = base.ctResponse(ui, row + 1 + range_half_rows * i, event, in);
                value = range_native.step(value, i, response.held, along, response.focused, ends.lo, ends.hi, in);
            }
            if (!std.meta.eql(value, previous)) ui.signals.set(Ui.field(bind), value);
        }
    };
}

fn SpinnerWidget(comptime busy: []const u8, comptime config: Config) type {
    return struct {
        const B = Binding(.spinner, config);
        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            if (B.check(State)) |err| return err;
            return spinner_native.check(State, field);
        }
        pub fn push(ui: anytype, comptime node: specs.Spec, parent: u32, next: *u32, in: *const Input) void {
            _ = spinnerBuild(targetUi(ui, parent), @field(ui.signals.state, busy), in.time, B.recipe(ui), B.use(ui, in), null) catch |err| {
                ui.fail(err);
                failedRows(ui, node, parent, next, .none);
                return;
            };
            next.* += 1 + spinner_native.dots;
        }
        pub fn wakeAfter(ui: anytype, in: *const Input) f32 {
            var use = B.use(ui, in);
            use.states.busy = @field(ui.signals.state, busy);
            if (!use.states.busy or (use.environment.reduced_motion orelse false)) return types.inf;
            const root = B.recipe(ui).resolve(Parts.root, use, null) catch return types.inf;
            if (!root.box.participation.layout or !root.box.participation.paint) return types.inf;
            return 1.0 / @as(f32, spinner_native.steps_per_second);
        }
    };
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
