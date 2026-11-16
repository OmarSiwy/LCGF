//! Tree view (tier 2): an outline of items, each at a depth, whose parents expand and collapse,
//! in both front ends. Follows the five-commit recipe of widgets/base.zig and is written against
//! the public API of tiers 0 and 1 only.
//!
//! State lives in the application: the items in depth-first order as two parallel slices (the
//! label strings and each item's depth, a parent's children follow it one level deeper) and a
//! `State(n)` value (the selected item and which items are expanded). Only the rows of items
//! whose ancestors are all expanded are built; rows have the list box's fixed height, so the
//! row under the pointer is index arithmetic over the visible items.

const std = @import("std");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Input = @import("../core/input.zig").Input;
const DrawList = @import("../draw/draw_list.zig").DrawList;
const Mono = @import("../text/protocol.zig").Mono;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const events = @import("../comptime/events.zig");
const signals = @import("../comptime/signals.zig");
const flatten = @import("../comptime/flatten.zig");
const a11y = @import("../a11y/tree.zig");
const base = @import("base.zig");
const list_zig = @import("list.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Color = types.Color;
const Style = types.Style;
const Response = types.Response;
const none = types.none;

// ---- spec ------------------------------------------------------------------------------------

/// What a tree view keeps between frames, owned by the application: the selected item (an
/// index into the items) and, per item, whether it is expanded (meaningful for parents).
pub fn State(comptime n: usize) type {
    return struct {
        selected: u32 = 0,
        expanded: [n]bool = @splat(false),
    };
}

/// Why `S` cannot back a comptime tree view bound to the state field `state`, with item labels
/// in `labels` and depths in `depths`, `n` items; null when it can.
pub fn check(comptime S: type, comptime state: []const u8, comptime labels: []const u8, comptime depths: []const u8, comptime n: u32) ?[]const u8 {
    comptime {
        if (n == 0) return "tree: a tree view has at least one item";
        if (!@hasField(S, state)) return "tree: state has no field '" ++ state ++ "' for the tree state";
        if (@FieldType(S, state) != State(n)) return std.fmt.comptimePrint("tree: field '{s}' must be a tree.State({d})", .{ state, n });
        if (!@hasField(S, labels)) return "tree: state has no field '" ++ labels ++ "' for the labels";
        if (@FieldType(S, labels) != []const []const u8) return "tree: labels field '" ++ labels ++ "' must be a []const []const u8";
        if (!@hasField(S, depths)) return "tree: state has no field '" ++ depths ++ "' for the depths";
        if (@FieldType(S, depths) != []const u8) return "tree: depths field '" ++ depths ++ "' must be a []const u8";
        return null;
    }
}

/// `check` as a compile error.
pub fn validate(comptime S: type, comptime state: []const u8, comptime labels: []const u8, comptime depths: []const u8, comptime n: u32) void {
    if (comptime check(S, state, labels, depths, n)) |msg| @compileError(msg);
}

/// Whether item `i` has children: the next item is deeper.
pub fn hasChildren(depths: []const u8, i: usize) bool {
    return i + 1 < depths.len and depths[i + 1] > depths[i];
}

/// Item `i`'s parent, or `none` at depth 0: the nearest earlier item one level up.
pub fn parentOf(depths: []const u8, i: u32) u32 {
    var j = i;
    while (j > 0) {
        j -= 1;
        if (depths[j] < depths[i]) return j;
    }
    return none;
}

/// The items whose ancestors are all expanded, in order, into `out`; returns how many. One pass:
/// below a collapsed item everything deeper is skipped.
pub fn visibleItems(depths: []const u8, expanded: []const bool, out: []u32) u32 {
    var len: u32 = 0;
    var hide_below: u16 = std.math.maxInt(u16);
    for (depths, expanded, 0..) |d, e, i| {
        if (d > hide_below) continue;
        hide_below = if (e) std.math.maxInt(u16) else d;
        out[len] = @intCast(i);
        len += 1;
    }
    return len;
}

/// Position of item `item` among the visible items, or `none` when it is hidden.
pub fn positionOf(visible: []const u32, item: u32) u32 {
    for (visible, 0..) |v, k| if (v == item) return @intCast(k);
    return none;
}

// ---- look: one function per part, called by both front ends -------------------------------

/// Indent per level of depth.
pub const indent_px: f32 = 16;
/// Size of the disclosure mark in front of a parent's label.
pub const mark_px: f32 = 8;

pub fn treeStyle(th: *const Theme) Style {
    var s = list_zig.listStyle(th);
    s.min = .{ 160, 0 };
    return s;
}

/// An item's row: the list box's option row, indented by its depth.
pub fn rowStyle(th: *const Theme, depth: u8) Style {
    var s = list_zig.optionStyle(th);
    s.pad[0] = th.pad + @as(f32, @floatFromInt(depth)) * indent_px;
    s.gap = th.gap;
    return s;
}

/// The disclosure mark: a dot, the accent when expanded, the hot control colour when collapsed,
/// nothing for an item without children.
pub fn markStyle(th: *const Theme, parent: bool, expanded: bool) Style {
    const fills = [4]Color{ .transparent, .transparent, th.control_hot, th.accent };
    return .{ .size = .{ .px(mark_px), .px(mark_px) }, .radius = mark_px / 2, .fill = fills[@as(u2, @intFromBool(expanded)) | (@as(u2, @intFromBool(parent)) << 1)] };
}

/// The visible position at height `y`, for a tree view whose last rect starts at `top`, clamped
/// into the `count` visible rows.
pub fn rowAt(th: *const Theme, top: f32, y: f32, count: u32) u32 {
    return list_zig.rowAt(th, top, y, count);
}

/// Whether `x` is on item `depth`'s disclosure mark (or before it), for a tree view whose last
/// rect starts at `left`: a click there toggles instead of only selecting.
pub fn onMark(th: *const Theme, left: f32, x: f32, depth: u8) bool {
    return x < left + list_zig.inset(th) + th.pad + @as(f32, @floatFromInt(depth)) * indent_px + mark_px + th.gap / 2;
}

// ---- behaviour: pure functions of the value and what happened -------------------------------

/// The state after one key (WAI-ARIA APG tree view): Down and Up move among the visible items,
/// Home and End to the first and last; Right expands a collapsed parent, or moves into an
/// expanded one's first child; Left collapses an expanded parent, or moves to the parent.
pub fn step(st: anytype, depths: []const u8, visible: []const u32, code: u8) void {
    const km = &list_zig.default_keys;
    const sel = st.selected;
    const pos = positionOf(visible, sel);
    // The selection is always visible (only it collapses, and a click selects what it
    // toggles), but a state set from outside may hide it: then keys do nothing.
    if (pos == none) return;
    const last: u32 = @intCast(visible.len - 1);
    const parent = hasChildren(depths, sel);
    if (code == km.down) st.selected = visible[@min(pos + 1, last)];
    if (code == km.up) st.selected = visible[pos -| 1];
    if (code == km.home) st.selected = visible[0];
    if (code == km.end) st.selected = visible[last];
    if (code == km.right) {
        if (parent and st.expanded[sel]) st.selected = sel + 1;
        st.expanded[sel] = st.expanded[sel] or parent;
    }
    if (code == km.left) {
        const up = parentOf(depths, sel);
        if (!(parent and st.expanded[sel]) and up != none) st.selected = up;
        st.expanded[sel] = false;
    }
}

/// A click on visible row `pos`: selects its item, and toggles it when the click is on its
/// disclosure mark.
pub fn click(st: anytype, depths: []const u8, visible: []const u32, pos: u32, on_mark: bool) void {
    const item = visible[pos];
    st.selected = item;
    st.expanded[item] = st.expanded[item] != (on_mark and hasChildren(depths, item));
}

/// One frame of input: a click, then this frame's keys while focused (press and repeat). The
/// visible items are recomputed after each change; `scratch` holds them (one entry per item).
pub fn update(st: anytype, th: *const Theme, depths: []const u8, r: Response, rect: types.Rect, in: *const Input, scratch: []u32) void {
    var len = visibleItems(depths, &st.expanded, scratch);
    if (r.clicked) {
        const pos = rowAt(th, rect.y0, in.pointer[1], len);
        click(st, depths, scratch[0..len], pos, onMark(th, rect.x0, in.pointer[0], depths[scratch[pos]]));
        len = visibleItems(depths, &st.expanded, scratch);
    }
    if (!r.focused) return;
    for (in.events) |e| {
        if (e.kind != .press and e.kind != .repeat) continue;
        step(st, depths, scratch[0..len], e.code);
        len = visibleItems(depths, &st.expanded, scratch);
    }
}

// ---- accessibility ---------------------------------------------------------------------------

/// Roles of the built rows: the tree view a tree, each item row a tree item. Rows are the box,
/// then per visible item its row, mark and label.
pub fn setRoles(t: *Tree, box: u32, len: u32) void {
    t.c.role[box] = @backingInt(a11y.Role.tree);
    for (0..len) |k| t.c.role[box + 1 + 3 * k] = @backingInt(a11y.Role.tree_item);
}

/// States of the built items for the bridge: parents are expandable and say whether they are
/// expanded, the selected item is selected. Run before `a11y.states`.
pub fn setStates(s: *a11y.Semantics, box: u32, depths: []const u8, st: anytype, visible: []const u32) void {
    for (visible, 0..) |item, k| {
        s.c.state[box + 1 + 3 * k] |= a11y.State.bitsOf(.{
            .expandable = hasChildren(depths, item),
            .expanded = hasChildren(depths, item) and st.expanded[item],
            .selected = item == st.selected,
        });
    }
}

// ---- runtime front end ----------------------------------------------------------------------

/// A tree view of `n` items, `labels` and `depths` in depth-first order, with `st` its state.
pub fn tree(f: *Frame, th: *const Theme, id: Id, comptime n: usize, labels: []const []const u8, depths: []const u8, st: *State(n)) Response {
    var scratch: [n]u32 = undefined;
    // The input changes which rows exist, so the response is read before the tree view is
    // opened; `interact` then marks it and reports the same response.
    const rect = f.lastRect(id);
    const pre = f.ctx.inter.response(id);
    update(st, th, depths, pre, rect, f.in, &scratch);
    const len = visibleItems(depths, &st.expanded, &scratch);
    var s = treeStyle(th);
    s.border_color = list_zig.listBorder(th, pre.focused);
    s.value = @floatFromInt(st.selected);
    const box = f.open(id, s);
    const r = f.interact(box, .button);
    const under = rowAt(th, rect.y0, f.in.pointer[1], len);
    for (scratch[0..len], 0..) |item, k| {
        const row = f.open(.none, rowStyle(th, depths[item]));
        f.setFill(row, list_zig.optionFill(th, r.hovered and under == k, st.selected == item));
        _ = f.leaf(.none, markStyle(th, hasChildren(depths, item), st.expanded[item]));
        _ = base.label(f, th, labels[item]);
        f.close();
    }
    f.close();
    setRoles(f.tree(), box.ix(), len);
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A tree view named `id` bound to the `State(n)` field `state`, over the `n` items of the
    /// fields `labels` ([]const []const u8) and `depths` ([]const u8). The spec holds `n` item
    /// rows, the most that can be visible, so capacity is exact; each binds the depths field and
    /// holds a mark and a label bound to the labels.
    pub fn tree(comptime th: Theme, comptime id: @EnumLiteral(), comptime state: @EnumLiteral(), comptime labels: @EnumLiteral(), comptime depths: @EnumLiteral(), comptime n: u32) Spec {
        var rows: [n]Spec = undefined;
        for (&rows) |*r| {
            r.* = spec_zig.row(.{}, .{ Spec{ .kind = .col }, base.ct.label(th, labels) });
            r.bind = @tagName(depths);
        }
        var s = spec_zig.col(.{}, rows);
        s.id = @tagName(id);
        s.bind = @tagName(state);
        return s;
    }

    /// The fields and item count a `ct.tree` node was built with.
    pub fn fields(comptime n: Spec) struct { state: []const u8, labels: []const u8, depths: []const u8, n: u32 } {
        return .{ .state = n.bind.?, .labels = n.children[0].children[1].bind.?, .depths = n.children[0].bind.?, .n = n.children.len };
    }
};

/// The comptime front end for a page of tree views: rows, columns and labels as in
/// `base.ComptimeUi`, every node with an id a tree view made by `ct.tree`.
pub fn ComptimeTree(comptime S: type, comptime spec: Spec, comptime th: Theme) type {
    const E = events.Events(spec);
    const Sig = signals.Signals(S, spec);
    inline for (E.widget_nodes) |row| {
        const v = ct.fields(list_zig.nodeAt(spec, row));
        validate(S, v.state, v.labels, v.depths, v.n);
    }
    const Tables = list_zig.CtFrame(flatten.count(spec) + 1, @max(list_zig.labelCount(spec), 1));
    return struct {
        const Self = @This();
        pub const Events = E;
        pub const Signals = Sig;

        page: Tables = .{},
        signals: Sig.Runtime = .{},
        pointer: list_zig.CtPointer(E) = .{},
        font: Mono = .{},

        pub const Output = struct { draw: *const DrawList, tree: *const Tree, event: ?E.Event };

        pub fn frame(ui: *Self, in: *const Input) Output {
            const event = ui.pointer.step(in);
            inline for (0..E.widget_count) |k| {
                const v = comptime ct.fields(list_zig.nodeAt(spec, E.widget_nodes[k]));
                const w = comptime E.widget(k);
                var r = ui.pointer.response(w, in);
                r.clicked = if (event) |e| e == w else false;
                var st = @field(ui.signals.state, v.state);
                var scratch: [v.n]u32 = undefined;
                update(&st, &th, @field(ui.signals.state, v.depths), r, ui.pointer.rectOf(w), in, &scratch);
                ui.signals.set(comptime field(v.state), st);
            }

            const tb = ui.page.begin(in);
            var next: u32 = 0;
            ui.push(spec, 0, &next, in);
            const t = ui.page.end(in);
            ui.pointer.store(t);
            return .{ .draw = &tb.d, .tree = t, .event = event };
        }

        fn push(ui: *Self, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            const tb = &ui.page.tables;
            const state = &ui.signals.state;
            const row = next.*;
            next.* += 1;
            if (n.kind == .label) {
                list_zig.pushLabel(tb, parent, &n.style, @field(state, n.bind.?), &th);
                return;
            }
            if (n.id == null) {
                const i = tb.t.push(parent, .none, &n.style);
                inline for (n.children) |c| ui.push(c, i, next, in);
                tb.t.seal(i);
                return;
            }
            // A tree view (`ct.tree`): rows for the visible items.
            next.* += 3 * n.children.len;
            const v = comptime ct.fields(n);
            const w: E.Widget = @fromBackingInt(@as(E.Index, @intCast(row)));
            const r = ui.pointer.response(w, in);
            const st = @field(state, v.state);
            const labels: []const []const u8 = @field(state, v.labels);
            const depths: []const u8 = @field(state, v.depths);
            var scratch: [v.n]u32 = undefined;
            const len = visibleItems(depths, &st.expanded, &scratch);
            const rect = ui.pointer.rectOf(w);
            var s = treeStyle(&th);
            s.border_color = list_zig.listBorder(&th, r.focused);
            s.value = @floatFromInt(st.selected);
            const box = tb.t.push(parent, .hash(n.id.?), &s);
            const under = rowAt(&th, rect.y0, in.pointer[1], len);
            for (scratch[0..len], 0..) |item, k| {
                var o = rowStyle(&th, depths[item]);
                o.fill = list_zig.optionFill(&th, r.hovered and under == k, st.selected == item);
                const i = tb.t.push(box, .none, &o);
                _ = tb.t.push(i, .none, &markStyle(&th, hasChildren(depths, item), st.expanded[item]));
                list_zig.pushLabel(tb, i, &.{ .role = .label }, labels[item], &th);
                tb.t.seal(i);
            }
            tb.t.seal(box);
            setRoles(&tb.t, box, len);
        }

        fn field(comptime name: []const u8) Sig.Field {
            return comptime std.meta.stringToEnum(Sig.Field, name).?;
        }
    };
}

// ---- example page -----------------------------------------------------------------------------

const outline_labels = [_][]const u8{ "src", "core", "tree.zig", "types.zig", "widgets", "list.zig", "docs", "DESIGN.md" };
const outline_depths = [_]u8{ 0, 1, 2, 2, 1, 2, 0, 1 };
const outline_start: State(8) = .{ .expanded = .{ true, false, false, false, false, false, false, false } };

/// The example page: a caption and a tree view of eight items (two top-level folders, `src`
/// expanded) on a panel, in both front ends, in theme `th`. Its tests and golden images
/// (tools/widgetgolden/) run it.
pub fn Example(comptime th: Theme) type {
    return struct {
        const panel: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(16), .gap = 8, .fill = th.panel };

        /// Runtime front end: the application owns the items and the tree state.
        pub const App = struct {
            outline: State(8) = outline_start,
            clicked: bool = false,

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, panel);
                _ = base.label(f, &th, "Project");
                app.clicked = tree(f, &th, .from("outline"), 8, &outline_labels, &outline_depths, &app.outline).clicked;
                f.close();
            }
        };

        /// Comptime front end: the same page as a spec over a state struct.
        pub const PageState = struct {
            title: []const u8 = "Project",
            labels: []const []const u8 = &outline_labels,
            depths: []const u8 = &outline_depths,
            outline: State(8) = outline_start,
        };
        pub const spec = spec_zig.col(panel, .{
            base.ct.label(th, .title),
            ct.tree(th, .outline, .outline, .labels, .depths, 8),
        });
        pub const Ui = ComptimeTree(PageState, spec, th);
        pub const limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

/// The example page in the default theme, its replay and the frames kept as golden images
/// (tools/widgetgolden/ref/tree-<name>.png), as tools/widgetgolden/dump.zig takes a page.
pub const Page = struct {
    pub const Run = Example(.default).Run;
    pub const replay = @embedFile("testdata/tree.replay");
    pub const golden_frames = .{
        .{ "rest", 0 },
        .{ "expanded", 3 },
        .{ "keys", 9 },
        .{ "collapsed", 13 },
    };
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const theme: Theme = .default;
const Replay = @import("../core/input.zig").Replay;

const test_labels = [_][]const u8{ "src", "core", "tree.zig", "types.zig", "widgets", "list.zig", "docs", "DESIGN.md" };
const test_depths = [_]u8{ 0, 1, 2, 2, 1, 2, 0, 1 };

var harness: Example(theme).Run = .{};

test "tree: the replay gives the same frames in both front ends" {
    const h = &harness;
    h.init();
    var text: [64]u8 = undefined;
    var evs: [16]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = Page.replay };
    var sel: [14]u32 = undefined;
    var shown: [14]u32 = undefined;
    while (try replay.next(buf)) |in| {
        const k = h.frames;
        const out = try h.frame(in);
        try testing.expectEqual(h.app.outline, h.ui.signals.state.outline);
        sel[k] = h.app.outline.selected;
        const t = out.runtime.tree;
        const box = t.find(.from("outline"));
        shown[k] = (t.c.end[box] - box - 1) / 3;
    }
    try testing.expectEqual(@as(u32, 14), h.frames);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 1, 2, 1, 1, 4, 4, 5, 6, 6, 0, 0 }, &sel);
    try testing.expectEqualSlices(u32, &.{ 4, 4, 4, 6, 6, 6, 4, 4, 5, 5, 5, 6, 6, 3 }, &shown);
}

test "tree: roles, value and the expanded and selected states" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 240 } };
    _ = try h.frame(&in);
    h.app.outline.selected = 4;
    h.ui.signals.state.outline = h.app.outline;
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    const box = t.find(.from("outline"));
    try testing.expectEqual(@backingInt(a11y.Role.tree), t.c.role[box]);
    try testing.expectEqual(@as(f32, 4), t.c.value[box]);
    // src (expanded), core, widgets, docs (collapsed parents).
    for (0..4) |k| try testing.expectEqual(@backingInt(a11y.Role.tree_item), t.c.role[box + 1 + 3 * k]);

    var sbuf: [4096]u8 align(@import("../core/mem.zig").column_align) = undefined;
    var carver: @import("../core/mem.zig").Carver = .{ .buf = &sbuf };
    var sem = a11y.Semantics.init(&carver, t.cap);
    sem.clear();
    var scratch: [8]u32 = undefined;
    const len = visibleItems(&test_depths, &h.app.outline.expanded, &scratch);
    setStates(&sem, box, &test_depths, &h.app.outline, scratch[0..len]);
    a11y.names(t, &sem);
    const st = struct {
        fn of(s: u8) a11y.State {
            return @bitCast(s);
        }
    }.of;
    try testing.expectEqual(a11y.State{ .expandable = true, .expanded = true }, st(sem.c.state[box + 1]));
    try testing.expectEqual(a11y.State{ .expandable = true }, st(sem.c.state[box + 4]));
    try testing.expectEqual(a11y.State{ .expandable = true, .selected = true }, st(sem.c.state[box + 7]));
    // Items are named by their label.
    try testing.expectEqual(t.c.text[box + 3], sem.c.name[box + 1]);
}

test "check: what a comptime tree view's state must have" {
    const Good = struct { st: State(3) = .{}, l: []const []const u8 = &.{}, d: []const u8 = &.{} };
    try testing.expectEqual(null, comptime check(Good, "st", "l", "d", 3));
    try testing.expectEqualStrings("tree: a tree view has at least one item", comptime check(Good, "st", "l", "d", 0).?);
    try testing.expectEqualStrings("tree: state has no field 'x' for the tree state", comptime check(Good, "x", "l", "d", 3).?);
    try testing.expectEqualStrings("tree: field 'st' must be a tree.State(4)", comptime check(Good, "st", "l", "d", 4).?);
    try testing.expectEqualStrings("tree: state has no field 'y' for the labels", comptime check(Good, "st", "y", "d", 3).?);
    try testing.expectEqualStrings("tree: labels field 'd' must be a []const []const u8", comptime check(Good, "st", "d", "d", 3).?);
    try testing.expectEqualStrings("tree: state has no field 'z' for the depths", comptime check(Good, "st", "l", "z", 3).?);
    try testing.expectEqualStrings("tree: depths field 'l' must be a []const u8", comptime check(Good, "st", "l", "l", 3).?);
}

test "ct.tree: one widget holding a row per item" {
    const spec = comptime ct.tree(theme, .outline, .outline, .labels, .depths, 8);
    try testing.expectEqual(1, events.Events(spec).widget_count);
    const v = comptime ct.fields(spec);
    try testing.expectEqualStrings("outline", v.state);
    try testing.expectEqualStrings("labels", v.labels);
    try testing.expectEqualStrings("depths", v.depths);
    try testing.expectEqual(8, v.n);
    try testing.expectEqual(1 + 8 * 3, flatten.count(spec));
}

test "visibleItems, parentOf, hasChildren: the outline's structure" {
    var out: [8]u32 = undefined;
    var e: [8]bool = @splat(false);
    try testing.expectEqualSlices(u32, &.{ 0, 6 }, out[0..visibleItems(&test_depths, &e, &out)]);
    e[0] = true;
    try testing.expectEqualSlices(u32, &.{ 0, 1, 4, 6 }, out[0..visibleItems(&test_depths, &e, &out)]);
    e[4] = true;
    try testing.expectEqualSlices(u32, &.{ 0, 1, 4, 5, 6 }, out[0..visibleItems(&test_depths, &e, &out)]);
    // An expanded item under a collapsed one stays hidden.
    e[0] = false;
    try testing.expectEqualSlices(u32, &.{ 0, 6 }, out[0..visibleItems(&test_depths, &e, &out)]);
    try testing.expectEqual(none, parentOf(&test_depths, 0));
    try testing.expectEqual(@as(u32, 1), parentOf(&test_depths, 3));
    try testing.expectEqual(@as(u32, 0), parentOf(&test_depths, 4));
    try testing.expectEqual(@as(u32, 6), parentOf(&test_depths, 7));
    try testing.expect(hasChildren(&test_depths, 1));
    try testing.expect(!hasChildren(&test_depths, 2));
    try testing.expect(!hasChildren(&test_depths, 7));
    try testing.expectEqual(@as(u32, 1), positionOf(&.{ 0, 6 }, 6));
    try testing.expectEqual(none, positionOf(&.{ 0, 6 }, 3));
}

test "step, click: the behaviour as pure functions" {
    const km = list_zig.default_keys;
    var st: State(8) = .{};
    var out: [8]u32 = undefined;
    const Key = struct {
        fn press(s: *State(8), o: *[8]u32, code: u8) void {
            step(s, &test_depths, o[0..visibleItems(&test_depths, &s.expanded, o)], code);
        }
    };
    Key.press(&st, &out, km.right); // expand src
    try testing.expect(st.expanded[0]);
    try testing.expectEqual(@as(u32, 0), st.selected);
    Key.press(&st, &out, km.right); // into core
    try testing.expectEqual(@as(u32, 1), st.selected);
    Key.press(&st, &out, km.right); // expand core
    Key.press(&st, &out, km.end);
    try testing.expectEqual(@as(u32, 6), st.selected);
    Key.press(&st, &out, km.up);
    try testing.expectEqual(@as(u32, 4), st.selected);
    Key.press(&st, &out, km.right); // expand widgets
    Key.press(&st, &out, km.right); // into list.zig
    try testing.expectEqual(@as(u32, 5), st.selected);
    Key.press(&st, &out, km.right); // a leaf: nothing
    try testing.expectEqual(@as(u32, 5), st.selected);
    try testing.expect(!st.expanded[5]);
    Key.press(&st, &out, km.left); // to widgets
    try testing.expectEqual(@as(u32, 4), st.selected);
    Key.press(&st, &out, km.left); // collapse widgets
    try testing.expect(!st.expanded[4]);
    Key.press(&st, &out, km.left); // to src
    try testing.expectEqual(@as(u32, 0), st.selected);
    Key.press(&st, &out, km.home);
    Key.press(&st, &out, km.up);
    try testing.expectEqual(@as(u32, 0), st.selected);
    Key.press(&st, &out, km.left); // collapse src; at depth 0 there is no parent
    try testing.expectEqual(@as(u32, 0), st.selected);
    try testing.expect(!st.expanded[0]);
    // Clicks: on the mark toggles a parent, elsewhere only selects; a leaf never toggles.
    const vis = [_]u32{ 0, 6 };
    click(&st, &test_depths, &vis, 1, false);
    try testing.expectEqual(@as(u32, 6), st.selected);
    try testing.expect(!st.expanded[6]);
    click(&st, &test_depths, &vis, 1, true);
    try testing.expect(st.expanded[6]);
    click(&st, &test_depths, &.{7}, 0, true);
    try testing.expect(!st.expanded[7]);
}

test "tree: both front ends agree; rows indent by depth" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 240 } };
    var out = try h.frame(&in);
    var t = out.runtime.tree;
    const box = t.find(.from("outline"));
    // src, core, widgets, docs: core's label one indent further right than src's.
    try testing.expectEqual(@as(u32, 4), (t.c.end[box] - box - 1) / 3);
    try testing.expectApproxEqAbs(indent_px, t.rect(box + 6).x0 - t.rect(box + 3).x0, 0.5);
    // Expanded parents show the accent mark, collapsed ones the hot control colour.
    try testing.expectEqual(theme.accent.bitsOf(), t.c.look[box + 2].fill);
    try testing.expectEqual(theme.control_hot.bitsOf(), t.c.look[box + 5].fill);
    // Hover the third row.
    const r = t.rect(box);
    in.pointer = .{ r.x0 + 100, r.y0 + list_zig.inset(&theme) + list_zig.rowHeight(&theme) * 2.5 };
    out = try h.frame(&in);
    t = out.runtime.tree;
    try testing.expectEqual(theme.control.bitsOf(), t.c.look[box + 7].fill);
    try testing.expectEqual(theme.accent.bitsOf(), t.c.look[box + 1].fill);
    try testing.expect(onMark(&theme, 16, 16 + 2 + 8 + 4, 0));
    try testing.expect(!onMark(&theme, 16, 16 + 2 + 8 + 20, 0));
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
