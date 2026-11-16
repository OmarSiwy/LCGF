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

// ---- spec ---------------------------------------------------------------------------------

/// Starts the tab set and builds its tab list: tab `k` has the identity `ids[k]` and shows
/// `titles[k]`. `selected.*` is clamped into range. Build the panels next, one per tab in
/// order, then `close`.
pub fn open(f: *Frame, th: *const Theme, ids: []const Id, selected: *u32, titles: []const []const u8) void {
    std.debug.assert(ids.len == titles.len and ids.len > 0);
    selected.* = @min(selected.*, @as(u32, @intCast(ids.len - 1)));
    _ = f.open(.none, setStyle(th));
    _ = f.open(.none, listStyle(th));
    for (ids, titles, 0..) |id, title, k| {
        const tab = f.open(id, tabStyle(th));
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
    return f.open(.none, panelStyle(th, selected == k));
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
            pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
                const th = @TypeOf(ui.*).theme;
                const t = &ui.tables.t;
                const sel: u32 = @min(@as(u32, @field(ui.signals.state, selected)), names.len - 1);
                const set = t.push(parent, .none, &n.style);
                const list = t.push(set, .none, &n.children[0].style);
                next.* += 2;
                inline for (n.children[0].children, names, 0..) |hd, name, k| {
                    var ts = hd.style;
                    ts.fill = tabFill(&th, ui.response(next.*, in), sel == k);
                    const tab = t.push(list, .hash(name), &ts);
                    next.* += 1;
                    ui.push(hd.children[0], tab, next, in);
                    t.seal(tab);
                }
                t.seal(list);
                const panels = t.push(set, .none, &n.children[1].style);
                next.* += 1;
                inline for (n.children[1].children, 0..) |p, k| {
                    const row = t.push(panels, .none, &panelStyle(&th, sel == k));
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

/// Three tabs: General (a checkbox), View (a slider), About (a label).
fn Page(comptime th: Theme) type {
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

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
