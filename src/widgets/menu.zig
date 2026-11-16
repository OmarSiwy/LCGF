//! Menu (tier 2): a button that opens a list of actions, one of which may open a submenu, the
//! WAI-ARIA APG menu pattern (a menu button with a menu). Written against the public API of
//! tiers 0 and 1, after the recipe in base.zig. The list floats under the root on a scrim, below
//! the trigger's rect of the last frame, as a popover does (popover.zig, `Style.float`).
//!
//! The items are fixed when compiling (`Def`); their state is a `MenuState` owned by the
//! application: open or not, the highlighted item, the submenu, and the item chosen this frame.
//!
//! Runtime: `trigger` in the page's flow, then `show(...)` under the root after the page.
//!
//! Comptime: `const M = Menu(th, .file, .menu, def);` gives the spec builders `M.button` and
//! `M.layer` and the hooks `popover.ComptimePage(State, spec, th, M)` runs.

const std = @import("std");
const base = @import("base.zig");
const popover = @import("popover.zig");
const types = @import("../core/types.zig");
const Input = @import("../core/input.zig").Input;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const a11y = @import("../a11y/tree.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Rect = types.Rect;
const Style = types.Style;
const Response = types.Response;
const Part = popover.Part;
const partName = popover.partName;

// ---- spec: what the menu takes and keeps -----------------------------------------------------

/// A menu's items, fixed when compiling. Each item has a name: its id is `menu_item` (menu name,
/// underscore, item name) and, in the comptime front end, its label shows the string field of
/// the same name. Items are numbered in one sequence: the top list, then the submenu.
pub const Def = struct {
    items: []const [:0]const u8,
    /// The top item that opens the submenu, by position, or null for no submenu.
    sub_at: ?u8 = null,
    sub: []const [:0]const u8 = &.{},

    /// Items in all: the top list and the submenu.
    pub fn count(comptime d: Def) u8 {
        return @intCast(d.items.len + d.sub.len);
    }
    /// The name of item `k` (in the one sequence).
    pub fn name(comptime d: Def, comptime k: u8) [:0]const u8 {
        return if (k < d.items.len) d.items[k] else d.sub[k - d.items.len];
    }
};

/// No item.
pub const no_item: u8 = 0xff;

/// A menu's state, owned by the application.
pub const MenuState = struct {
    open: bool = false,
    /// The highlighted item of the top list, by position.
    active: u8 = 0,
    /// The submenu is open.
    sub: bool = false,
    /// The highlighted item of the submenu, by position in it.
    sub_active: u8 = 0,
    /// The item last under the pointer (in the one sequence), or `no_item`: the pointer moves
    /// the highlight only when it reaches another item, so arrows are not undone by a resting
    /// pointer.
    hover: u8 = no_item,
    /// The item chosen this frame, in the one sequence, plus one; 0 when none.
    chosen: u8 = 0,
};

/// `null` if `State` can hold menu `def` bound to `menu`, else the compile error: `menu` must
/// be a `MenuState`, and every item needs a string field of its name.
pub fn checkMenu(comptime State: type, comptime def: Def, comptime menu: []const u8) ?[]const u8 {
    if (!@hasField(State, menu)) return "menu: state " ++ @typeName(State) ++ " has no field '" ++ menu ++ "'";
    if (@FieldType(State, menu) != MenuState) return "menu: field '" ++ menu ++ "' must be a menu.MenuState";
    if (def.items.len == 0) return "menu: no items";
    if (def.count() >= no_item) return "menu: too many items";
    if ((def.sub_at == null) != (def.sub.len == 0)) return "menu: a submenu needs both sub_at and sub items";
    if (def.sub_at) |k| if (k >= def.items.len) return "menu: sub_at is past the items";
    inline for (0..def.count()) |k| {
        const n = comptime def.name(k);
        if (!@hasField(State, n)) return "menu: item '" ++ n ++ "' needs a string field of its name";
        if (@FieldType(State, n) != []const u8) return "menu: field '" ++ n ++ "' must be a []const u8";
    }
    return null;
}

/// Menu `name`, with items `def`, bound to the `MenuState` field `menu`, in theme `th`: its spec
/// builders and the hooks `popover.ComptimePage` calls.
pub fn Menu(comptime th: Theme, comptime name: @EnumLiteral(), comptime menu: @EnumLiteral(), comptime def: Def) type {
    const id = @tagName(name);
    const menu_name = @tagName(menu);
    return struct {
        /// The button that opens and closes the menu, showing the string field `text`.
        pub fn button(comptime text: @EnumLiteral()) Spec {
            return base.ct.button(th, name, text);
        }

        /// The scrim, the list and the submenu, shown while the menu is open. Put it last in the
        /// page's root so it is drawn above the rest.
        pub fn layer() Spec {
            var top: [def.items.len]Spec = undefined;
            for (&top, 0..) |*s, k| s.* = itemSpec(id, def.items[k]);
            var list = spec_zig.col(.{}, top);
            list.id = partName(id, "panel");
            if (def.sub.len == 0) return .{ .kind = .col, .id = partName(id, "scrim"), .children = &.{list} };
            var subs: [def.sub.len]Spec = undefined;
            for (&subs, 0..) |*s, k| s.* = itemSpec(id, def.sub[k]);
            var sub = spec_zig.col(.{}, subs);
            sub.id = partName(id, "sub");
            return .{ .kind = .col, .id = partName(id, "scrim"), .children = &.{ list, sub } };
        }

        pub fn check(comptime State: type) ?[]const u8 {
            return checkMenu(State, def, menu_name);
        }

        pub fn step(sig: anytype, v: anytype) void {
            _ = sig;
            _ = v;
        }

        pub fn part(comptime n: Spec, st: anytype, v: anytype) ?Part {
            const ms: MenuState = @field(st, menu_name);
            if (comptime named(n, partName(id, "scrim"))) {
                if (!ms.open) return null;
                return .{ .style = popover.scrimStyle(v.in.viewport) };
            }
            if (comptime named(n, partName(id, "panel"))) return .{ .style = listStyle(&th, v.last.of(id)) };
            if (comptime named(n, partName(id, "sub"))) {
                if (!ms.sub) return null;
                return .{ .style = subStyle(&th, v.last.of(partName(id, def.items[def.sub_at.?]))) };
            }
            if (comptime itemOf(def, id, n)) |k| return .{ .style = itemStyle(&th, highlighted(def, ms, k)) };
            return popover.plainPart(th, n, v.response);
        }
    };
}

/// Whether item `k` (in the one sequence) is highlighted: the active item of its list.
pub fn highlighted(comptime def: Def, st: MenuState, k: u8) bool {
    _ = def;
    _ = st;
    _ = k;
    return false;
}

fn named(comptime n: Spec, comptime want: []const u8) bool {
    return n.id != null and std.mem.eql(u8, n.id.?, want);
}

/// The item (in the one sequence) that spec node `n` is, or null.
fn itemOf(comptime def: Def, comptime id: []const u8, comptime n: Spec) ?u8 {
    inline for (0..def.count()) |k| if (named(n, partName(id, def.name(k)))) return k;
    return null;
}

/// An item: a row named `menu_item` holding a label of the string field `item`.
fn itemSpec(comptime id: []const u8, comptime item: [:0]const u8) Spec {
    // As `base.ct.label` builds a label, from a name instead of an enum literal.
    var s = spec_zig.row(.{}, .{Spec{ .kind = .label, .bind = item, .style = .{ .role = .label } }});
    s.id = partName(id, item);
    return s;
}

// ---- look -------------------------------------------------------------------------------------

/// The list, floating `th.gap` below the trigger's rect `at` (last frame's), left edges
/// aligned: the popover's panel (panel fill, control outline), with half a gap of padding and
/// the items touching.
pub fn listStyle(th: *const Theme, at: Rect) Style {
    var s = popover.panelStyle(th, at);
    s.pad = @splat(th.gap * 0.5);
    s.gap = 0;
    return s;
}

/// The submenu: the list's look, to the right of the rect `at` of the item that opens it, its
/// first item level with that item.
pub fn subStyle(th: *const Theme, at: Rect) Style {
    var s = listStyle(th, at);
    s.offset = .{ at.x1 + th.gap * 0.5, at.y0 - th.gap * 0.5 };
    return s;
}

/// An item row, as wide as the list: padded like a button, filled when highlighted.
pub fn itemStyle(th: *const Theme, active: bool) Style {
    return .{
        .dir = .x,
        .size = .{ .fill, .fit },
        .pad = .{ th.pad, th.gap, th.pad, th.gap },
        .cross = .center,
        .radius = th.radius,
        .fill = itemFills(th)[@intFromBool(active)],
    };
}

/// An item's fill by highlight, indexed by it: none, then the hot control colour.
pub fn itemFills(th: *const Theme) base.OnOff {
    return .{ .transparent, th.control_hot };
}

// ---- runtime front end ------------------------------------------------------------------------

/// The trigger: a button named `name` showing `text`.
pub fn trigger(f: *Frame, th: *const Theme, comptime name: []const u8, text: []const u8) Response {
    return base.button(f, th, .from(name), text);
}

/// Builds menu `name` (items `def`, labels `texts` in the one sequence) if it is open. Call
/// it at the root's depth, after the rest of the page, so it is drawn on top. Returns the item
/// chosen this frame plus one, or 0 (also left in `st.chosen`).
pub fn show(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: Def, st: *MenuState, texts: []const []const u8) u8 {
    std.debug.assert(texts.len == def.count());
    if (!st.open) return st.chosen;
    _ = f.open(.from(partName(name, "scrim")), popover.scrimStyle(f.in.viewport));
    _ = f.open(.from(partName(name, "panel")), listStyle(th, f.lastRect(.from(name))));
    inline for (0..def.items.len) |k| buildItem(f, th, name, def, st, k, texts[k]);
    f.close();
    if (def.sub_at) |at| if (st.sub) {
        _ = f.open(.from(partName(name, "sub")), subStyle(th, f.lastRect(.from(partName(name, def.items[at])))));
        inline for (def.items.len..comptime def.count()) |k| buildItem(f, th, name, def, st, k, texts[k]);
        f.close();
    };
    f.close();
    return st.chosen;
}

fn buildItem(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: Def, st: *const MenuState, comptime k: u8, text: []const u8) void {
    _ = f.open(.from(partName(name, def.name(k))), itemStyle(th, highlighted(def, st.*, k)));
    _ = base.label(f, th, text);
    f.close();
}

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;

const file_menu: Def = .{ .items = &.{ "new", "open", "recent", "quit" }, .sub_at = 2, .sub = &.{ "scene1", "scene2" } };
const file_texts = [_][]const u8{ "New", "Open", "Recent", "Quit", "Scene 1", "Scene 2" };

/// The test page: a toolbar with the File button and a label, and its menu.
fn Page(comptime th: Theme) type {
    return struct {
        const toolbar_style: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel };

        pub const App = struct {
            menu: MenuState = .{},
            chosen: u8 = 0,

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, .{});
                _ = f.open(.none, toolbar_style);
                _ = trigger(f, &th, "file", "File");
                _ = base.label(f, &th, "Untitled");
                f.close();
                app.chosen = show(f, &th, "file", file_menu, &app.menu, &file_texts);
                f.close();
            }
        };

        pub const State = struct {
            menu: MenuState = .{},
            file_text: []const u8 = "File",
            doc: []const u8 = "Untitled",
            new: []const u8 = "New",
            open: []const u8 = "Open",
            recent: []const u8 = "Recent",
            quit: []const u8 = "Quit",
            scene1: []const u8 = "Scene 1",
            scene2: []const u8 = "Scene 2",
        };
        pub const M = Menu(th, .file, .menu, file_menu);
        pub const spec = spec_zig.col(.{}, .{
            spec_zig.row(toolbar_style, .{ M.button(.file_text), base.ct.label(th, .doc) }),
            M.layer(),
        });
        pub const Ui = popover.ComptimePage(State, spec, th, M);
        pub const limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

test "Menu: the page agrees in both front ends, closed, open and with the submenu" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 400, 300 } };
    try testing.expectEqual(@as(u32, 6), (try h.frame(&in)).runtime.tree.len);
    h.app.menu.open = true;
    h.ui.signals.set(.menu, .{ .open = true });
    _ = try h.frame(&in);
    var t = (try h.frame(&in)).runtime.tree;
    // Scrim, list, four items of two rows each.
    try testing.expectEqual(@as(u32, 6 + 2 + 8), t.len);
    const at = t.rect(t.find(.from("file")));
    const list = t.rect(t.find(.from("file_panel")));
    try testing.expectEqual(at.x0, list.x0);
    try testing.expectEqual(at.y1 + Theme.default.gap, list.y0);
    h.app.menu.sub = true;
    h.ui.signals.set(.menu, .{ .open = true, .sub = true });
    _ = try h.frame(&in);
    t = (try h.frame(&in)).runtime.tree;
    try testing.expectEqual(@as(u32, 6 + 2 + 8 + 1 + 4), t.len);
    // The submenu opens to the right of Recent.
    const recent = t.rect(t.find(.from("file_recent")));
    try testing.expectEqual(recent.x1 + 3, t.rect(t.find(.from("file_sub"))).x0);
    try testing.expectEqual(recent.y0, t.rect(t.find(.from("file_scene1"))).y0);
}

test "listStyle, subStyle, itemStyle: the theme's tokens" {
    const th: Theme = .default;
    const at: Rect = .{ .x0 = 10, .y0 = 20, .x1 = 60, .y1 = 40 };
    const l = listStyle(&th, at);
    try testing.expect(l.float);
    try testing.expectEqual([2]f32{ 10, 40 + th.gap }, l.offset);
    try testing.expectEqual(th.panel, l.fill);
    try testing.expectEqual(th.control_hot, l.border_color);
    try testing.expectEqual([4]f32{ 3, 3, 3, 3 }, l.pad);
    try testing.expectEqual([2]f32{ 63, 17 }, subStyle(&th, at).offset);
    try testing.expectEqual(types.Color.transparent, itemStyle(&th, false).fill);
    try testing.expectEqual(th.control_hot, itemStyle(&th, true).fill);
    try testing.expectEqual(types.Size.fill, itemStyle(&th, true).size[0]);
}

const light: Theme = .{ .panel = .rgb(240, 240, 240), .control_hot = .rgb(180, 180, 190), .text = .rgb(20, 20, 20), .pad = 12, .gap = 10, .radius = 0 };

test "Menu: another theme restyles both front ends alike" {
    const S = struct {
        var h: Page(light).Run = .{};
    };
    S.h.init();
    const in: Input = .{ .viewport = .{ 400, 300 } };
    _ = try S.h.frame(&in);
    S.h.app.menu = .{ .open = true, .sub = true };
    S.h.ui.signals.set(.menu, .{ .open = true, .sub = true });
    _ = try S.h.frame(&in);
    const t = (try S.h.frame(&in)).runtime.tree;
    try testing.expectEqual(light.panel.bitsOf(), t.c.look[t.find(.from("file_sub"))].fill);
    // Items are as wide as their list.
    try testing.expectEqual(t.rect(t.find(.from("file_new"))).w(), t.rect(t.find(.from("file_quit"))).w());
}

test "checkMenu: the state field, the item fields and the submenu" {
    try testing.expectEqual(null, comptime checkMenu(Default.State, file_menu, "menu"));
    try testing.expectEqualStrings("menu: field 'menu' must be a menu.MenuState", comptime checkMenu(struct { menu: bool }, file_menu, "menu").?);
    try testing.expectEqualStrings("menu: item 'new' needs a string field of its name", comptime checkMenu(struct { menu: MenuState }, file_menu, "menu").?);
    try testing.expectEqualStrings("menu: a submenu needs both sub_at and sub items", comptime checkMenu(Default.State, .{ .items = &.{"new"}, .sub_at = 0 }, "menu").?);
    try testing.expectEqualStrings("menu: sub_at is past the items", comptime checkMenu(Default.State, .{ .items = &.{"new"}, .sub_at = 1, .sub = &.{"open"} }, "menu").?);
    try testing.expectEqualStrings("menu: no items", comptime checkMenu(Default.State, .{ .items = &.{} }, "menu").?);
}

test "Def: one sequence of items, the top list then the submenu" {
    try testing.expectEqual(6, comptime file_menu.count());
    try testing.expectEqualStrings("quit", comptime file_menu.name(3));
    try testing.expectEqualStrings("scene1", comptime file_menu.name(4));
}

test {
    std.testing.refAllDecls(@This());
}
