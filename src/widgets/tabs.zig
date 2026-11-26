//! Tabs (tier 2): a row of tabs above a stack of panels, showing the panel of the selected
//! tab. The selected index is application state (a `u32`). Written against the public API of
//! tiers 0 and 1 (src/widgets/base.zig has the recipe).
//!
//! Runtime: `tabs.open(f, th, &ids, &selected, &titles)`, then for each tab `k`
//! `tabs.panel(f, th, selected, k)`, its children and `f.close()`, then `tabs.close(f)`.
//! Comptime: `tabs.ct.tabs(th, .selected, .{ .{ .id, .title, .{...children} }, ... })`.
//!
//! Every panel is built every frame; the ones not selected are 0 px high and clip, so
//! nothing in them is painted or hit. The rows stay the same whatever is selected, as the
//! comptime front end's fixed tables need.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const Id = types.Id;
const Node = types.Node;
const Theme = base.Theme;
const simd = @import("../core/simd.zig");
const keys = @import("keys.zig");
const none = types.none;
const a11y = @import("../a11y/tree.zig");
const Tree = @import("../core/tree.zig").Tree;

// ---- spec ---------------------------------------------------------------------------------

/// Starts the tab set and builds its tab list: tab `k` has the identity `ids[k]` and shows
/// `titles[k]`. Input moves `selected.*` and keyboard focus first (`select`); it is clamped
/// into range. Build the panels next, one per tab in order, then `close`.
pub fn open(f: *Frame, th: *const Theme, ids: []const Id, selected: *u32, titles: []const []const u8) void {
    std.debug.assert(ids.len == titles.len and ids.len > 0);
    const count: u32 = @intCast(ids.len);
    // What happened to the tabs, from this frame's interaction step (as `Frame.interact`).
    var clicked: u32 = none;
    var focused: u32 = none;
    for (ids, 0..) |id, k| {
        const r = f.ctx.inter.response(id);
        clicked = simd.selU(r.clicked, @intCast(k), clicked);
        focused = simd.selU(r.focused, @intCast(k), focused);
    }
    const m = select(selected.*, count, clicked, focused, f.in);
    selected.* = m.selected;
    if (m.focus != none) f.ctx.inter.focus = @backingInt(ids[m.focus]);
    _ = f.open(.none, setStyle(th));
    const list = f.open(.none, listStyle(th));
    f.tree().c.role[list.ix()] = role.list;
    f.tree().c.value[list.ix()] = @floatFromInt(selected.*);
    for (ids, titles, 0..) |id, title, k| {
        const tab = f.open(id, tabStyle(th));
        f.tree().c.role[tab.ix()] = role.tab;
        const r = f.interact(tab, .button);
        f.setFill(tab, tabFill(th, r, k == selected.*));
        f.setCursor(.pointer, r.hovered);
        _ = base.label(f, th, title);
        f.close();
    }
    f.close();
    _ = f.open(.none, panelsStyle(th));
}

/// Starts the panel of tab `k`; build its children, then `f.close()`.
pub fn panel(f: *Frame, th: *const Theme, selected: u32, k: u32) Node {
    const n = f.open(.none, panelStyle(th, selected == k));
    f.tree().c.role[n.ix()] = role.panel;
    return n;
}

/// Ends the tab set `open` started.
pub fn close(f: *Frame) void {
    f.close();
    f.close();
}

/// The tab set: the tab list above the panels.
pub fn setStyle(th: *const Theme) Style {
    _ = th;
    return .{ .dir = .y, .size = .{ .fill, .fit } };
}

/// The tab list: the tabs side by side.
pub fn listStyle(th: *const Theme) Style {
    _ = th;
    return .{ .dir = .x, .size = .{ .fill, .fit } };
}

/// One tab: its title, padded, with its top corners rounded so it joins the panels below.
pub fn tabStyle(th: *const Theme) Style {
    return .{ .dir = .x, .cross = .center, .pad = .{ th.pad, th.gap, th.pad, th.gap }, .radii = .{ th.radius, th.radius, 0, 0 } };
}

/// A tab's fill: the selected tab takes the panels' colour, so it reads as the front of the
/// stack; the others are filled as buttons, by interaction state. Picked by table index.
pub fn tabFill(th: *const Theme, r: types.Response, selected: bool) types.Color {
    const fills = [2]types.Color{ base.buttonFill(th, r), th.panel };
    return fills[@intFromBool(selected)];
}

/// The stack of panels, on the panel colour and padded; its top-left corner is square, under
/// the first tab.
pub fn panelsStyle(th: *const Theme) Style {
    return .{ .dir = .y, .size = .{ .fill, .fit }, .pad = @splat(th.pad), .fill = th.panel, .radii = .{ 0, th.radius, th.radius, th.radius } };
}

/// One panel: as tall as its children while its tab is selected, else 0 px and clipping,
/// picked by table index.
pub fn panelStyle(th: *const Theme, shown: bool) Style {
    _ = th;
    const heights = [2]types.Size{ .px(0), .fit };
    return .{ .dir = .y, .size = .{ .fill, heights[@intFromBool(shown)] }, .clip = true };
}

// ---- behaviour ----------------------------------------------------------------------------

/// Where selection and focus go: tab indices, `none` for "no tab focused".
pub const Move = struct { selected: u32, focus: u32 };

/// The next selection and focus of a tab set of `count` tabs (WAI-ARIA APG tabs pattern,
/// automatic activation). A click on tab `clicked` selects it. While tab `focused` has focus,
/// Right and Left move focus to the next and previous tab (wrapping), Home and End to the
/// first and last, and the tab focus lands on is selected; Enter and Space select the focused
/// tab. Key repeats move again. `clicked` and `focused` are `none` when no tab was clicked or
/// has focus; then keys do nothing. The selection is clamped into range.
pub fn select(selected: u32, count: u32, clicked: u32, focused: u32, in: *const Input) Move {
    const last = count - 1;
    var sel = @min(simd.selU(clicked != none, clicked, selected), last);
    var foc = focused;
    if (foc == none) return .{ .selected = sel, .focus = none };
    for (in.events) |e| {
        if (e.kind != .press and e.kind != .repeat) continue;
        const k = keys.map;
        const to = if (e.code == k.right) (foc + 1) % count else if (e.code == k.left) (foc + last) % count else if (e.code == k.home) 0 else if (e.code == k.end) last else none;
        foc = simd.selU(to != none, to, foc);
        const activate = e.kind == .press and (e.code == keys.enter or e.code == keys.space);
        sel = simd.selU(to != none or activate, foc, sel);
    }
    return .{ .selected = sel, .focus = foc };
}

// ---- accessibility ------------------------------------------------------------------------

/// What assistive technology sees (WAI-ARIA APG tabs pattern): the tab list is a `tab_list`
/// whose value is the selected index, each tab a `tab` named by its title (from content),
/// each panel a `tab_panel`. `types.Role` has none of them, so both front ends write the
/// bytes to the role column.
pub const role = struct {
    pub const list: u8 = @backingInt(a11y.Role.tab_list);
    pub const tab: u8 = @backingInt(a11y.Role.tab);
    pub const panel: u8 = @backingInt(a11y.Role.tab_panel);
};

/// Fills the caller's semantic columns for the tab set at tree row `row` with `count` tabs,
/// from the tree: the selected tab (the list's value) is `selected`, and each panel is
/// labelled by its tab. Call after the frame, for either front end.
pub fn semantics(t: *const Tree, s: *a11y.Semantics, row: u32, count: u32) void {
    const list = row + 1;
    const sel: u32 = @intFromFloat(t.c.value[list]);
    var p = list + 1 + 2 * count + 1; // the first panel: after the tabs and the panel stack
    for (0..count) |k| {
        const tab = list + 1 + 2 * @as(u32, @intCast(k));
        const on = -%@as(u8, @intFromBool(k == sel));
        s.c.state[tab] |= a11y.State.bitsOf(.{ .selected = true }) & on;
        s.c.labelled_by[p] = tab;
        p = t.c.end[p];
    }
}

/// The tab set as a spec node.
pub const ct = struct {
    /// Tabs over the u32 field `selected`. `tabs_` is a tuple of `.{ id, title, children }`:
    /// the tab's widget name, the string field it shows, and its panel's children (a tuple of
    /// specs). Mistakes are compile errors: no tabs, a tab without three parts, an empty
    /// panel, a `selected` that is not a u32 field or a title that is not a string field.
    pub fn tabs(comptime th: Theme, comptime selected: @EnumLiteral(), comptime tabs_: anytype) Spec {
        if (tabs_.len == 0) @compileError("tabs over '" ++ @tagName(selected) ++ "' have no tabs");
        var heads: [tabs_.len]Spec = undefined;
        var panels: [tabs_.len]Spec = undefined;
        var names: [tabs_.len][:0]const u8 = undefined;
        for (tabs_, &heads, &panels, &names) |t, *hd, *p, *name| {
            if (t.len != 3) @compileError("a tab is .{ id, title, children }");
            if (t[2].len == 0) @compileError("tab '" ++ @tagName(t[0]) ++ "' has an empty panel");
            hd.* = spec_zig.row(tabStyle(&th), .{base.ct.label(th, t[1])});
            hd.id = @tagName(t[0]);
            name.* = @tagName(t[0]);
            p.* = spec_zig.col(panelStyle(&th, false), t[2]);
        }
        const final_names = names;
        var s = spec_zig.col(setStyle(&th), .{ spec_zig.row(listStyle(&th), heads), spec_zig.col(panelsStyle(&th), panels) });
        s.widget = Tabs(@tagName(selected), &final_names);
        return s;
    }

    /// How the comptime front end builds and drives one tab set.
    fn Tabs(comptime selected: []const u8, comptime names: []const [:0]const u8) type {
        return struct {
            /// Selection and focus from the frame's click event and `ui.focus`.
            pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
                _ = row;
                const E = @TypeOf(ui.*).Events;
                var clicked: u32 = none;
                var focused: u32 = none;
                inline for (names, 0..) |name, k| {
                    const me = @field(E.Widget, name);
                    if (event) |e| clicked = simd.selU(std.meta.activeTag(e) == me, k, clicked);
                    focused = simd.selU(ui.focus == me, k, focused);
                }
                const m = select(@field(ui.signals.state, selected), names.len, clicked, focused, in);
                ui.signals.set(comptime @TypeOf(ui.*).field(selected), m.selected);
                inline for (names, 0..) |name, k| {
                    if (m.focus == k) ui.focus = @field(E.Widget, name);
                }
            }

            pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
                const th = @TypeOf(ui.*).theme;
                const t = &ui.tables.t;
                const sel: u32 = @min(@as(u32, @field(ui.signals.state, selected)), names.len - 1);
                const set = t.push(parent, .none, &n.style);
                const list = t.push(set, .none, &n.children[0].style);
                t.c.role[list] = role.list;
                t.c.value[list] = @floatFromInt(sel);
                next.* += 2;
                inline for (n.children[0].children, names, 0..) |hd, name, k| {
                    var ts = hd.style;
                    ts.fill = tabFill(&th, ui.response(next.*, in), sel == k);
                    const tab = t.push(list, .hash(name), &ts);
                    t.c.role[tab] = role.tab;
                    next.* += 1;
                    ui.push(hd.children[0], tab, next, in);
                    t.seal(tab);
                }
                t.seal(list);
                const panels = t.push(set, .none, &n.children[1].style);
                next.* += 1;
                inline for (n.children[1].children, 0..) |p, k| {
                    const row = t.push(panels, .none, &panelStyle(&th, sel == k));
                    t.c.role[row] = role.panel;
                    next.* += 1;
                    inline for (p.children) |c| ui.push(c, row, next, in);
                    t.seal(row);
                }
                t.seal(panels);
                t.seal(set);
            }
        };
    }
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;

/// The example page: three tabs, General (a checkbox), View (a slider) and About (a label),
/// in both front ends, in theme `th`.
pub fn Page(comptime th: Theme) type {
    const column: Style = .{ .dir = .y, .size = .{ .px(260), .fit }, .pad = @splat(8) };
    return struct {
        pub const ids = [_]Id{ .from("general"), .from("view"), .from("about") };
        pub const App = struct {
            selected: u32 = 0,
            wire: bool = false,
            zoom: f32 = 0.5,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, column);
                open(f, &th, &ids, &app.selected, &.{ "General", "View", "About" });
                _ = panel(f, &th, app.selected, 0);
                _ = base.checkbox(f, &th, .from("wire"), &app.wire, "Wireframe");
                f.close();
                _ = panel(f, &th, app.selected, 1);
                _ = base.slider(f, &th, .from("zoom"), &app.zoom, 0, 1);
                f.close();
                _ = panel(f, &th, app.selected, 2);
                _ = base.label(f, &th, "Version 1");
                f.close();
                close(f);
                f.close();
            }
        };
        pub const State = struct {
            selected: u32 = 0,
            general_text: []const u8 = "General",
            view_text: []const u8 = "View",
            about_text: []const u8 = "About",
            wire: bool = false,
            wire_text: []const u8 = "Wireframe",
            zoom: f32 = 0.5,
            version: []const u8 = "Version 1",
        };
        pub const spec = spec_zig.col(column, .{ct.tabs(th, .selected, .{
            .{ .general, .general_text, .{base.ct.checkbox(th, .wire, .wire, .wire_text)} },
            .{ .view, .view_text, .{base.ct.slider(th, .zoom, .zoom)} },
            .{ .about, .about_text, .{base.ct.label(th, .version)} },
        })});
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 48, .texts = 12, .customs = 1, .strings = 256, .depth = 8 });
    };
}

/// Input for `Page(.default)` at 320 x 200, one commented line per frame.
pub const replay = @embedFile("testdata/tabs.replay");

/// The frames of `replay` kept as golden images (tools/golden/ref/widgets/tabs-<name>.png).
pub const golden_frames = .{
    .{ "rest", 0 },
    .{ "view", 3 },
    .{ "about", 4 },
};

const Default = Page(.default);
var harness: Default.Run = .{};

/// Tree rows of the page: root 0, column 1, set 2, list 3, tabs 4/6/8 (labels after each),
/// panels 10, panel rows 11 (checkbox 12..14), 15 (slider 16..17), 18 (label 19).
const rows = struct {
    const list = 3;
    const tab = [3]u32{ 4, 6, 8 };
    const panel = [3]u32{ 11, 15, 18 };
};

test "tabs: both front ends build every panel; only the selected one has height" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(@as(u32, 20), t.len);
    for (rows.tab, Default.ids) |r, id| try testing.expectEqual(r, t.find(id));
    try testing.expect(t.rect(rows.panel[0]).h() > 0);
    try testing.expectEqual(@as(f32, 0), t.rect(rows.panel[1]).h());
    try testing.expectEqual(@as(f32, 0), t.rect(rows.panel[2]).h());
    // The tabs sit side by side.
    try testing.expect(t.rect(rows.tab[1]).x0 >= t.rect(rows.tab[0]).x1);
    // Selection out of range is clamped to the last tab, in both front ends.
    h.app.selected = 7;
    h.ui.signals.state.selected = 7;
    const o2 = try h.frame(&in);
    try testing.expectEqual(@as(u32, 2), h.app.selected);
    try testing.expect(o2.runtime.tree.rect(rows.panel[2]).h() > 0);
}

test "tabs: selected tab on the panel colour, others as buttons; any theme alike" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 200 } };
    var out = try h.frame(&in);
    const th = Theme.default;
    var t = out.runtime.tree;
    try testing.expectEqual(th.panel.bitsOf(), t.c.look[rows.tab[0]].fill);
    try testing.expectEqual(th.control.bitsOf(), t.c.look[rows.tab[1]].fill);
    try testing.expectEqual(th.panel.bitsOf(), t.c.look[10].fill);
    // The panels start right under the tabs.
    try testing.expectEqual(t.rect(rows.tab[0]).y1, t.rect(10).y0);
    // Hovering View lights it in both front ends.
    const r = t.rect(rows.tab[1]);
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    out = try h.frame(&in);
    t = out.runtime.tree;
    try testing.expectEqual(th.control_hot.bitsOf(), t.c.look[rows.tab[1]].fill);
    try testing.expectEqual(th.control_hot.bitsOf(), out.comptime_.tree.c.look[rows.tab[1]].fill);

    const Light = Page(.{ .panel = .rgb(240, 240, 240), .control = .rgb(200, 200, 205), .control_hot = .rgb(180, 180, 190), .text = .rgb(20, 20, 20), .pad = 12, .gap = 10, .radius = 0 });
    const S = struct {
        var light: Light.Run = .{};
    };
    S.light.init();
    _ = try S.light.frame(&in);
    const lo = try S.light.frame(&in);
    try testing.expectEqual(types.Color.rgb(240, 240, 240).bitsOf(), lo.runtime.tree.c.look[rows.tab[0]].fill);
}

test "select: clicks select; arrows, Home and End move focus and selection; Enter selects" {
    const k = keys.map;
    const ev = struct {
        fn of(comptime codes: []const u8) Input {
            const list = comptime blk: {
                var l: [codes.len]Input.Event = undefined;
                for (&l, codes) |*e, c| e.* = .{ .kind = .press, .code = c };
                break :blk l;
            };
            return .{ .events = &list };
        }
    };
    const none_in: Input = .{};
    try testing.expectEqual(Move{ .selected = 2, .focus = none }, select(0, 3, 2, none, &none_in));
    try testing.expectEqual(Move{ .selected = 1, .focus = none }, select(1, 3, none, none, &ev.of(&.{k.right})));
    try testing.expectEqual(Move{ .selected = 1, .focus = 1 }, select(0, 3, none, 0, &ev.of(&.{k.right})));
    try testing.expectEqual(Move{ .selected = 0, .focus = 0 }, select(2, 3, none, 2, &ev.of(&.{k.right})));
    try testing.expectEqual(Move{ .selected = 2, .focus = 2 }, select(0, 3, none, 0, &ev.of(&.{k.left})));
    try testing.expectEqual(Move{ .selected = 2, .focus = 2 }, select(0, 3, none, 1, &ev.of(&.{k.end})));
    try testing.expectEqual(Move{ .selected = 0, .focus = 0 }, select(2, 3, none, 1, &ev.of(&.{k.home})));
    try testing.expectEqual(Move{ .selected = 1, .focus = 1 }, select(0, 3, none, 1, &ev.of(&.{keys.enter})));
    try testing.expectEqual(Move{ .selected = 1, .focus = 1 }, select(0, 3, none, 0, &ev.of(&.{ k.right, k.right, k.left, k.right, k.left })));
    try testing.expectEqual(Move{ .selected = 2, .focus = none }, select(9, 3, none, none, &none_in));
}

test "tabs: click selects and focuses; arrows move both; in both front ends" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    const r = t.rect(rows.tab[1]);
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    in.buttons.left = false;
    var o = try h.frame(&in);
    try testing.expectEqual(@as(u32, 1), h.app.selected);
    try testing.expectEqual(@as(u32, 1), h.ui.signals.state.selected);
    try testing.expect(o.runtime.tree.rect(rows.panel[1]).h() > 0);
    try testing.expectEqual(@as(f32, 0), o.runtime.tree.rect(rows.panel[0]).h());
    const steps = [_]struct { code: u8, sel: u32 }{
        .{ .code = keys.map.right, .sel = 2 },
        .{ .code = keys.map.right, .sel = 0 },
        .{ .code = keys.map.end, .sel = 2 },
        .{ .code = keys.map.left, .sel = 1 },
        .{ .code = 0x04, .sel = 1 },
    };
    for (steps) |st| {
        const e = [1]Input.Event{.{ .kind = .press, .code = st.code }};
        in.events = &e;
        o = try h.frame(&in);
        try testing.expectEqual(st.sel, h.app.selected);
        try testing.expectEqual(st.sel, h.ui.signals.state.selected);
        try testing.expectEqual(@backingInt(Default.ids[st.sel]), h.ctx.inter.focus);
        const W = Default.Ui.Events.Widget;
        try testing.expectEqual(([3]W{ .general, .view, .about })[st.sel], h.ui.focus.?);
    }
    // Keys without a focused tab do nothing.
    in.events = &.{};
    in.pointer = .{ 300, 190 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    in.buttons.left = false;
    const e = [1]Input.Event{.{ .kind = .press, .code = keys.map.right }};
    in.events = &e;
    _ = try h.frame(&in);
    try testing.expectEqual(@as(u32, 1), h.app.selected);
    try testing.expectEqual(@as(u32, 1), h.ui.signals.state.selected);
}

test "tabs: tab list with the selection as value, tabs named and selected, panels labelled" {
    const check = @import("check.zig");
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    h.app.selected = 1;
    h.ui.signals.state.selected = 1;
    const out = try h.frame(&in);
    var sb: check.SemBuf = undefined;
    const trees = [2]*const Tree{ out.runtime.tree, out.comptime_.tree };
    const texts = [2]*const @import("../core/texts.zig").Texts{ out.runtime.texts, &h.ui.tables.tx };
    const strings = [2][]const u8{ h.ctx.strings[h.ctx.cur].buf, h.ui.tables.strings.buf };
    const titles = [3][]const u8{ "General", "View", "About" };
    for (trees, texts, strings) |t, tx, str| {
        var sem = sb.init();
        semantics(t, &sem, 2, 3);
        a11y.names(t, &sem);
        a11y.states(t, &sem);
        try testing.expectEqual(a11y.Role.tab_list, @as(a11y.Role, @fromBackingInt(t.c.role[rows.list])));
        try testing.expectEqual(@as(f32, 1), t.c.value[rows.list]);
        for (rows.tab, rows.panel, titles, 0..) |tab, p, title, k| {
            try testing.expectEqual(a11y.Role.tab, @as(a11y.Role, @fromBackingInt(t.c.role[tab])));
            try testing.expectEqual(a11y.Role.tab_panel, @as(a11y.Role, @fromBackingInt(t.c.role[p])));
            try testing.expectEqualStrings(title, check.nameOf(&sem, tx, str, tab));
            try testing.expectEqualStrings(title, check.nameOf(&sem, tx, str, p));
            const st: a11y.State = @bitCast(sem.c.state[tab]);
            try testing.expectEqual(k == 1, st.selected);
        }
    }
}

test "tabs: the example replay gives the same frames in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var rp: Replay = .{ .src = replay };
    var selected: [8]u32 = undefined;
    var fills: [8]u32 = undefined;
    while (try rp.next(buf)) |in| {
        const k = h.frames;
        const out = try h.frame(in);
        selected[k] = h.app.selected;
        try testing.expectEqual(h.app.selected, h.ui.signals.state.selected);
        fills[k] = out.runtime.tree.c.look[rows.tab[1]].fill;
        // Only the selected panel has height.
        for (rows.panel, 0..) |p, j| try testing.expectEqual(j == h.app.selected, out.runtime.tree.rect(p).h() > 0);
    }
    try testing.expectEqual(@as(u32, 8), h.frames);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 1, 2, 0, 2, 1 }, &selected);
    const th = Theme.default;
    const c = th.controlFills();
    try testing.expectEqualSlices(u32, &.{ c[0].bitsOf(), c[1].bitsOf(), c[3].bitsOf(), th.panel.bitsOf(), c[1].bitsOf() }, fills[0..5]);
}

test "golden_frames: name frames the tabs replay has" {
    inline for (golden_frames) |g| try testing.expect(g[1] < 8);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
