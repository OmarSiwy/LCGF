//! Dedicated recipe compositions for navigation and overlays. State and clock belong to the
//! caller; actions are returned data. The stock widgets' pure behavior remains authoritative.
//! Call floating overlays under the root after ordinary content. Styles are resolved before
//! opening rows, so a failed token never leaves an unbalanced frame or commits a menu action.

const std = @import("std");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const a11y = @import("../a11y/tree.zig");
const style = @import("../style/style.zig");
const model = @import("recipe.zig");
const controls = @import("recipe_controls.zig");
const part_helpers = @import("recipe_parts.zig");
const ct_controls = @import("recipe_comptime.zig");
const base = @import("../widgets/base.zig");
const menu_z = @import("../widgets/menu.zig");
const popup_z = @import("../widgets/popover.zig");
const tip_z = @import("../widgets/tooltip.zig");
const crumb_z = @import("../widgets/breadcrumb.zig");
const toast_z = @import("../widgets/toast.zig");
const specs = @import("../comptime/spec.zig");
const Parts = style.Parts;
const Id = types.Id;
pub const Options = controls.Options;
pub const MenuState = menu_z.MenuState;
pub const MenuDef = menu_z.Def;
pub const Tip = tip_z.Tip;
pub const ToastState = toast_z.ToastState;
/// Borrowed item content. Accelerator text is a label, not a registered shortcut. An indicator
/// may be any short string (for example ">" for a submenu). Separators have no action or label.
pub const MenuContent = struct { accelerator: []const u8 = "", indicator: []const u8 = "", separator: bool = false };
pub const MenuOptions = struct { style: Options = .{}, item_states: []const style.States = &.{}, content: []const MenuContent = &.{} };
pub const TooltipOptions = struct { style: Options = .{}, arrow: bool = false };
pub const names = struct {
    pub const scrim = Id.from("scrim");
    pub const submenu = Id.from("submenu");
    pub const current = Id.from("current");
    pub const layer = Id.from("layer");
    pub const accelerator = Id.from("accelerator");
    pub const arrow = Id.from("arrow");
};

const common_rules = [_]style.Rule{
    .{ .part = Parts.root, .declarations = &.{ style.token(.text_color, model.Names.text), style.token(.text_size, model.Names.text_size[2]) } },
    .{ .part = Parts.label, .declarations = &.{style.inherit(.text_color)} },
    .{ .part = names.current, .declarations = &.{style.inherit(.text_color)} },
    .{ .part = Parts.focus, .declarations = &.{ style.set(.border_width, 0), style.token(.border_color, model.Names.accent) } },
    .{ .part = Parts.focus, .require = .{ .focus_visible = true }, .declarations = &.{style.set(.border_width, 2)} },
    .{ .part = Parts.row, .require = .{ .disabled = true }, .declarations = &.{style.token(.text_color, model.Names.muted)} },
};
const popup_rules = common_rules ++ [_]style.Rule{
    .{ .part = Parts.root, .declarations = &.{ style.token(.fill, model.Names.surface), style.token(.border_color, model.Names.hot), style.token(.radius, model.Names.radius[2]) } },
    .{ .part = names.submenu, .declarations = &.{ style.token(.fill, model.Names.surface), style.token(.border_color, model.Names.hot), style.token(.radius, model.Names.radius[2]) } },
    .{ .part = Parts.row, .require = .{ .selected = true }, .declarations = &.{style.token(.fill, model.Names.hot)} },
};
const popup_box: types.Style = .{ .float = true, .offset = .{ 0, 4 }, .pad = @splat(8), .gap = 4, .border = 1, .radius = 4 };
const label_part: model.Part = .{ .id = Parts.label, .base = .{ .box = .{ .role = .label } } };
const focus_part: model.Part = .{ .id = Parts.focus, .base = .{ .box = .{ .radius = 4 } } };

pub const recipes = struct {
    pub const menu: model.Recipe = .{
        .parts = &.{
            .{ .id = Parts.root, .base = .{ .box = .{ .float = true, .offset = .{ 0, 4 }, .pad = @splat(4), .border = 1, .radius = 4 } } },
            .{ .id = names.scrim, .base = .{ .box = .{ .float = true } } },
            .{ .id = names.submenu, .base = .{ .box = .{ .float = true, .offset = .{ 2, -2 }, .pad = @splat(4), .border = 1, .radius = 4 } } },
            .{ .id = Parts.row, .base = .{ .box = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = .{ 8, 4, 8, 4 }, .cross = .center, .radius = 4 } } },
            label_part,
            focus_part,
            .{ .id = Parts.support, .base = .{ .box = .{ .size = .{ .fill, .px(0) }, .participation = .{ .hit = false, .semantics = false } } } },
            .{ .id = names.accelerator, .base = .{ .box = .{ .role = .label, .pad = .{ 16, 0, 0, 0 } } } },
            .{ .id = Parts.indicator, .base = .{ .box = .{ .role = .label, .pad = .{ 8, 0, 0, 0 } } } },
            .{ .id = Parts.separator, .base = .{ .box = .{ .size = .{ .fill, .px(1) }, .participation = .{ .hit = false } } } },
        },
        .rules = &(popup_rules ++ [_]style.Rule{
            .{ .part = names.accelerator, .declarations = &.{style.token(.text_color, model.Names.muted)} },
            .{ .part = Parts.indicator, .declarations = &.{style.inherit(.text_color)} },
            .{ .part = Parts.separator, .declarations = &.{style.token(.fill, model.Names.hot)} },
        }),
    };
    pub const popover: model.Recipe = .{ .parts = &.{ .{ .id = Parts.root, .base = .{ .box = popup_box } }, .{ .id = names.scrim, .base = .{ .box = .{ .float = true } } }, label_part }, .rules = &popup_rules };
    pub const tooltip: model.Recipe = .{
        .parts = &.{
            .{ .id = Parts.root, .base = .{ .box = popup_box } },
            label_part,
            .{ .id = names.arrow, .base = .{ .box = .{ .float = true, .size = .{ .px(8), .px(8) }, .offset = .{ 8, -4 }, .transform = .{ 0.70710677, 0.70710677, -0.70710677, 0.70710677, 0, 0 }, .participation = .{ .hit = false, .semantics = false } } } },
        },
        .rules = &(popup_rules ++ [_]style.Rule{
            .{ .part = Parts.root, .declarations = &.{style.token(.fill, model.Names.held)} },
            .{ .part = names.arrow, .declarations = &.{style.inherit(.fill)} },
        }),
    };
    pub const breadcrumb: model.Recipe = .{
        .parts = &.{
            .{ .id = Parts.root, .base = .{ .box = .{ .dir = .x, .gap = 4, .cross = .center } } },
            .{ .id = Parts.row, .base = .{ .box = .{ .dir = .x, .pad = @splat(4), .radius = 4, .cross = .center } } },
            .{ .id = Parts.separator, .base = .{ .box = .{ .size = .{ .px(4), .px(4) }, .radius = 2 } } },
            .{ .id = names.current, .base = .{ .box = .{ .role = .label } } },
            label_part,
            focus_part,
        },
        .rules = &(common_rules ++ [_]style.Rule{
            .{ .part = Parts.row, .declarations = &.{style.token(.text_color, model.Names.accent)} },
            .{ .part = Parts.row, .require = .{ .hovered = true }, .declarations = &.{style.token(.fill, model.Names.hot)} },
            .{ .part = Parts.row, .require = .{ .held = true }, .declarations = &.{style.token(.fill, model.Names.held)} },
            .{ .part = Parts.separator, .declarations = &.{style.token(.fill, model.Names.hot)} },
        }),
    };
    pub const toast: model.Recipe = .{
        .parts = &.{
            .{ .id = Parts.root, .base = .{ .box = .{ .dir = .x, .pad = .{ 16, 8, 16, 8 }, .border = 1, .radius = 4, .cross = .center } } },
            .{ .id = names.layer, .base = .{ .box = .{ .float = true, .pad = @splat(16), .main = .end, .cross = .center } } },
            label_part,
        },
        .rules = &popup_rules,
    };
};

/// Shared preparation seam: runtime and compile-time overlay builders consume these same
/// resolved values. The pointer used for inheritance is borrowed only during each call.
pub const Resolved = struct {
    recipe: model.Recipe,
    use: model.Use,
    root: style.Computed,
    pub fn part(value: *const Resolved, id: Id, states: style.States) style.Error!style.Computed {
        return value.under(id, value.root, states);
    }
    pub fn under(value: *const Resolved, id: Id, parent: style.Computed, states: style.States) style.Error!style.Computed {
        var use = value.use;
        use.parent = &parent;
        use.states = states;
        use.local = &.{};
        return value.recipe.resolve(id, use, null);
    }
};

pub fn resolve(default_recipe: model.Recipe, options: Options, use: model.Use) style.Error!Resolved {
    const recipe = options.recipe orelse default_recipe;
    return .{ .recipe = recipe, .use = use, .root = try recipe.resolve(Parts.root, use, null) };
}

fn prepared(f: *const Frame, default_recipe: model.Recipe, options: Options, states: style.States) style.Error!Resolved {
    return resolve(default_recipe, options, controls.useFor(f, options, states));
}
fn room(f: *const Frame, options: Options, rows: usize) style.Error!void {
    if (options.semantics) |s| if (rows > s.cap -| f.tree().len) return error.NoSpace;
}
fn anchor(box: types.Style, at: types.Rect, side: bool) types.Style {
    var out = box;
    out.float = true;
    out.offset[0] += if (side) at.x1 else at.x0;
    out.offset[1] += if (side) at.y0 else at.y1;
    return out;
}
fn viewport(box: types.Style, size: [2]f32) types.Style {
    var out = box;
    out.float = true;
    out.size = .{ .px(size[0]), .px(size[1]) };
    return out;
}
fn expose(f: *Frame, node: types.Node, role: a11y.Role, options: Options, states: style.States) void {
    f.tree().c.role[node.ix()] = @backingInt(role);
    controls.expose(options.semantics, node, states);
}

pub const menuTrigger = controls.button;
pub fn popoverTrigger(f: *Frame, id: Id, open: *bool, text: []const u8, options: Options) style.Error!types.Response {
    var state = options;
    state.states.expanded = open.*;
    const response = try controls.button(f, id, text, state);
    open.* = popup_z.toggle(open.*, response.clicked and !options.states.read_only);
    return response;
}

fn itemState(options: MenuOptions, k: usize) style.States {
    var states = options.style.states.merge(if (options.item_states.len == 0) .{} else options.item_states[k]);
    states.disabled = states.disabled or itemContent(options, k).separator;
    return states;
}
fn itemContent(options: MenuOptions, k: usize) MenuContent {
    return if (options.content.len == 0) .{} else options.content[k];
}
fn currentItem(comptime def: MenuDef, state: MenuState) usize {
    return if (state.sub) def.items.len + state.sub_active else state.active;
}
fn moveEnabled(comptime def: MenuDef, state: MenuState, options: MenuOptions, backwards: bool) MenuState {
    var next = state;
    const length = if (next.sub) def.sub.len else def.items.len;
    for (0..length) |_| {
        if (!itemState(options, currentItem(def, next)).disabled) break;
        const ev = [_]Input.Event{.{ .kind = .press, .code = if (backwards) popup_z.keys.up else popup_z.keys.down }};
        next = menu_z.advance(def, next, .{ .hovered = next.hover }, &ev);
    }
    return next;
}

/// The native menu behavior plus disabled-item filtering. A read-only item remains navigable
/// but cannot produce an action. No item array, command registry or callback is retained.
pub fn menuState(comptime def: MenuDef, state: MenuState, hits: menu_z.Hits, events: []const Input.Event, options: MenuOptions) style.Error!MenuState {
    comptime if (def.items.len == 0 or def.items.len + def.sub.len >= menu_z.no_item or (def.sub_at != null and def.sub.len == 0)) @compileError("a recipe menu needs 1..254 items and a nonempty declared submenu");
    comptime if ((def.sub_at == null) != (def.sub.len == 0) or (def.sub_at != null and def.sub_at.? >= def.items.len)) @compileError("recipe menu sub_at must name a top-level item and accompany sub items");
    if (options.item_states.len != 0 and options.item_states.len != def.count()) return error.InvalidValue;
    if (options.content.len != 0 and options.content.len != def.count()) return error.InvalidValue;
    for (options.content) |content| if (content.separator and (content.accelerator.len != 0 or content.indicator.len != 0)) return error.InvalidValue;
    if ((hits.clicked != menu_z.no_item and hits.clicked >= def.count()) or (hits.hovered != menu_z.no_item and hits.hovered >= def.count())) return error.InvalidValue;
    if (state.open and (state.active >= def.items.len or (state.sub and (def.sub_at == null or state.sub_active >= def.sub.len)))) return error.InvalidValue;
    if (options.style.states.disabled) return .{};
    var safe = hits;
    if (safe.clicked != menu_z.no_item and (itemState(options, safe.clicked).disabled or itemState(options, safe.clicked).read_only)) safe.clicked = menu_z.no_item;
    if (safe.hovered != menu_z.no_item and itemState(options, safe.hovered).disabled) safe.hovered = menu_z.no_item;
    var next = menu_z.advance(def, state, safe, &.{});
    if (!next.open) return next;
    next = moveEnabled(def, next, options, false);
    for (events) |event| {
        if (!next.open) break;
        const item = itemState(options, currentItem(def, next));
        if ((event.code == popup_z.keys.enter or event.code == popup_z.keys.space or event.code == popup_z.keys.right) and (item.disabled or item.read_only)) continue;
        next = menu_z.advance(def, next, .{ .hovered = next.hover }, &.{event});
        if (next.open) next = moveEnabled(def, next, options, event.code == popup_z.keys.up or event.code == popup_z.keys.end);
    }
    return next;
}

const ItemPaint = struct {
    body: style.Computed,
    label: style.Computed,
    focus: style.Computed,
    states: style.States,
    content: MenuContent = .{},
    support: style.Computed = .{},
    accelerator: style.Computed = .{},
    indicator: style.Computed = .{},
    separator: style.Computed = .{},
};
fn menuItem(value: *const Resolved, options: MenuOptions, state: MenuState, response: types.Response, visible: bool, comptime def: MenuDef, k: usize) style.Error!ItemPaint {
    var states = controls.statesFor(itemState(options, k), response, visible);
    states.selected = menu_z.highlighted(def, state, @intCast(k));
    states.focus_visible = states.selected and visible;
    states.expanded = def.sub_at == @as(u8, @intCast(k)) and state.sub;
    const body = try value.part(Parts.row, states);
    return .{
        .body = body,
        .label = try value.under(Parts.label, body, states),
        .focus = try value.under(Parts.focus, body, states),
        .states = states,
        .content = itemContent(options, k),
        .support = try value.under(Parts.support, body, states),
        .accelerator = try value.under(names.accelerator, body, states),
        .indicator = try value.under(Parts.indicator, body, states),
        .separator = try value.part(Parts.separator, options.style.states),
    };
}
fn emitItem(f: *Frame, id: Id, text: []const u8, item: ItemPaint, options: Options) void {
    if (item.content.separator) {
        const separator = f.leaf(id, item.separator.box);
        expose(f, separator, .separator, options, .{});
        return;
    }
    const node = f.open(id, item.body.box);
    _ = f.interact(node, if (item.states.disabled) .{} else popup_z.overlay_sense);
    expose(f, node, .menu_item, options, item.states);
    _ = f.textStyled(text, item.label.text, item.label.box);
    if (item.content.accelerator.len != 0 or item.content.indicator.len != 0) _ = f.leaf(.none, item.support.box);
    if (item.content.accelerator.len != 0) _ = f.textStyled(item.content.accelerator, item.accelerator.text, item.accelerator.box);
    if (item.content.indicator.len != 0) _ = f.textStyled(item.content.indicator, item.indicator.text, item.indicator.box);
    _ = f.outline(node, controls.outlineOptions(item.focus, options.focus_offset));
    f.close();
}

/// `trigger` is the actual styled button's returned response, preserving keyboard activation.
/// The opening key is consumed once; subsequent arrows/Home/End/submenu/Enter use menu.advance.
pub fn menu(f: *Frame, comptime name: []const u8, comptime def: MenuDef, state: *MenuState, texts: []const []const u8, trigger: types.Response, options: MenuOptions) style.Error!u8 {
    if (texts.len != def.count() or (options.item_states.len != 0 and options.item_states.len != def.count()) or (options.content.len != 0 and options.content.len != def.count())) return error.InvalidValue;
    var hits: menu_z.Hits = .{ .toggle = trigger.clicked, .outside = f.ctx.inter.response(.from(popup_z.partName(name, "scrim"))).pressed };
    inline for (0..comptime def.count()) |k| hits.add(k, controls.responseFor(f, .from(popup_z.partName(name, def.name(k))), itemState(options, k).disabled));
    const keyboard_open = !state.open and trigger.focused and (popup_z.keyPressed(f.in, popup_z.keys.down) or popup_z.keyPressed(f.in, popup_z.keys.up) or trigger.clicked);
    hits.toggle = hits.toggle or keyboard_open;
    var next = try menuState(def, state.*, hits, if (keyboard_open) &.{} else f.in.events, options);
    if (keyboard_open and popup_z.keyPressed(f.in, popup_z.keys.up)) {
        next.active = @intCast(def.items.len - 1);
        next = moveEnabled(def, next, options, true);
    }
    var states = options.style.states;
    states.expanded = next.open;
    const value = try prepared(f, recipes.menu, options.style, states);
    if (!value.root.box.participation.hit or !value.root.box.participation.layout) next = .{};
    if (!next.open) {
        state.* = next;
        return next.chosen;
    }
    const scrim = try value.part(names.scrim, states);
    const submenu = try value.part(names.submenu, states);
    var items: [def.count()]ItemPaint = undefined;
    inline for (0..comptime def.count()) |k| items[k] = try menuItem(&value, options, next, f.ctx.inter.response(.from(popup_z.partName(name, def.name(k)))), controls.visibleFocus(f, options.style), def, k);
    var rows: usize = 2 + @as(usize, @intFromBool(next.sub));
    inline for (0..comptime def.count()) |k| if (k < def.items.len or next.sub) {
        const content = items[k].content;
        rows += if (content.separator) 1 else 3 + @as(usize, @intFromBool(content.accelerator.len != 0 or content.indicator.len != 0)) + @as(usize, @intFromBool(content.accelerator.len != 0)) + @as(usize, @intFromBool(content.indicator.len != 0));
    };
    try room(f, options.style, rows);
    state.* = next;
    _ = f.interact(f.open(.from(popup_z.partName(name, "scrim")), viewport(scrim.box, f.in.viewport)), popup_z.overlay_sense);
    defer f.close();
    const panel = f.open(.from(popup_z.partName(name, "panel")), anchor(value.root.box, f.lastRect(.from(name)), false));
    _ = f.interact(panel, popup_z.overlay_sense);
    expose(f, panel, .menu, options.style, states);
    inline for (0..def.items.len) |k| emitItem(f, .from(popup_z.partName(name, def.name(k))), texts[k], items[k], options.style);
    f.close();
    if (def.sub_at) |at| if (next.sub) {
        const sub = f.open(.from(popup_z.partName(name, "sub")), anchor(submenu.box, f.lastRect(.from(popup_z.partName(name, def.items[at]))), true));
        _ = f.interact(sub, popup_z.overlay_sense);
        expose(f, sub, .menu, options.style, states);
        inline for (def.items.len..comptime def.count()) |k| emitItem(f, .from(popup_z.partName(name, def.name(k))), texts[k], items[k], options.style);
        f.close();
    };
    if (options.style.semantics) |s| menu_z.semantics(f.tree(), s, name, def, next);
    return next.chosen;
}

pub fn popover(f: *Frame, comptime name: []const u8, open: *bool, options: Options) style.Error!?part_helpers.OpenPart {
    var next = popup_z.dismiss(open.* and !options.states.disabled, f.ctx.inter.response(.from(popup_z.partName(name, "scrim"))).pressed, popup_z.keyPressed(f.in, popup_z.keys.escape));
    var states = options.states;
    states.expanded = next;
    const value = try prepared(f, recipes.popover, options, states);
    const scrim = try value.part(names.scrim, states);
    next = next and value.root.box.participation.layout and value.root.box.participation.hit;
    try room(f, options, 2);
    open.* = next;
    if (!next) return null;
    _ = f.interact(f.open(.from(popup_z.partName(name, "scrim")), viewport(scrim.box, f.in.viewport)), popup_z.overlay_sense);
    const node = f.open(.from(popup_z.partName(name, "panel")), anchor(value.root.box, f.lastRect(.from(name)), false));
    _ = f.interact(node, popup_z.overlay_sense);
    expose(f, node, .dialog, options, states);
    if (options.semantics) |s| popup_z.semantics(f.tree(), s, name);
    return .{ .node = node, .computed = value.root, .options = .{ .recipe = value.recipe, .use = value.use, .semantics = options.semantics } };
}
pub const endPopover = popup_z.end;
pub const popoverText = part_helpers.text;

pub fn tooltip(f: *Frame, target: Id, tip: *Tip, response: types.Response, text: []const u8, options: Options) style.Error!?types.Node {
    return tooltipDecorated(f, target, tip, response, text, .{ .style = options });
}

/// Opt-in arrow is an ordinary transformed square. Its named part can supply a caller-owned
/// texture/material instead. The arrow's offset is relative to the bubble border-box origin.
pub fn tooltipDecorated(f: *Frame, target: Id, tip: *Tip, response: types.Response, text: []const u8, decoration: TooltipOptions) style.Error!?types.Node {
    const options = decoration.style;
    const interested = !options.states.disabled and (response.hovered or response.focused);
    const next = tip_z.advance(tip.*, interested, if (response.focused) @max(f.in.dt, tip_z.delay) else f.in.dt, popup_z.keyPressed(f.in, popup_z.keys.escape));
    const value = try prepared(f, recipes.tooltip, options, options.states);
    const label = try value.part(Parts.label, options.states);
    const arrow = if (decoration.arrow) try value.part(names.arrow, options.states) else null;
    try room(f, options, if (decoration.arrow) 3 else 2);
    tip.* = next;
    if (interested and !next.shown and !next.dismissed) f.ctx.motion = @max(f.ctx.motion, tip_z.delay - next.rested);
    if (!next.shown) return null;
    const node = f.open(.none, anchor(value.root.box, f.lastRect(target), false));
    defer f.close();
    expose(f, node, .tooltip, options, options.states);
    if (arrow) |part| _ = f.leaf(.none, arrowBox(value.root.box, part.box));
    _ = f.textStyled(text, label.text, label.box);
    return node;
}

fn arrowBox(parent: types.Style, arrow: types.Style) types.Style {
    var box = arrow;
    box.float = true;
    box.offset[0] -= parent.pad[0];
    box.offset[1] -= parent.pad[1];
    box.participation.hit = false;
    box.participation.semantics = false;
    return box;
}

pub fn breadcrumb(f: *Frame, ids: []const Id, titles: []const []const u8, options: Options) style.Error!u32 {
    if (titles.len != ids.len + 1) return error.InvalidValue;
    const value = try prepared(f, recipes.breadcrumb, options, options.states);
    const separator = try value.part(Parts.separator, options.states);
    var current_states = options.states;
    current_states.current = true;
    const current = try value.part(names.current, current_states);
    // Preflight all per-link resolution before opening the navigation row.
    for (ids) |id| {
        const states = controls.statesFor(options.states, controls.responseFor(f, id, options.states.disabled), controls.visibleFocus(f, options));
        const body = try value.part(Parts.row, states);
        _ = try value.under(Parts.label, body, states);
        _ = try value.under(Parts.focus, body, states);
    }
    try room(f, options, 2 + 4 * ids.len);
    const nav = f.open(.none, value.root.box);
    defer f.close();
    expose(f, nav, .navigation, options, options.states);
    var clicked: u32 = types.none;
    var focused: u32 = types.none;
    for (ids, titles[0..ids.len], 0..) |id, title, k| {
        const response = controls.responseFor(f, id, options.states.disabled);
        const states = controls.statesFor(options.states, response, controls.visibleFocus(f, options));
        const body = try value.part(Parts.row, states);
        const label = try value.under(Parts.label, body, states);
        const focus = try value.under(Parts.focus, body, states);
        const node = f.open(id, body.box);
        _ = f.interact(node, if (states.disabled) .{} else .button);
        expose(f, node, .link, options, states);
        _ = f.textStyled(title, label.text, label.box);
        _ = f.outline(node, controls.outlineOptions(focus, options.focus_offset));
        f.setCursor(f.tree().cursor(node.ix()) orelse .pointer, response.hovered);
        f.close();
        _ = f.leaf(.none, separator.box);
        if (!states.disabled and !states.read_only) {
            if (response.clicked) clicked = @intCast(k);
            if (response.focused) focused = @intCast(k);
        }
    }
    const last = f.textStyled(titles[ids.len], current.text, current.box);
    controls.expose(options.semantics, last, current_states);
    return crumb_z.follow(clicked, focused, f.in);
}

pub fn toast(f: *Frame, id: Id, state: *ToastState, trigger: bool, text: []const u8, options: Options) style.Error!?types.Node {
    const hovered = f.ctx.inter.response(id).hovered;
    const next = toast_z.advance(state.*, trigger and !options.states.disabled, hovered, f.in.dt);
    const value = try prepared(f, recipes.toast, options, options.states);
    const layer = try value.part(names.layer, options.states);
    const label = try value.part(Parts.label, options.states);
    try room(f, options, 3);
    state.* = next;
    if (!next.shown) return null;
    if (!hovered) f.ctx.motion = @max(f.ctx.motion, next.left);
    _ = f.open(.none, viewport(layer.box, f.in.viewport));
    defer f.close();
    var body = value.root.box;
    if (!(value.use.environment.reduced_motion orelse false)) body.opacity *= base.unit(next.left / toast_z.fade);
    const node = f.open(id, body);
    defer f.close();
    _ = f.interact(node, .{ .hover = true });
    expose(f, node, .alert, options, options.states);
    const label_node = f.textStyled(text, label.text, label.box);
    if (options.semantics) |s| s.c.labelled_by[node.ix()] = label_node.ix();
    return node;
}

fn configError(comptime State: type, comptime config: ct_controls.Config) ?[]const u8 {
    if (config.states_field) |field| if (base.fieldError(State, "overlay states", field, style.States)) |err| return err;
    if (config.environment_field) |field| if (base.fieldError(State, "overlay environment", field, model.Environment)) |err| return err;
    if (config.tokens_field) |field| if (base.fieldError(State, "overlay tokens", field, style.tokens.Table)) |err| return err;
    if (config.recipe_field) |field| if (base.fieldError(State, "overlay recipe", field, model.Recipe)) |err| return err;
    return null;
}

fn configured(st: anytype, in: *const Input, comptime config: ct_controls.Config) Options {
    return .{
        .recipe = if (config.recipe_field) |field| @field(st, field) else config.recipe,
        .tokens = if (config.tokens_field) |field| @field(st, field) else config.tokens,
        .states = if (config.states_field) |field| @field(st, field) else config.states,
        .environment = if (config.environment_field) |field| @field(st, field) else config.environment orelse model.Environment.fromInput(in),
        .scope = config.scope,
        .variants = config.variants,
        .local = config.local,
        .focus_offset = config.focus_offset,
        .color_policy = config.color_policy,
    };
}

fn configuredValue(default_recipe: model.Recipe, options: Options, states: style.States) style.Error!Resolved {
    return resolve(default_recipe, options, .{
        .states = states,
        .tokens = options.tokens,
        .scope = options.scope,
        .variants = options.variants,
        .local = options.local,
        .environment = options.environment orelse .{},
        .color_policy = options.color_policy,
    });
}

fn focusVisible(options: Options) bool {
    return options.states.focus_visible or (options.environment.?.always_show_focus orelse false);
}

fn named(comptime node: specs.Spec, comptime name: []const u8) bool {
    return node.id != null and std.mem.eql(u8, node.id.?, name);
}

const TagKind = enum { trigger_label, trigger_focus, item_label, item_focus, item_support, item_accelerator, item_indicator, content, arrow };
fn Tag(comptime owner: []const u8, comptime kind: TagKind, comptime index: usize) type {
    return struct {
        pub const overlay_owner = owner;
        pub const overlay_kind = kind;
        pub const overlay_index = index;
    };
}

fn tagged(comptime node: specs.Spec, comptime owner: []const u8) bool {
    const W = node.widget orelse return false;
    return @hasDecl(W, "overlay_owner") and std.mem.eql(u8, W.overlay_owner, owner);
}

fn ringPart(t: *const @import("../core/tree.zig").Tree, target: Id, focus: style.Computed, offset: f32) popup_z.Part {
    const row = t.find(target);
    if (row == types.none) return .{ .style = .{ .participation = .collapsed } };
    const options = controls.outlineOptions(focus, offset);
    const radii = options.radii orelse @import("../core/tree.zig").radiiOf(t.x.row[t.c.extra[row]].radii, t.c.look[row].radius);
    const growth = options.width + options.offset;
    const expanded: [4]f32 = @max(@as(@Vector(4, f32), radii) + @as(@Vector(4, f32), @splat(growth)), @as(@Vector(4, f32), @splat(0)));
    return .{ .style = .{ .float = true, .size = .{ .px(0), .px(0) }, .border = options.width, .border_color = options.color, .radii = expanded, .paint_reference = row, .paint_outset = @splat(growth) } };
}

/// The existing overlay page remains the builder/renderer. Configured state, tokens and
/// environment are read on every frame. `failure_field` is an explicit caller-owned
/// `?style.Error`, cleared once in step and retaining the first error of that frame.
/// ComptimePage has no focus manager; its host supplies trigger focus through Config.states
/// or states_field. Open-menu keys and Escape are handled directly by the stock behavior.
pub const ct = struct {
    pub const Config = struct {
        style: ct_controls.Config = .{},
        trigger: ct_controls.Config = .{},
        failure_field: []const u8 = "style_error",
        /// Optional []const style.States with exactly MenuDef.count() entries.
        item_states_field: ?[]const u8 = null,
        menu_content: []const MenuContent = &.{},
        /// Optional []const MenuContent with exactly MenuDef.count() entries.
        menu_content_field: ?[]const u8 = null,
        tooltip_arrow: bool = false,
    };
    pub const ComptimePage = popup_z.ComptimePage;

    pub fn Menu(comptime th: base.Theme, comptime name: @EnumLiteral(), comptime field: @EnumLiteral(), comptime def: MenuDef, comptime config: Config) type {
        const H = Hook(.menu, th, name, field, name, def, config);
        return struct {
            pub const button = H.button;
            pub const check = H.check;
            pub const step = H.step;
            pub const part = H.part;
            pub fn layer() specs.Spec {
                var top: [def.items.len]specs.Spec = undefined;
                for (&top, 0..) |*node, k| node.* = H.item(k);
                var panel = specs.col(.{}, top);
                panel.id = popup_z.partName(@tagName(name), "panel");
                if (def.sub.len == 0) return .{ .kind = .col, .id = popup_z.partName(@tagName(name), "scrim"), .children = &.{panel} };
                var sub: [def.sub.len]specs.Spec = undefined;
                for (&sub, 0..) |*node, k| node.* = H.item(def.items.len + k);
                var submenu = specs.col(.{}, sub);
                submenu.id = popup_z.partName(@tagName(name), "sub");
                return .{ .kind = .col, .id = popup_z.partName(@tagName(name), "scrim"), .children = &.{ panel, submenu } };
            }
        };
    }

    pub fn Popover(comptime th: base.Theme, comptime name: @EnumLiteral(), comptime field: @EnumLiteral(), comptime config: Config) type {
        const H = Hook(.popover, th, name, field, name, .{ .items = &.{} }, config);
        return struct {
            pub const button = H.button;
            pub const label = H.label;
            pub const check = H.check;
            pub const step = H.step;
            pub const part = H.part;
            /// Only labels made with H.label are styled by this recipe. Other caller content
            /// retains its own Spec style and the stock page's default label typography.
            pub const layer = popup_z.Popover(th, name, field).layer;
        };
    }

    pub fn Tooltip(comptime th: base.Theme, comptime target: @EnumLiteral(), comptime field: @EnumLiteral(), comptime config: Config) type {
        const H = Hook(.tooltip, th, target, field, target, .{ .items = &.{} }, config);
        return struct {
            pub const button = H.button;
            pub const check = H.check;
            pub const step = H.step;
            pub const part = H.part;
            pub fn bubble(comptime text: @EnumLiteral()) specs.Spec {
                if (config.tooltip_arrow) return .{ .kind = .col, .bind = @tagName(field), .children = &.{ .{ .kind = .col, .widget = Tag(@tagName(target), .arrow, 0) }, H.label(text) } };
                return .{ .kind = .col, .bind = @tagName(field), .children = &.{H.label(text)} };
            }
        };
    }

    pub fn Toast(comptime th: base.Theme, comptime name: @EnumLiteral(), comptime field: @EnumLiteral(), comptime trigger: @EnumLiteral(), comptime config: Config) type {
        const H = Hook(.toast, th, name, field, trigger, .{ .items = &.{} }, config);
        return struct {
            pub const button = H.button;
            pub const check = H.check;
            pub const step = H.step;
            pub const part = H.part;
            pub fn layer(comptime text: @EnumLiteral()) specs.Spec {
                return .{ .kind = .col, .bind = @tagName(field), .children = &.{.{ .kind = .row, .id = @tagName(name), .children = &.{H.label(text)} }} };
            }
        };
    }

    /// Breadcrumb uses the regular ComptimeUi so each link participates in its existing
    /// focus chain. The returned action remains the caller's u32 field, as in the stock trail.
    pub fn breadcrumb(comptime activated: @EnumLiteral(), comptime links: anytype, comptime current: @EnumLiteral(), comptime config: ct_controls.Config) specs.Spec {
        var kids: [2 * links.len + 1]specs.Spec = undefined;
        for (links, 0..) |link, k| {
            if (link.len != 2) @compileError("a recipe breadcrumb link is .{ id, title }");
            kids[2 * k] = .{ .kind = .row, .id = @tagName(link[0]), .children = &.{ .{ .kind = .label, .bind = @tagName(link[1]) }, .{ .kind = .col } } };
            kids[2 * k].widget = BreadcrumbLink(@tagName(link[0]), config);
            kids[2 * k + 1] = .{ .kind = .col };
        }
        kids[2 * links.len] = .{ .kind = .label, .bind = @tagName(current) };
        var out = specs.row(.{}, kids);
        out.bind = @tagName(activated);
        out.widget = Breadcrumb(activated, links, current, config);
        return out;
    }
};

const OverlayKind = enum { menu, popover, tooltip, toast };
fn Hook(comptime kind: OverlayKind, comptime th: base.Theme, comptime name: @EnumLiteral(), comptime field: @EnumLiteral(), comptime trigger: @EnumLiteral(), comptime def: MenuDef, comptime config: ct.Config) type {
    _ = th;
    const owner = @tagName(name);
    const trigger_name = @tagName(trigger);
    const field_name = @tagName(field);
    const defaults = switch (kind) {
        .menu => recipes.menu,
        .popover => recipes.popover,
        .tooltip => recipes.tooltip,
        .toast => recipes.toast,
    };
    return struct {
        fn fail(st: anytype, err: style.Error) void {
            if (@field(st, config.failure_field) == null) @field(st, config.failure_field) = err;
        }
        fn failedPart(st: anytype, err: style.Error) ?popup_z.Part {
            fail(st, err);
            return null;
        }
        fn textPart(comptime n: specs.Spec, st: anytype, v: anytype, value: style.Computed, override: ?[]const u8) ?popup_z.Part {
            const bytes = override orelse @field(st, n.bind.?);
            const strings = &v.page.tables.strings;
            if (bytes.len > strings.buf.len - strings.len) return failedPart(st, error.NoSpace);
            return .{ .style = value.box, .text = value.text, .content = override };
        }
        pub fn check(comptime State: type) ?[]const u8 {
            if (base.fieldError(State, "overlay error", config.failure_field, ?style.Error)) |err| return err;
            if (configError(State, config.style)) |err| return err;
            if (configError(State, config.trigger)) |err| return err;
            if (config.item_states_field) |f| if (base.fieldError(State, "menu item states", f, []const style.States)) |err| return err;
            if (config.menu_content_field) |f| if (base.fieldError(State, "menu content", f, []const MenuContent)) |err| return err;
            return switch (kind) {
                .menu => menu_z.checkMenu(State, def, field_name),
                .popover => popup_z.checkOpen(State, owner, field_name),
                .tooltip => tip_z.checkTip(State, field_name),
                .toast => toast_z.checkToast(State, field_name),
            };
        }
        pub fn button(comptime text: @EnumLiteral()) specs.Spec {
            return .{ .kind = .row, .id = trigger_name, .children = &.{
                .{ .kind = .label, .bind = @tagName(text), .widget = Tag(owner, .trigger_label, 0) },
                .{ .kind = .col, .widget = Tag(owner, .trigger_focus, 0) },
            } };
        }
        pub fn label(comptime text: @EnumLiteral()) specs.Spec {
            return .{ .kind = .label, .bind = @tagName(text), .widget = Tag(owner, .content, 0) };
        }
        fn item(comptime k: usize) specs.Spec {
            return .{ .kind = .row, .id = popup_z.partName(owner, def.name(k)), .children = &.{
                .{ .kind = .label, .bind = def.name(k), .widget = Tag(owner, .item_label, k) },
                .{ .kind = .col, .widget = Tag(owner, .item_support, k) },
                .{ .kind = .label, .bind = def.name(k), .widget = Tag(owner, .item_accelerator, k) },
                .{ .kind = .label, .bind = def.name(k), .widget = Tag(owner, .item_indicator, k) },
                .{ .kind = .col, .widget = Tag(owner, .item_focus, k) },
            } };
        }
        fn menuOptions(st: anytype, options: Options) MenuOptions {
            return .{ .style = options, .item_states = if (config.item_states_field) |f| @field(st, f) else &.{}, .content = if (config.menu_content_field) |f| @field(st, f) else config.menu_content };
        }
        fn triggerValue(st: anytype, v: anytype) style.Error!Resolved {
            const options = configured(st, v.in, config.trigger);
            var response = v.responseOf(trigger_name);
            response.focused = options.states.focused;
            return configuredValue(model.button, options, controls.statesFor(options.states, response, focusVisible(options)));
        }
        fn overlayValue(st: anytype, v: anytype) style.Error!Resolved {
            const options = configured(st, v.in, config.style);
            var states = options.states;
            if (kind == .menu) states.expanded = @field(st, field_name).open;
            if (kind == .popover) states.expanded = @field(st, field_name);
            return configuredValue(defaults, options, states);
        }
        fn preflight(value: *const Resolved) style.Error!void {
            for (value.recipe.parts) |p| _ = try value.part(p.id, value.use.states);
        }
        pub fn step(sig: anytype, v: anytype) void {
            const st = &sig.state;
            @field(st, config.failure_field) = null;
            const options = configured(st, v.in, config.style);
            const trigger_options = configured(st, v.in, config.trigger);
            const trigger_value = triggerValue(st, v) catch |err| {
                fail(st, err);
                return;
            };
            preflight(&trigger_value) catch |err| {
                fail(st, err);
                return;
            };
            const value = overlayValue(st, v) catch |err| {
                fail(st, err);
                return;
            };
            preflight(&value) catch |err| {
                fail(st, err);
                return;
            };
            const active = !options.states.disabled and value.root.box.participation.layout and value.root.box.participation.hit;
            const can_trigger = !trigger_options.states.disabled and !trigger_options.states.read_only and trigger_value.root.box.participation.layout and trigger_value.root.box.participation.hit;
            const response = v.responseOf(trigger_name);
            const pressed = can_trigger and @import("../widgets/button.zig").activated(response.clicked, trigger_options.states.focused, v.in);
            switch (kind) {
                .menu => {
                    const opts = menuOptions(st, options);
                    var hits: menu_z.Hits = .{ .toggle = pressed, .outside = v.responseOf(popup_z.partName(owner, "scrim")).pressed };
                    inline for (0..comptime def.count()) |k| hits.add(k, v.responseOf(popup_z.partName(owner, def.name(k))));
                    const before: MenuState = @field(st, field_name);
                    const opening = !before.open and can_trigger and trigger_options.states.focused and (pressed or popup_z.keyPressed(v.in, popup_z.keys.up) or popup_z.keyPressed(v.in, popup_z.keys.down));
                    hits.toggle = hits.toggle or opening;
                    var next = menuState(def, before, hits, if (opening) &.{} else v.in.events, opts) catch |err| {
                        fail(st, err);
                        return;
                    };
                    if (opening and popup_z.keyPressed(v.in, popup_z.keys.up)) {
                        next.active = @intCast(def.items.len - 1);
                        next = moveEnabled(def, next, opts, true);
                    }
                    inline for (0..comptime def.count()) |k| _ = menuItem(&value, opts, next, v.responseOf(popup_z.partName(owner, def.name(k))), focusVisible(options), def, k) catch |err| {
                        fail(st, err);
                        return;
                    };
                    sig.set(field, if (active) next else .{});
                },
                .popover => sig.set(field, popup_z.dismiss(popup_z.toggle(@field(st, field_name), pressed) and active, v.responseOf(popup_z.partName(owner, "scrim")).pressed, popup_z.keyPressed(v.in, popup_z.keys.escape))),
                .tooltip => {
                    const interested = active and !trigger_options.states.disabled and trigger_value.root.box.participation.layout and trigger_value.root.box.participation.hit and (response.hovered or trigger_options.states.focused);
                    sig.set(field, tip_z.advance(@field(st, field_name), interested, if (trigger_options.states.focused) @max(v.in.dt, tip_z.delay) else v.in.dt, popup_z.keyPressed(v.in, popup_z.keys.escape)));
                },
                .toast => sig.set(field, toast_z.advance(@field(st, field_name), pressed and active, v.responseOf(owner).hovered, v.in.dt)),
            }
        }
        pub fn part(comptime n: specs.Spec, st: anytype, v: anytype) ?popup_z.Part {
            if (comptime named(n, trigger_name) or (tagged(n, owner) and (n.widget.?.overlay_kind == .trigger_label or n.widget.?.overlay_kind == .trigger_focus))) {
                if (@field(st, config.failure_field) != null) return null;
                const value = triggerValue(st, v) catch |err| return failedPart(st, err);
                if (comptime named(n, trigger_name)) {
                    var box = value.root.box;
                    box.role = .button;
                    return .{ .style = box };
                }
                const p = value.part(if (n.widget.?.overlay_kind == .trigger_label) Parts.label else Parts.focus, value.use.states) catch |err| return failedPart(st, err);
                if (n.widget.?.overlay_kind == .trigger_focus) return ringPart(&v.page.tables.t, .from(trigger_name), p, config.trigger.focus_offset);
                return textPart(n, st, v, p, null);
            }
            const is_field = comptime n.kind == .col and n.bind != null and std.mem.eql(u8, n.bind.?, field_name);
            const is_overlay = comptime tagged(n, owner) or named(n, popup_z.partName(owner, "scrim")) or named(n, popup_z.partName(owner, "panel")) or named(n, popup_z.partName(owner, "sub")) or (kind == .toast and named(n, owner)) or is_field;
            const is_item = comptime blk: {
                if (kind == .menu) for (0..def.count()) |k| if (named(n, popup_z.partName(owner, def.name(k)))) break :blk true;
                break :blk false;
            };
            if (comptime !is_overlay and !is_item) return .{ .style = n.style };
            if (@field(st, config.failure_field) != null) return null;
            const value = overlayValue(st, v) catch |err| return failedPart(st, err);
            const options = configured(st, v.in, config.style);
            switch (kind) {
                .menu => {
                    const state: MenuState = @field(st, field_name);
                    if (!state.open) return null;
                    if (comptime named(n, popup_z.partName(owner, "scrim"))) {
                        const p = value.part(names.scrim, value.use.states) catch |err| return failedPart(st, err);
                        return .{ .style = viewport(p.box, v.in.viewport) };
                    }
                    if (comptime named(n, popup_z.partName(owner, "panel"))) return .{ .style = anchor(value.root.box, v.last.of(owner), false), .role = .menu };
                    if (comptime named(n, popup_z.partName(owner, "sub"))) {
                        if (!state.sub) return null;
                        const p = value.part(names.submenu, value.use.states) catch |err| return failedPart(st, err);
                        return .{ .style = anchor(p.box, v.last.of(popup_z.partName(owner, def.items[def.sub_at.?])), true), .role = .menu };
                    }
                    inline for (0..comptime def.count()) |k| if (comptime named(n, popup_z.partName(owner, def.name(k))) or (tagged(n, owner) and n.widget.?.overlay_index == k)) {
                        const item_paint = menuItem(&value, menuOptions(st, options), state, v.responseOf(popup_z.partName(owner, def.name(k))), focusVisible(options), def, k) catch |err| return failedPart(st, err);
                        if (item_paint.content.separator) {
                            if (comptime named(n, popup_z.partName(owner, def.name(k)))) return .{ .style = item_paint.separator.box, .role = .separator };
                            return null;
                        }
                        if (comptime named(n, popup_z.partName(owner, def.name(k)))) return .{ .style = item_paint.body.box, .role = .menu_item };
                        if (comptime n.widget.?.overlay_kind == .item_focus) return ringPart(&v.page.tables.t, .from(popup_z.partName(owner, def.name(k))), item_paint.focus, config.style.focus_offset);
                        if (comptime n.widget.?.overlay_kind == .item_support) return if (item_paint.content.accelerator.len == 0 and item_paint.content.indicator.len == 0) null else .{ .style = item_paint.support.box };
                        if (comptime n.widget.?.overlay_kind == .item_accelerator) return if (item_paint.content.accelerator.len == 0) null else textPart(n, st, v, item_paint.accelerator, item_paint.content.accelerator);
                        if (comptime n.widget.?.overlay_kind == .item_indicator) return if (item_paint.content.indicator.len == 0) null else textPart(n, st, v, item_paint.indicator, item_paint.content.indicator);
                        return textPart(n, st, v, item_paint.label, null);
                    };
                },
                .popover => {
                    if (!@field(st, field_name)) return null;
                    if (comptime named(n, popup_z.partName(owner, "scrim"))) {
                        const p = value.part(names.scrim, value.use.states) catch |err| return failedPart(st, err);
                        return .{ .style = viewport(p.box, v.in.viewport) };
                    }
                    if (comptime named(n, popup_z.partName(owner, "panel"))) return .{ .style = anchor(value.root.box, v.last.of(owner), false), .role = .dialog };
                },
                .tooltip => {
                    if (!@field(st, field_name).shown) return null;
                    if (is_field) return .{ .style = anchor(value.root.box, v.last.of(owner), false), .role = .tooltip };
                    if (comptime tagged(n, owner) and n.widget.?.overlay_kind == .arrow) {
                        const arrow = value.part(names.arrow, value.use.states) catch |err| return failedPart(st, err);
                        return .{ .style = arrowBox(value.root.box, arrow.box) };
                    }
                },
                .toast => {
                    const state: ToastState = @field(st, field_name);
                    if (!state.shown) return null;
                    if (is_field) {
                        const p = value.part(names.layer, value.use.states) catch |err| return failedPart(st, err);
                        return .{ .style = viewport(p.box, v.in.viewport) };
                    }
                    if (comptime named(n, owner)) {
                        var box = value.root.box;
                        if (!(value.use.environment.reduced_motion orelse false)) box.opacity *= base.unit(state.left / toast_z.fade);
                        return .{ .style = box, .role = .alert };
                    }
                },
            }
            const p = value.part(Parts.label, value.use.states) catch |err| return failedPart(st, err);
            return textPart(n, st, v, p, null);
        }
    };
}

fn breadcrumbOptions(ui: anytype, in: *const Input, comptime config: ct_controls.Config) Options {
    var options = configured(&ui.signals.state, in, config);
    if (config.environment_field == null and config.environment == null) options.environment = model.Environment.fromInput(in).withSettings(&ui.frame_settings);
    return options;
}

fn BreadcrumbLink(comptime name: [:0]const u8, comptime config: ct_controls.Config) type {
    return struct {
        pub const focusable = true;
        pub const Payload = void;
        pub fn inputAvailability(ui: anytype, in: *const Input) @import("../comptime/events.zig").Availability {
            const options = breadcrumbOptions(ui, in, config);
            const value = configuredValue(recipes.breadcrumb, options, options.states) catch |err| {
                ui.fail(err);
                return .{ .enabled = false, .activates = false };
            };
            const U = @TypeOf(ui.*);
            const me = @field(U.Events.Widget, name);
            var response = ui.response(@backingInt(me), in);
            response.focused = ui.focus == me;
            const states = controls.statesFor(options.states, response, ui.focus_visible or focusVisible(options));
            const body = value.part(Parts.row, states) catch |err| {
                ui.fail(err);
                return .{ .enabled = false, .activates = false };
            };
            return .{ .enabled = !states.disabled and value.root.box.participation.layout and value.root.box.participation.hit and body.box.participation.layout and body.box.participation.hit, .activates = !states.read_only };
        }
    };
}

fn Breadcrumb(comptime activated: @EnumLiteral(), comptime links: anytype, comptime current: @EnumLiteral(), comptime config: ct_controls.Config) type {
    return struct {
        const Bundle = struct { options: Options, value: Resolved, separator: style.Computed, current: style.Computed, items: [links.len]ItemPaint };
        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            _ = field;
            if (configError(State, config)) |err| return err;
            if (base.fieldError(State, "breadcrumb activation", @tagName(activated), u32)) |err| return err;
            inline for (links) |link| if (base.fieldError(State, "breadcrumb label", @tagName(link[1]), []const u8)) |err| return err;
            return base.fieldError(State, "breadcrumb current", @tagName(current), []const u8);
        }
        fn prepare(ui: anytype, in: *const Input) style.Error!Bundle {
            const options = breadcrumbOptions(ui, in, config);
            const value = try configuredValue(recipes.breadcrumb, options, options.states);
            var current_states = options.states;
            current_states.current = true;
            var items: [links.len]ItemPaint = undefined;
            const U = @TypeOf(ui.*);
            inline for (links, 0..) |link, k| {
                const me = @field(U.Events.Widget, @tagName(link[0]));
                var response = ui.response(@backingInt(me), in);
                response.focused = ui.focus == me;
                const states = controls.statesFor(options.states, response, ui.focus_visible or focusVisible(options));
                const body = try value.part(Parts.row, states);
                items[k] = .{ .body = body, .label = try value.under(Parts.label, body, states), .focus = try value.under(Parts.focus, body, states), .states = states };
            }
            return .{ .options = options, .value = value, .items = items, .separator = try value.part(Parts.separator, options.states), .current = try value.part(names.current, current_states) };
        }
        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
            _ = row;
            const U = @TypeOf(ui.*);
            const bundle = prepare(ui, in) catch |err| {
                ui.fail(err);
                ui.signals.set(activated, types.none);
                return;
            };
            var clicked: u32 = types.none;
            var focused: u32 = types.none;
            inline for (links, 0..) |link, k| {
                const me = @field(U.Events.Widget, @tagName(link[0]));
                const item_paint = bundle.items[k];
                if (!item_paint.states.disabled and !item_paint.states.read_only and item_paint.body.box.participation.hit and item_paint.body.box.participation.layout and bundle.value.root.box.participation.hit and bundle.value.root.box.participation.layout) {
                    if (event) |e| if (std.meta.activeTag(e) == me) {
                        clicked = @intCast(k);
                    };
                    if (ui.focus == me) focused = @intCast(k);
                }
            }
            ui.signals.set(activated, crumb_z.follow(clicked, focused, in));
        }
        fn pushText(ui: anytype, parent: u32, comptime field: []const u8, value: style.Computed) void {
            const t = &ui.tables.t;
            const node = t.push(parent, .none, &value.box);
            t.c.text[node] = ui.tables.tx.push(node, ui.tables.strings.add(@field(ui.signals.state, field)), &value.text);
            t.seal(node);
        }
        pub fn push(ui: anytype, comptime n: specs.Spec, parent: u32, next: *u32, in: *const Input) void {
            const t = &ui.tables.t;
            const bundle = prepare(ui, in) catch |err| {
                ui.fail(err);
                const count = comptime @import("../comptime/flatten.zig").count(n);
                const root = t.push(parent, .none, &.{ .participation = .collapsed });
                for (1..count) |_| {
                    const node = t.push(root, .none, &.{});
                    t.seal(node);
                }
                t.seal(root);
                next.* += count;
                return;
            };
            const root = t.push(parent, .none, &bundle.value.root.box);
            t.c.role[root] = @backingInt(a11y.Role.navigation);
            next.* += 1;
            inline for (links, 0..) |link, k| {
                const item_paint = bundle.items[k];
                const node = t.push(root, .from(@tagName(link[0])), &item_paint.body.box);
                t.c.role[node] = @backingInt(a11y.Role.link);
                pushText(ui, node, @tagName(link[1]), item_paint.label);
                _ = @import("../draw/outline.zig").append(t, node, @fromBackingInt(node), controls.outlineOptions(item_paint.focus, config.focus_offset));
                t.seal(node);
                const separator = t.push(root, .none, &bundle.separator.box);
                t.seal(separator);
                ui.setCursor(t.cursor(node) orelse .pointer, item_paint.states.hovered);
                next.* += 4;
            }
            pushText(ui, root, @tagName(current), bundle.current);
            next.* += 1;
            t.seal(root);
        }
    };
}

const test_context = @import("../runtime/context.zig");
const test_limits: test_context.Limits = .{ .nodes = 96, .texts = 24, .customs = 1, .strings = 2048, .depth = 16, .anims = 1, .tweens = 1, .flips = 1, .signals = 1, .timers = 1 };
const test_bytes = blk: {
    @setEvalBranchQuota(100_000);
    break :blk test_context.Context.requiredBytes(test_limits);
};
const test_menu: MenuDef = .{ .items = &.{ "first", "more", "last" }, .sub_at = 1, .sub = &.{ "subone", "subtwo" } };
const test_titles = [_][]const u8{ "First", "More", "Last", "One", "Two" };

test "recipe menu: disabled items are skipped and read-only items cannot activate" {
    const entries = [_]style.States{ .{ .disabled = true }, .{}, .{ .read_only = true }, .{ .disabled = true }, .{} };
    const options: MenuOptions = .{ .item_states = &entries };
    var state = try menuState(test_menu, .{}, .{ .toggle = true }, &.{}, options);
    try std.testing.expectEqual(@as(u8, 1), state.active);
    state = try menuState(test_menu, state, .{}, &.{.{ .kind = .press, .code = popup_z.keys.right }}, options);
    try std.testing.expect(state.sub);
    try std.testing.expectEqual(@as(u8, 1), state.sub_active);
    state = try menuState(test_menu, state, .{}, &.{.{ .kind = .press, .code = popup_z.keys.enter }}, options);
    try std.testing.expectEqual(@as(u8, 5), state.chosen);
    state = try menuState(test_menu, .{ .open = true, .active = 2 }, .{ .clicked = 2 }, &.{.{ .kind = .press, .code = popup_z.keys.enter }}, options);
    try std.testing.expect(state.open);
    try std.testing.expectEqual(@as(u8, 0), state.chosen);
    try std.testing.expectError(error.InvalidValue, menuState(test_menu, state, .{}, &.{}, .{ .item_states = entries[0..2] }));
}

test "recipe menu: runtime and CT consume dynamic typography tokens and the same submenu keys" {
    const State = struct {
        menu: MenuState = .{ .open = true },
        caption: []const u8 = "Commands",
        first: []const u8 = "First",
        more: []const u8 = "More",
        last: []const u8 = "Last",
        subone: []const u8 = "One",
        subtwo: []const u8 = "Two",
        tokens: style.tokens.Table = .{},
        environment: model.Environment = .{ .always_show_focus = true },
        style_error: ?style.Error = null,
    };
    const config: ct_controls.Config = .{ .tokens_field = "tokens", .environment_field = "environment" };
    const H = ct.Menu(.default, .commands, .menu, test_menu, .{ .style = config, .trigger = config });
    const spec = specs.col(.{}, .{ H.button(.caption), H.layer() });
    const Ui = ct.ComptimePage(State, spec, .default, H);
    var ui: Ui = .{};
    var token_rows = model.tokenRows(.{}, .{});
    token_rows[0] = style.tokens.literal(.text_color, model.Names.text, .rgb(30, 180, 80));
    token_rows[21] = style.tokens.literal(.text_size, model.Names.text_size[2], 22);
    const scopes = [_]style.tokens.Scope{.{ .entries = &token_rows }};
    const tokens: style.tokens.Table = .{ .scopes = &scopes };
    ui.signals.state.tokens = tokens;
    var raw: [test_bytes]u8 align(64) = undefined;
    var ctx = try test_context.Context.init(&raw, test_limits);
    var input: Input = .{ .viewport = .{ 600, 400 }, .pointer = .{ -10, -10 } };
    var state: MenuState = .{ .open = true };
    const options: Options = .{ .tokens = tokens, .environment = .{ .always_show_focus = true } };
    var frame = ctx.begin(&input);
    var response = try menuTrigger(&frame, .from("commands"), "Commands", options);
    _ = try menu(&frame, "commands", test_menu, &state, &test_titles, response, .{ .style = options });
    var out = frame.end(.{});
    _ = ui.frame(&input);
    try std.testing.expect(out.status.ok());
    try std.testing.expectEqual(@as(?style.Error, null), ui.signals.state.style_error);
    try std.testing.expectEqual(@as(u32, 4), out.texts.len);
    try std.testing.expectEqual(out.texts.len, ui.tables.tx.len);
    try std.testing.expectEqualSlices(f32, out.texts.c.px[0..out.texts.len], ui.tables.tx.c.px[0..ui.tables.tx.len]);
    try std.testing.expectEqualSlices(u32, out.texts.c.color[0..out.texts.len], ui.tables.tx.c.color[0..ui.tables.tx.len]);
    try std.testing.expectEqual(@as(f32, 22), ui.tables.tx.c.px[1]);
    const item = ui.tables.t.find(.from("commands_first"));
    try std.testing.expectEqual(@backingInt(a11y.Role.menu_item), ui.tables.t.c.role[item]);
    const ring = item + 2;
    try std.testing.expectEqual(item, ui.tables.t.x.row[ui.tables.t.c.extra[ring]].paint_reference);
    try std.testing.expectEqual(@as(f32, 2), ui.tables.t.border(ring));
    input.events = &.{
        .{ .kind = .press, .code = popup_z.keys.down },
        .{ .kind = .press, .code = popup_z.keys.right },
        .{ .kind = .press, .code = popup_z.keys.down },
        .{ .kind = .press, .code = popup_z.keys.enter },
    };
    frame = ctx.begin(&input);
    response = try menuTrigger(&frame, .from("commands"), "Commands", options);
    const chosen = try menu(&frame, "commands", test_menu, &state, &test_titles, response, .{ .style = options });
    _ = frame.end(.{});
    _ = ui.frame(&input);
    try std.testing.expectEqual(@as(u8, 5), chosen);
    try std.testing.expectEqual(state, ui.signals.state.menu);
    token_rows[21] = style.tokens.literal(.text_size, model.Names.text_size[2], 26);
    input.events = &.{};
    state = .{ .open = true };
    ui.signals.state.menu = state;
    frame = ctx.begin(&input);
    response = try menuTrigger(&frame, .from("commands"), "Commands", options);
    _ = try menu(&frame, "commands", test_menu, &state, &test_titles, response, .{ .style = options });
    out = frame.end(.{});
    _ = ui.frame(&input);
    try std.testing.expectEqual(@as(f32, 26), out.texts.c.px[1]);
    try std.testing.expectEqual(out.texts.c.px[1], ui.tables.tx.c.px[1]);
}

test "overlay recipes: runtime popup content tooltip focus toast deadline and breadcrumb roles are consumed" {
    var raw: [test_bytes]u8 align(64) = undefined;
    var ctx = try test_context.Context.init(&raw, test_limits);
    var input: Input = .{ .viewport = .{ 600, 400 }, .pointer = .{ -10, -10 }, .dt = 0.1 };
    var tip: Tip = .{};
    var popup_open = true;
    var toast_state: ToastState = .{ .shown = true, .left = 0.2 };
    var frame = ctx.begin(&input);
    _ = try popoverTrigger(&frame, .from("details"), &popup_open, "Details", .{});
    const follow = try breadcrumb(&frame, &.{ .from("home"), .from("docs") }, &.{ "Home", "Docs", "Here" }, .{});
    try std.testing.expectEqual(types.none, follow);
    const before = ctx.depth;
    if (try popover(&frame, "details", &popup_open, .{ .local = &.{style.set(.text_size, 23)} })) |panel| {
        _ = try popoverText(&frame, &panel, Parts.label, "Styled content");
        _ = frame.leaf(.from("custom"), .{ .size = .{ .px(6), .px(6) }, .fill = .rgb(230, 20, 70) });
        endPopover(&frame);
    }
    try std.testing.expectEqual(before, ctx.depth);
    const tip_node = (try tooltip(&frame, .from("details"), &tip, .{ .focused = true }, "Keyboard help", .{})).?;
    const alert = (try toast(&frame, .from("notice"), &toast_state, false, "Saved", .{ .environment = .{ .reduced_motion = true } })).?;
    const out = frame.end(.{});
    try std.testing.expect(out.status.ok());
    try std.testing.expect(tip.shown);
    try std.testing.expect(ctx.motion > 0);
    try std.testing.expectEqual(@backingInt(a11y.Role.tooltip), out.tree.c.role[tip_node.ix()]);
    try std.testing.expectEqual(@backingInt(a11y.Role.alert), out.tree.c.role[alert.ix()]);
    try std.testing.expectEqual(@as(f32, 1), out.tree.x.row[out.tree.c.extra[alert.ix()]].opacity);
    const home = out.tree.find(.from("home"));
    try std.testing.expectEqual(@backingInt(a11y.Role.link), out.tree.c.role[home]);
    try std.testing.expectEqual(@backingInt(a11y.Role.navigation), out.tree.c.role[out.tree.c.parent[home]]);
    try std.testing.expectEqual(types.Color.rgb(230, 20, 70).bitsOf(), out.tree.c.look[out.tree.find(.from("custom"))].fill);
    input.events = &.{.{ .kind = .press, .code = popup_z.keys.escape }};
    frame = ctx.begin(&input);
    try std.testing.expect((try popover(&frame, "details", &popup_open, .{})) == null);
    try std.testing.expect((try tooltip(&frame, .from("details"), &tip, .{ .focused = true }, "Keyboard help", .{})) == null);
    _ = frame.end(.{});
    try std.testing.expect(!popup_open and tip.dismissed);
}

test "recipe popover: CT typography is opt-in per label and Escape closes the native overlay" {
    const State = struct { open: bool = true, caption: []const u8 = "Details", styled: []const u8 = "Styled", plain: []const u8 = "Plain", style_error: ?style.Error = null };
    const H = ct.Popover(.default, .details, .open, .{ .style = .{ .local = &.{ style.set(.text_size, 25), style.set(.text_color, .rgb(180, 40, 60)) } } });
    const spec = specs.col(.{}, .{ H.button(.caption), H.layer(.{ H.label(.styled), specs.label(.plain), specs.Spec{ .kind = .col, .id = "custom_content", .style = .{ .size = .{ .px(6), .px(6) }, .fill = .rgb(1, 2, 3) } } }) });
    const Ui = ct.ComptimePage(State, spec, .default, H);
    var ui: Ui = .{};
    var input: Input = .{ .viewport = .{ 400, 240 }, .pointer = .{ -1, -1 } };
    var out = ui.frame(&input);
    try std.testing.expectEqual(@as(?style.Error, null), ui.signals.state.style_error);
    try std.testing.expectEqual(@as(f32, 25), ui.tables.tx.c.px[1]);
    try std.testing.expectEqual(types.Color.rgb(180, 40, 60).bitsOf(), ui.tables.tx.c.color[1]);
    try std.testing.expectEqual(base.Theme.default.text_px, ui.tables.tx.c.px[2]);
    try std.testing.expectEqual(base.Theme.default.text.bitsOf(), ui.tables.tx.c.color[2]);
    try std.testing.expectEqual(types.Color.rgb(1, 2, 3).bitsOf(), out.tree.c.look[out.tree.len - 1].fill);
    input.events = &.{.{ .kind = .press, .code = popup_z.keys.escape }};
    out = ui.frame(&input);
    try std.testing.expect(!ui.signals.state.open);
    try std.testing.expectEqual(types.none, out.tree.find(.from("details_panel")));
}

test "recipe overlays: CT tooltip focus and reduced-motion toast use the styled label consumer" {
    const TipState = struct { tip: Tip = .{}, caption: []const u8 = "Help", help: []const u8 = "Explanation", style_error: ?style.Error = null };
    const TipHook = ct.Tooltip(.default, .help_button, .tip, .{ .style = .{ .local = &.{style.set(.text_size, 19)} }, .trigger = .{ .states = .{ .focused = true } } });
    const TipUi = ct.ComptimePage(TipState, specs.col(.{}, .{ TipHook.button(.caption), TipHook.bubble(.help) }), .default, TipHook);
    var tip_ui: TipUi = .{};
    const input: Input = .{ .viewport = .{ 400, 240 }, .pointer = .{ -1, -1 }, .dt = 0.05 };
    const tip_out = tip_ui.frame(&input);
    try std.testing.expect(tip_ui.signals.state.tip.shown);
    try std.testing.expectEqual(@as(f32, 19), tip_ui.tables.tx.c.px[1]);
    try std.testing.expectEqual(@backingInt(a11y.Role.tooltip), tip_out.tree.c.role[tip_out.tree.len - 2]);
    const ToastApp = struct { toast: ToastState = .{ .shown = true, .left = 0.2 }, caption: []const u8 = "Save", message: []const u8 = "Saved", style_error: ?style.Error = null };
    const ToastHook = ct.Toast(.default, .notice, .toast, .save, .{ .style = .{ .environment = .{ .reduced_motion = true }, .local = &.{style.set(.text_size, 21)} } });
    const ToastUi = ct.ComptimePage(ToastApp, specs.col(.{}, .{ ToastHook.button(.caption), ToastHook.layer(.message) }), .default, ToastHook);
    var toast_ui: ToastUi = .{};
    const toast_out = toast_ui.frame(&input);
    const row = toast_out.tree.find(.from("notice"));
    try std.testing.expectEqual(@backingInt(a11y.Role.alert), toast_out.tree.c.role[row]);
    try std.testing.expectEqual(@as(f32, 21), toast_ui.tables.tx.c.px[1]);
    try std.testing.expectEqual(@as(f32, 1), toast_out.tree.x.row[toast_out.tree.c.extra[row]].opacity);
}

test "recipe breadcrumb: CT links follow Enter keep focus outlines and reject disabled activation" {
    const State = struct { activated: u32 = types.none, home_text: []const u8 = "Home", docs_text: []const u8 = "Docs", current: []const u8 = "Here", states: style.States = .{} };
    const spec = ct.breadcrumb(.activated, .{ .{ .home, .home_text }, .{ .docs, .docs_text } }, .current, .{ .states_field = "states", .local = &.{style.set(.text_size, 20)} });
    const Ui = base.ComptimeUi(State, spec, .default);
    var ui: Ui = .{};
    var input: Input = .{ .viewport = .{ 400, 240 }, .pointer = .{ -1, -1 } };
    _ = ui.frame(&input);
    ui.focus = .docs;
    input.events = &.{.{ .kind = .press, .code = popup_z.keys.enter }};
    var out = ui.frame(&input);
    try std.testing.expectEqual(@as(?anyerror, null), out.failure);
    try std.testing.expectEqual(@as(u32, 1), ui.signals.state.activated);
    const row = out.tree.find(.from("docs"));
    try std.testing.expectEqual(@as(f32, 20), ui.tables.tx.c.px[1]);
    try std.testing.expectEqual(@as(f32, 2), out.tree.border(row + 2));
    input.events = &.{.{ .kind = .press, .code = popup_z.keys.space }};
    _ = ui.frame(&input);
    try std.testing.expectEqual(types.none, ui.signals.state.activated);
    ui.signals.state.states.disabled = true;
    input.events = &.{.{ .kind = .press, .code = popup_z.keys.enter }};
    out = ui.frame(&input);
    try std.testing.expectEqual(@as(?anyerror, null), out.failure);
    try std.testing.expectEqual(types.none, ui.signals.state.activated);
    try std.testing.expectEqual(@as(?Ui.Events.Widget, null), ui.focus);
}

test "recipe overlays: resolution failure is explicit preserves menu state and resets next frame only" {
    const broken: model.Recipe = comptime .{ .parts = recipes.popover.parts, .rules = &.{.{ .part = Parts.root, .declarations = &.{style.token(.fill, .from("missing.overlay.token"))} }} };
    const State = struct { open: bool = false, caption: []const u8 = "Details", body: []const u8 = "Body", recipe: model.Recipe = broken, style_error: ?style.Error = null };
    const H = ct.Popover(.default, .details, .open, .{ .style = .{ .recipe_field = "recipe" }, .trigger = .{ .states = .{ .focused = true } } });
    const Ui = ct.ComptimePage(State, specs.col(.{}, .{ H.button(.caption), H.layer(.{H.label(.body)}) }), .default, H);
    var ui: Ui = .{};
    var input: Input = .{ .viewport = .{ 400, 240 }, .pointer = .{ -1, -1 }, .events = &.{.{ .kind = .press, .code = popup_z.keys.enter }} };
    _ = ui.frame(&input);
    try std.testing.expectEqual(@as(?style.Error, error.MissingToken), ui.signals.state.style_error);
    try std.testing.expect(!ui.signals.state.open);
    ui.signals.state.recipe = recipes.popover;
    _ = ui.frame(&input);
    try std.testing.expectEqual(@as(?style.Error, null), ui.signals.state.style_error);
    try std.testing.expect(ui.signals.state.open);
    var raw: [test_bytes]u8 align(64) = undefined;
    var ctx = try test_context.Context.init(&raw, test_limits);
    input.events = &.{};
    var frame = ctx.begin(&input);
    const depth = ctx.depth;
    var state: MenuState = .{ .open = true };
    var bad_menu = recipes.menu;
    bad_menu.rules = broken.rules;
    try std.testing.expectError(error.MissingToken, menu(&frame, "commands", test_menu, &state, &test_titles, .{}, .{ .style = .{ .recipe = bad_menu } }));
    try std.testing.expectEqual(depth, ctx.depth);
    try std.testing.expect(state.open);
    _ = frame.end(.{});
}

test "recipe menu accessories: runtime and CT style accelerators indicators separators and skip separator actions" {
    const def: MenuDef = .{ .items = &.{ "first", "divider", "more", "last" }, .sub_at = 2, .sub = &.{ "subone", "subtwo" } };
    const custom: model.Recipe = comptime .{ .parts = recipes.menu.parts, .rules = &(popup_rules ++ [_]style.Rule{
        .{ .part = names.accelerator, .declarations = &.{ style.set(.text_color, .rgb(210, 60, 30)), style.set(.text_size, 11) } },
        .{ .part = Parts.indicator, .declarations = &.{ style.set(.text_color, .rgb(20, 100, 220)), style.set(.text_size, 18) } },
        .{ .part = Parts.separator, .declarations = &.{ style.set(.fill, .rgb(180, 20, 150)), style.set(.height, .px(3)) } },
    }) };
    const State = struct {
        menu: MenuState = .{ .open = true },
        caption: []const u8 = "Commands",
        first: []const u8 = "Save",
        divider: []const u8 = "Not emitted",
        more: []const u8 = "More",
        last: []const u8 = "Close",
        subone: []const u8 = "One",
        subtwo: []const u8 = "Two",
        content: []const MenuContent = &.{},
        style_error: ?style.Error = null,
    };
    const H = ct.Menu(.default, .commands, .menu, def, .{ .style = .{ .recipe = custom }, .menu_content_field = "content" });
    const Ui = ct.ComptimePage(State, specs.col(.{}, .{ H.button(.caption), H.layer() }), .default, H);
    var ui: Ui = .{};
    var content = [_]MenuContent{ .{ .accelerator = "Ctrl+S" }, .{ .separator = true }, .{ .indicator = ">" }, .{ .accelerator = "F4" }, .{}, .{} };
    ui.signals.state.content = &content;
    const options: MenuOptions = .{ .style = .{ .recipe = custom }, .content = &content };
    var raw: [test_bytes]u8 align(64) = undefined;
    var ctx = try test_context.Context.init(&raw, test_limits);
    var input: Input = .{ .viewport = .{ 600, 400 }, .pointer = .{ -10, -10 } };
    var state: MenuState = .{ .open = true };
    var frame = ctx.begin(&input);
    const trigger_response = try menuTrigger(&frame, .from("commands"), "Commands", .{});
    _ = try menu(&frame, "commands", def, &state, &.{ "Save", "Not emitted", "More", "Close", "One", "Two" }, trigger_response, options);
    const out = frame.end(.{});
    const ct_out = ui.frame(&input);
    try std.testing.expect(out.status.ok());
    try std.testing.expectEqual(@as(?style.Error, null), ui.signals.state.style_error);
    try std.testing.expectEqual(@as(u32, 7), out.texts.len);
    try std.testing.expectEqual(out.texts.len, ui.tables.tx.len);
    try std.testing.expectEqualSlices(u32, out.texts.c.color[0..out.texts.len], ui.tables.tx.c.color[0..ui.tables.tx.len]);
    try std.testing.expectEqualSlices(f32, out.texts.c.px[0..out.texts.len], ui.tables.tx.c.px[0..ui.tables.tx.len]);
    try std.testing.expectEqualStrings("Ctrl+S", ui.tables.strings.get(.{ .start = ui.tables.tx.c.start[2], .bytes = ui.tables.tx.c.bytes[2] }));
    try std.testing.expectEqualStrings(">", ui.tables.strings.get(.{ .start = ui.tables.tx.c.start[4], .bytes = ui.tables.tx.c.bytes[4] }));
    try std.testing.expectEqual(types.Color.rgb(210, 60, 30).bitsOf(), out.texts.c.color[2]);
    try std.testing.expectEqual(types.Color.rgb(20, 100, 220).bitsOf(), out.texts.c.color[4]);
    const divider = out.tree.find(.from("commands_divider"));
    try std.testing.expectEqual(@backingInt(a11y.Role.separator), out.tree.c.role[divider]);
    try std.testing.expectEqual(@as(u8, 0), out.tree.c.sense[divider]);
    try std.testing.expectEqual(@as(f32, 3), out.tree.rect(divider).h());
    try std.testing.expectEqual(types.Color.rgb(180, 20, 150).bitsOf(), out.tree.c.look[divider].fill);
    const ct_divider = ct_out.tree.find(.from("commands_divider"));
    try std.testing.expectEqual(out.tree.rect(divider).h(), ct_out.tree.rect(ct_divider).h());
    const accelerator_end = out.tree.rect(out.texts.c.node[2]).x1;
    try std.testing.expectApproxEqAbs(accelerator_end, out.tree.rect(out.texts.c.node[6]).x1, 0.001);
    // Text-node border boxes may touch: the accelerator owns its 16px leading padding.
    // The renderer consumes inset TextRun.rect, so verify the actual text content gap.
    try std.testing.expectApproxEqAbs(@as(f32, 16), out.draw.runs[2].rect[0] - out.draw.runs[1].rect[2], 0.001);
    try std.testing.expectEqual(out.draw.runs[2].rect, ct_out.draw.runs[2].rect);
    input.events = &.{.{ .kind = .press, .code = popup_z.keys.down }};
    state = try menuState(def, state, .{}, input.events, options);
    _ = ui.frame(&input);
    try std.testing.expectEqual(@as(u8, 2), state.active);
    try std.testing.expectEqual(state.active, ui.signals.state.menu.active);
    state = try menuState(def, state, .{ .clicked = 1 }, &.{}, options);
    try std.testing.expect(state.open and state.chosen == 0);
    content[0].accelerator = "Shift+S";
    input.events = &.{};
    _ = ui.frame(&input);
    try std.testing.expectEqualStrings("Shift+S", ui.tables.strings.get(.{ .start = ui.tables.tx.c.start[2], .bytes = ui.tables.tx.c.bytes[2] }));
    const oversized: [1100]u8 = @splat('X');
    content[0].accelerator = &oversized;
    _ = ui.frame(&input);
    try std.testing.expectEqual(@as(?style.Error, error.NoSpace), ui.signals.state.style_error);
    try std.testing.expect(!ui.tables.strings.overflow);
}

test "recipe tooltip arrow: optional part styles real geometry in runtime and CT without input or extra layout" {
    const custom: model.Recipe = comptime .{ .parts = recipes.tooltip.parts, .rules = &(popup_rules ++ [_]style.Rule{
        .{ .part = names.arrow, .declarations = &.{ style.set(.fill, .rgb(210, 30, 70)), style.set(.width, .px(12)), style.set(.height, .px(10)), style.set(.offset, .{ 16, -5 }) } },
    }) };
    const State = struct { tip: Tip = .{}, caption: []const u8 = "Help", help: []const u8 = "Explanation", style_error: ?style.Error = null };
    const H = ct.Tooltip(.default, .help_button, .tip, .{ .style = .{ .recipe = custom }, .trigger = .{ .states = .{ .focused = true } }, .tooltip_arrow = true });
    const Ui = ct.ComptimePage(State, specs.col(.{}, .{ H.button(.caption), H.bubble(.help) }), .default, H);
    var ui: Ui = .{};
    const input: Input = .{ .viewport = .{ 400, 240 }, .pointer = .{ -1, -1 } };
    const ct_out = ui.frame(&input);
    var raw: [test_bytes]u8 align(64) = undefined;
    var ctx = try test_context.Context.init(&raw, test_limits);
    var frame = ctx.begin(&input);
    _ = try controls.button(&frame, .from("help_button"), "Help", .{});
    var tip: Tip = .{};
    const bubble = (try tooltipDecorated(&frame, .from("help_button"), &tip, .{ .focused = true }, "Explanation", .{ .style = .{ .recipe = custom }, .arrow = true })).?;
    const out = frame.end(.{});
    const arrow = bubble.ix() + 1;
    const ct_arrow = ct_out.tree.len - 2;
    try std.testing.expectEqual(@as(?style.Error, null), ui.signals.state.style_error);
    try std.testing.expectEqual(types.Color.rgb(210, 30, 70).bitsOf(), out.tree.c.look[arrow].fill);
    try std.testing.expectEqual(out.tree.c.look[arrow].fill, ct_out.tree.c.look[ct_arrow].fill);
    try std.testing.expectEqual(@as(f32, 12), out.tree.rect(arrow).w());
    try std.testing.expectEqual(@as(f32, 10), out.tree.rect(arrow).h());
    try std.testing.expectEqual(out.tree.rect(arrow).array(), ct_out.tree.rect(ct_arrow).array());
    try std.testing.expectApproxEqAbs(out.tree.rect(bubble.ix()).y0 - 5, out.tree.rect(arrow).y0, 0.001);
    try std.testing.expectEqual(@as(f32, 0), out.tree.c.flow[arrow]);
    try std.testing.expectEqual(@as(u8, 0), out.tree.c.sense[arrow]);
    try std.testing.expect(!out.tree.participation(arrow).semantics);
}

test "recipe overlay participation: hidden popup removes its scrim and read-only focused controls retain help" {
    var raw: [test_bytes]u8 align(64) = undefined;
    var ctx = try test_context.Context.init(&raw, test_limits);
    const input: Input = .{ .viewport = .{ 400, 240 }, .pointer = .{ -1, -1 } };
    var frame = ctx.begin(&input);
    var open = true;
    const hidden: Options = .{ .local = &.{style.set(.participation, .collapsed)} };
    try std.testing.expect((try popover(&frame, "details", &open, hidden)) == null);
    const out = frame.end(.{});
    try std.testing.expect(!open);
    try std.testing.expectEqual(types.none, out.tree.find(.from("details_scrim")));
    const State = struct { tip: Tip = .{}, caption: []const u8 = "Read only", help: []const u8 = "Still available", style_error: ?style.Error = null };
    const H = ct.Tooltip(.default, .help_button, .tip, .{ .trigger = .{ .states = .{ .focused = true, .read_only = true } } });
    const Ui = ct.ComptimePage(State, specs.col(.{}, .{ H.button(.caption), H.bubble(.help) }), .default, H);
    var ui: Ui = .{};
    _ = ui.frame(&input);
    try std.testing.expectEqual(@as(?style.Error, null), ui.signals.state.style_error);
    try std.testing.expect(ui.signals.state.tip.shown);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
