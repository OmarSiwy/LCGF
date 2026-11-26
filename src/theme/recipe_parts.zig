//! Composable navigation, data-view and editor parts. Plain recipes stay independently
//! resolvable; these helpers feed Frame/Tree/Texts and reuse existing control behavior.
//! Passive data parts do not take over sorting/selection state or impose a retained model.

const std = @import("std");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const style = @import("../style/style.zig");
const model = @import("recipe.zig");
const controls = @import("recipe_controls.zig");
const a11y = @import("../a11y/tree.zig");
const tabs = @import("../widgets/tabs.zig");
const textarea_zig = @import("../widgets/textarea.zig");
const textfield = @import("../widgets/textfield.zig");
const Parts = style.Parts;

pub const PartOptions = struct {
    recipe: model.Recipe = model.data,
    use: model.Use = .{},
    role: ?a11y.Role = null,
    semantics: ?*a11y.Semantics = null,
};
pub const OpenPart = struct {
    node: types.Node,
    computed: style.Computed,
    options: PartOptions,

    pub fn resolve(part: *const OpenPart, id: types.Id, states: style.States) style.Error!style.Computed {
        var use = part.options.use;
        use.parent = &part.computed;
        use.local = &.{};
        use.states = states;
        return part.options.recipe.resolve(id, use, null);
    }
};

/// Opens a passive named part. Call Frame.close after its children. The same recipe/use data
/// can instead be passed directly to Recipe.resolve and Tree.push by a custom front end.
pub fn open(f: *Frame, id: types.Id, part: types.Id, options: PartOptions) style.Error!OpenPart {
    if (options.semantics) |s| if (f.tree().len >= s.cap) return error.NoSpace;
    const computed = try options.recipe.resolve(part, options.use, null);
    const node = f.open(id, computed.box);
    if (options.role) |role| f.tree().c.role[node.ix()] = @backingInt(role);
    controls.expose(options.semantics, node, options.use.states);
    return .{ .node = node, .computed = computed, .options = options };
}

pub fn child(f: *Frame, parent: *const OpenPart, part: types.Id, states: style.States, role: ?a11y.Role) style.Error!OpenPart {
    var options = parent.options;
    options.use.parent = &parent.computed;
    options.use.local = &.{};
    options.use.states = states;
    options.role = role;
    return open(f, .none, part, options);
}

pub fn text(f: *Frame, parent: *const OpenPart, part: types.Id, str: []const u8) style.Error!types.Node {
    const computed = try parent.resolve(part, parent.options.use.states);
    return f.textStyled(str, computed.text, computed.box);
}

pub fn leaf(f: *Frame, parent: *const OpenPart, part: types.Id) style.Error!types.Node {
    const computed = try parent.resolve(part, parent.options.use.states);
    return f.leaf(.none, computed.box);
}

pub fn dataRow(f: *Frame, parent: *const OpenPart, states: style.States) style.Error!OpenPart {
    return child(f, parent, Parts.row, states, .row);
}

pub fn dataCell(f: *Frame, row: *const OpenPart, str: []const u8, states: style.States, header: bool) style.Error!types.Node {
    const cell = try child(f, row, if (header) Parts.header else Parts.cell, states, if (header) .column_header else .cell);
    defer f.close();
    _ = try text(f, &cell, Parts.label, str);
    return cell.node;
}

pub const Icon = struct { texture: types.Texture, uv: [4]f32 = .{ 0, 0, 1, 1 } };
pub const Item = struct { id: types.Id, text: []const u8, icon: ?Icon = null, states: style.States = .{} };

/// A menu/link/tab/tree-item action whose input behavior is the existing button activation.
/// The caller supplies semantic role and authoritative selection/expanded/current state.
/// Application commands remain returned data; no callback or destination is registered.
pub fn navigationItem(f: *Frame, item: Item, role: a11y.Role, options: controls.Options) style.Error!types.Response {
    var opts = options;
    opts.recipe = options.recipe orelse model.navigation;
    opts.states = opts.states.merge(item.states);
    const control = try controls.beginButton(f, item.id, opts);
    defer controls.end(f, &control);
    f.tree().c.role[control.node.ix()] = @backingInt(role);
    if (item.icon) |image| _ = try controls.icon(f, &control, image.texture, image.uv);
    _ = controls.label(f, &control, item.text);
    const indicator = try control.part(Parts.indicator, null);
    _ = f.leaf(.none, indicator.box);
    return control.response;
}

fn enabled(item: Item, options: controls.Options) bool {
    return !item.states.disabled and !options.states.disabled;
}
fn indexAt(items: []const Item, ordinal: u32, options: controls.Options) u32 {
    var at: u32 = 0;
    for (items, 0..) |item, i| if (enabled(item, options)) {
        if (at == ordinal) return @intCast(i);
        at += 1;
    };
    return types.none;
}

/// A complete keyboard/pointer tab bar using tabs.select. Disabled items are excluded from
/// its ordinal mapping; no temporary list or allocator is required. Panels can be arbitrary
/// caller-built content (tabPanel below is one convenience). An empty bar selects none.
pub fn tabBar(f: *Frame, items: []const Item, selected: *u32, options: controls.Options) style.Error!types.Node {
    var count: u32 = 0;
    var clicked: u32 = types.none;
    var focused: u32 = types.none;
    var current: u32 = 0;
    for (items, 0..) |item, i| {
        var opts = options;
        opts.states = opts.states.merge(item.states);
        const response = try controls.policyResponse(f, item.id, opts.recipe orelse model.navigation, opts, opts.states);
        if (!enabled(item, options)) continue;
        if (i == selected.*) current = count;
        if (response.clicked) clicked = count;
        if (response.focused) focused = count;
        count += 1;
    }
    const move: tabs.Move = if (count == 0) .{ .selected = types.none, .focus = types.none } else tabs.select(current, count, clicked, focused, f.in);
    const next = if (options.states.read_only) selected.* else indexAt(items, move.selected, options);
    const previous_focus = f.ctx.inter.focus;
    errdefer f.ctx.inter.focus = previous_focus;
    if (move.focus != types.none) f.ctx.inter.focus = @backingInt(items[indexAt(items, move.focus, options)].id);
    const node = f.open(.none, .{ .dir = .x, .size = .{ .fill, .fit } });
    defer f.close();
    f.tree().c.role[node.ix()] = @backingInt(a11y.Role.tab_list);
    f.tree().c.value[node.ix()] = if (next == types.none) -1 else @floatFromInt(next);
    for (items, 0..) |source, i| {
        var item = source;
        item.states.selected = i == next;
        _ = try navigationItem(f, item, .tab, options);
    }
    selected.* = next;
    return node;
}

/// Opens a panel with explicit participation instead of inferring visibility from alpha or
/// a zero height. Build its children then close it. A hidden panel keeps its nodes stable.
pub fn tabPanel(f: *Frame, id: types.Id, selected: u32, index: u32, options: PartOptions) style.Error!OpenPart {
    var resolved = try options.recipe.resolve(Parts.root, options.use, null);
    if (selected != index) resolved.box.participation = .collapsed;
    if (options.semantics) |s| if (f.tree().len >= s.cap) return error.NoSpace;
    const node = f.open(id, resolved.box);
    f.tree().c.role[node.ix()] = @backingInt(a11y.Role.tab_panel);
    return .{ .node = node, .computed = resolved, .options = options };
}

/// A multiline field using the existing textarea.behave/read-only editor policy. Each hard
/// line, selection band, caret, placeholder and outside focus uses an independent recipe part.
/// Supplied shaped views retain the existing textarea's bidi selection and caret behavior.
pub fn textarea(f: *Frame, id: types.Id, field: anytype, rows: u32, hint: []const u8, options: controls.Options) style.Error!types.Response {
    if (rows == 0) return error.InvalidValue;
    const lines = std.math.mul(u32, rows, textfield.bands + 1 + controls.selection_sections * 2) catch return error.NoSpace;
    const needed = std.math.add(u32, lines, 3) catch return error.NoSpace;
    if (needed > f.tree().cap -| f.tree().len or rows > f.texts().cap -| f.texts().len) return error.NoSpace;
    if (options.semantics) |s| if (f.tree().len >= s.cap) return error.NoSpace;
    const recipe = options.recipe orelse model.editor;
    const response = try controls.policyResponse(f, id, recipe, options, options.states);
    var states = options.validation.states(controls.statesFor(options.states, response, controls.visibleFocus(f, options)), field.text());
    var r = try resolveArea(f, recipe, options, states);
    const editor = field.editor();
    const previous_read_only = editor.mode.read_only;
    editor.mode.read_only = previous_read_only or states.read_only or states.disabled;
    defer editor.mode.read_only = previous_read_only;
    var last = f.lastRect(id);
    last.y0 += r.root.box.pad[1] - textfield.padding(&r.metrics)[1];
    const was_invalid = options.validation.invalid(field.text());
    textarea_zig.behave(field, &r.metrics, id, response, last, rows, f.in);
    if (editor.mode.read_only) field.input.reset();
    // The comptime front end resolves after this frame's edit: validity follows the new text.
    if (options.validation.invalid(field.text()) != was_invalid) {
        states.invalid = options.states.invalid or options.validation.invalid(field.text());
        r = try resolveArea(f, recipe, options, states);
    }
    var root = r.root;
    const content = r.content;
    const placeholder = r.placeholder;
    const selection = r.selection;
    const caret = r.caret;
    const focus = r.focus;
    const metrics = r.metrics;
    textfield.platform(f, field);
    root.box.role = .text_input;
    root.box.scroll = .{ 0, 0 }; // textarea.behave already selects the visible line window.
    const node = f.open(id, root.box);
    defer f.close();
    _ = f.interact(node, if (states.disabled) .{} else types.Sense.any);
    f.setCursor(f.tree().cursor(node.ix()) orelse .text, response.hovered);
    const value = editor.text();
    const scroll: u32 = @intFromFloat(field.scroll);
    const selected = editor.selection();
    const advance = textfield.advance(&metrics);
    const height = textfield.lineHeight(&metrics);
    const fresh = textfield.fresh(field);
    for (0..rows) |i| {
        const line = textarea_zig.shownLine(value, scroll, @intCast(i), selected, advance);
        for (textarea_zig.lineBands(fresh, scroll + @as(u32, @intCast(i)), selected, line.sel)) |band| {
            var box = selection.box;
            box.float = true;
            box.offset = .{ band[0], @as(f32, @floatFromInt(i)) * height };
            box.size = .{ .px(band[1] - band[0]), .px(height) };
            _ = f.leaf(.none, box);
        }
    }
    for (0..rows) |i| {
        const line = textarea_zig.shownLine(value, scroll, @intCast(i), selected, advance);
        const show_hint = value.len == 0 and i == 0;
        var part = if (show_hint) placeholder else content;
        part.box.size[1] = .px(height);
        const bands = textarea_zig.lineBands(fresh, scroll + @as(u32, @intCast(i)), selected, line.sel);
        controls.selectedText(f, if (show_hint) hint else line.str, part, selection, bands, @as(f32, @floatFromInt(i)) * height, height);
    }
    const at = textarea_zig.caretAt(value, editor.shownCaret(), scroll, rows, &metrics, fresh);
    var caret_box = caret.box;
    caret_box.float = true;
    caret_box.offset = .{ at.x, at.y };
    caret_box.size[1] = .px(height);
    if (!at.shown) caret_box.fill = .transparent;
    _ = f.leaf(.none, caret_box);
    _ = f.outline(node, controls.outlineOptions(focus, options.focus_offset));
    controls.expose(options.semantics, node, states);
    if (options.semantics) |s| s.c.state[node.ix()] |= (a11y.State{ .multiline = true }).bitsOf();
    return response;
}

const Area = struct { root: style.Computed, content: style.Computed, placeholder: style.Computed, selection: style.Computed, caret: style.Computed, focus: style.Computed, metrics: @import("../widgets/base.zig").Theme };

fn resolveArea(f: *Frame, recipe: model.Recipe, options: controls.Options, states: style.States) style.Error!Area {
    const use = controls.useFor(f, options, states);
    var a: Area = undefined;
    a.root = try recipe.resolve(Parts.root, use, null);
    var inside = use;
    inside.parent = &a.root;
    inside.local = &.{};
    a.content = try recipe.resolve(Parts.content, inside, null);
    a.placeholder = try recipe.resolve(Parts.placeholder, inside, null);
    a.selection = try recipe.resolve(Parts.selection, inside, null);
    a.caret = try recipe.resolve(Parts.caret, inside, null);
    a.focus = try recipe.resolve(Parts.focus, inside, null);
    a.metrics = controls.fieldMetrics(a.root, a.content, false);
    return a;
}

/// Emits an editor's independently styled support/error text. Use outside the clipped field
/// so the caller chooses form layout; state, tokens and environment are still the same data.
pub fn support(f: *Frame, str: []const u8, options: controls.Options) style.Error!types.Node {
    const recipe = options.recipe orelse model.editor;
    const use = controls.useFor(f, options, options.states);
    const root = try recipe.resolve(Parts.root, use, null);
    var child_use = use;
    child_use.parent = &root;
    child_use.local = &.{};
    const computed = try recipe.resolve(Parts.support, child_use, null);
    return f.textStyled(str, computed.text, computed.box);
}

test "data and navigation parts feed actual semantic rows and tab selection behavior" {
    const context = @import("../runtime/context.zig");
    const caps: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 12, .anims = 1, .tweens = 1, .flips = 1, .signals = 1, .timers = 1 };
    const bytes = comptime blk: {
        @setEvalBranchQuota(40_000);
        break :blk context.Context.requiredBytes(caps);
    };
    var memory: [bytes]u8 align(64) = undefined;
    var ctx = try context.Context.init(&memory, caps);
    var input: @import("../core/input.zig").Input = .{ .viewport = .{ 320, 400 } };
    const items = [_]Item{ .{ .id = .from("first"), .text = "First" }, .{ .id = .from("disabled"), .text = "Disabled", .states = .{ .disabled = true } }, .{ .id = .from("last"), .text = "Last" } };
    var selected: u32 = 0;
    var frame = ctx.begin(&input);
    _ = try tabBar(&frame, &items, &selected, .{});
    const data = try open(&frame, .from("data"), Parts.root, .{ .role = .table });
    const row = try dataRow(&frame, &data, .{});
    const cell = try dataCell(&frame, &row, "Styled cell", .{ .selected = true }, false);
    frame.close();
    frame.close();
    var output = frame.end(.{});
    try std.testing.expectEqual(@backingInt(a11y.Role.cell), output.tree.c.role[cell.ix()]);
    try std.testing.expect(output.draw.quad_len > 0);
    ctx.inter.focus = @backingInt(items[0].id);
    input.events = &.{.{ .kind = .press, .code = @import("../widgets/keys.zig").map.right }};
    frame = ctx.begin(&input);
    _ = try tabBar(&frame, &items, &selected, .{});
    output = frame.end(.{});
    try std.testing.expectEqual(@as(u32, 2), selected);
    try std.testing.expectEqual(@backingInt(items[2].id), ctx.inter.focus);
    try std.testing.expect(output.status.ok());
}

test "multiline recipe routes typing, read-only policy and support part to real editor output" {
    const context = @import("../runtime/context.zig");
    const caps: context.Limits = .{ .nodes = 96, .texts = 32, .customs = 1, .strings = 2048, .depth = 12, .anims = 1, .tweens = 1, .flips = 1, .signals = 1, .timers = 1 };
    const bytes = comptime blk: {
        @setEvalBranchQuota(40_000);
        break :blk context.Context.requiredBytes(caps);
    };
    var memory: [bytes]u8 align(64) = undefined;
    var ctx = try context.Context.init(&memory, caps);
    var field = textarea_zig.Text(128).init("one\ntwo");
    var input: @import("../core/input.zig").Input = .{ .viewport = .{ 320, 200 } };
    var frame = ctx.begin(&input);
    _ = try textarea(&frame, .from("editor"), &field, 3, "Notes", .{});
    var output = frame.end(.{});
    ctx.inter.focus = @backingInt(types.Id.from("editor"));
    input.text = "!";
    input.events = &.{.{ .kind = .text, .at = 0, .len = 1 }};
    frame = ctx.begin(&input);
    _ = try textarea(&frame, .from("editor"), &field, 3, "Notes", .{});
    output = frame.end(.{});
    try std.testing.expectEqualStrings("one\ntwo!", field.text());
    frame = ctx.begin(&input);
    _ = try textarea(&frame, .from("editor"), &field, 3, "Notes", .{ .states = .{ .read_only = true } });
    _ = try support(&frame, "Cannot edit", .{ .states = .{ .invalid = true } });
    output = frame.end(.{});
    try std.testing.expectEqualStrings("one\ntwo!", field.text());
    try std.testing.expectEqual(@as(u32, 4), output.texts.len);
    try std.testing.expect(!output.platform.wants_text);
    try std.testing.expect(output.status.ok());
}
