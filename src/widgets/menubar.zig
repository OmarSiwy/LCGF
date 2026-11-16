//! Menu bar (tier 2): a row of buttons, each opening a menu, the WAI-ARIA APG menubar pattern.
//! Written against the public API of tiers 0 and 1, after the recipe in base.zig. The bar is in
//! the page's flow; the open menu's list floats under the root below its button, built from the
//! same parts as menu.zig (`menu.Def`, `menu.MenuState`, `menu.advance`).
//!
//! There is no scrim: the bar's buttons stay under the pointer while a menu is open, so the
//! pointer can move from one menu to the next. A press outside the bar's widgets closes it.
//!
//! Runtime: `bar(...)` in the page's flow, then `menus(...)` under the root after the page.
//!
//! Comptime: `const B = MenuBar(th, .bar, .bar_state, def);` gives the spec builders `B.row` and
//! `B.layer` and the hooks `popover.ComptimePage(State, spec, th, B)` runs.

const std = @import("std");
const base = @import("base.zig");
const popover = @import("popover.zig");
const menu = @import("menu.zig");
const types = @import("../core/types.zig");
const Input = @import("../core/input.zig").Input;
const Tree = @import("../core/tree.zig").Tree;
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
const no_item = menu.no_item;
const none = types.none;

// ---- spec: what the menu bar takes and keeps -------------------------------------------------

/// A menu bar's menus, fixed when compiling: one name per button (its id is `bar_name`; in the
/// comptime front end its label shows the string field of that name) and one `menu.Def` per
/// button, whose ids are `bar_name_item` and so on, as menu.zig names them with `bar_name` as
/// the menu's name.
pub const BarDef = struct {
    names: []const [:0]const u8,
    menus: []const menu.Def,
};

/// A menu bar's state, owned by the application.
pub const BarState = struct {
    /// The open menu, by position, or `menu.no_item`.
    open: u8 = no_item,
    /// The open menu's state.
    menu: menu.MenuState = .{},
    /// The button last under the pointer, or `menu.no_item`.
    hover: u8 = no_item,
    /// The left button was down last frame, so a press is seen once.
    down: bool = false,
    /// The menu the item in `menu.chosen` was chosen from this frame, or `menu.no_item`.
    from: u8 = no_item,
};

/// `null` if `State` can hold menu bar `def` bound to `field`, else the compile error.
pub fn checkBar(comptime State: type, comptime def: BarDef, comptime field: []const u8) ?[]const u8 {
    if (!@hasField(State, field)) return "menu bar: state " ++ @typeName(State) ++ " has no field '" ++ field ++ "'";
    if (@FieldType(State, field) != BarState) return "menu bar: field '" ++ field ++ "' must be a menubar.BarState";
    if (def.names.len == 0 or def.names.len != def.menus.len) return "menu bar: one menu per button, at least one";
    if (def.names.len >= no_item) return "menu bar: too many menus";
    for (def.names, def.menus) |n, m| {
        if (!@hasField(State, n) or @FieldType(State, n) != []const u8) return "menu bar: button '" ++ n ++ "' needs a string field of its name";
        if (m.items.len == 0) return "menu bar: menu '" ++ n ++ "' has no items";
        if (m.count() >= no_item) return "menu bar: menu '" ++ n ++ "' has too many items";
        if ((m.sub_at == null) != (m.sub.len == 0)) return "menu bar: menu '" ++ n ++ "': a submenu needs both sub_at and sub items";
        if (m.sub_at) |k| if (k >= m.items.len) return "menu bar: menu '" ++ n ++ "': sub_at is past the items";
        for (0..m.count()) |k| {
            const item = if (k < m.items.len) m.items[k] else m.sub[k - m.items.len];
            if (!@hasField(State, item) or @FieldType(State, item) != []const u8) return "menu bar: item '" ++ item ++ "' needs a string field of its name";
        }
    }
    return null;
}

/// Menu bar `name` with menus `def`, bound to the `BarState` field `field`, in theme `th`: its
/// spec builders and the hooks `popover.ComptimePage` calls.
pub fn MenuBar(comptime th: Theme, comptime name: @EnumLiteral(), comptime field: @EnumLiteral(), comptime def: BarDef) type {
    const id = @tagName(name);
    const field_name = @tagName(field);
    return struct {
        /// The bar: a row of buttons, in the page's flow.
        pub fn row() Spec {
            var buttons: [def.names.len]Spec = undefined;
            for (&buttons, def.names) |*s, n| s.* = textRow(partName(id, n), n);
            var r = spec_zig.row(.{}, buttons);
            r.id = partName(id, "bar");
            return r;
        }

        /// The menus' lists, of which the open one is shown. Put it last in the page's root so
        /// it is drawn above the rest.
        pub fn layer() Spec {
            var kids: [listCount(def)]Spec = undefined;
            var j: usize = 0;
            for (def.names, def.menus) |n, m| {
                const mid = partName(id, n);
                var items: [m.items.len]Spec = undefined;
                for (&items, m.items) |*s, item| s.* = textRow(partName(mid, item), item);
                kids[j] = spec_zig.col(.{}, items);
                kids[j].id = partName(mid, "panel");
                j += 1;
                if (m.sub.len == 0) continue;
                var subs: [m.sub.len]Spec = undefined;
                for (&subs, m.sub) |*s, item| s.* = textRow(partName(mid, item), item);
                kids[j] = spec_zig.col(.{}, subs);
                kids[j].id = partName(mid, "sub");
                j += 1;
            }
            return spec_zig.col(layerStyle(), kids);
        }

        pub fn check(comptime State: type) ?[]const u8 {
            return checkBar(State, def, field_name);
        }

        pub fn step(sig: anytype, v: anytype) void {
            _ = sig;
            _ = v;
        }

        pub fn part(comptime n: Spec, st: anytype, v: anytype) ?Part {
            const bs: BarState = @field(st, field_name);
            if (comptime named(n, partName(id, "bar"))) return .{ .style = barStyle(&th) };
            inline for (def.names, def.menus, 0..) |mn, m, i| {
                const mid = comptime partName(id, mn);
                const open = bs.open == i;
                if (comptime named(n, mid)) return .{ .style = buttonStyle(&th, open, v.response.hovered) };
                if (comptime named(n, partName(mid, "panel"))) {
                    if (!open) return null;
                    return .{ .style = menu.listStyle(&th, v.last.of(mid)) };
                }
                if (comptime m.sub_at != null and named(n, partName(mid, "sub"))) {
                    if (!open or !bs.menu.sub) return null;
                    return .{ .style = menu.subStyle(&th, v.last.of(partName(mid, m.items[m.sub_at.?]))) };
                }
                inline for (0..comptime m.count()) |k| {
                    if (comptime named(n, partName(mid, m.name(k)))) return .{ .style = menu.itemStyle(&th, menu.highlighted(m, bs.menu, k)) };
                }
            }
            return popover.plainPart(th, n, v.response);
        }
    };
}

fn named(comptime n: Spec, comptime want: []const u8) bool {
    return n.id != null and std.mem.eql(u8, n.id.?, want);
}

/// Lists in all: one per menu, one more per submenu.
fn listCount(comptime def: BarDef) usize {
    var k: usize = 0;
    for (def.menus) |m| k += @as(usize, 1) + @intFromBool(m.sub.len != 0);
    return k;
}

/// A row named `id` holding a label of the string field `field`.
fn textRow(comptime id: [:0]const u8, comptime field: [:0]const u8) Spec {
    // As `base.ct.label` builds a label, from a name instead of an enum literal.
    var s = spec_zig.row(.{}, .{Spec{ .kind = .label, .bind = field, .style = .{ .role = .label } }});
    s.id = id;
    return s;
}

// ---- look -------------------------------------------------------------------------------------

/// The bar.
pub fn barStyle(th: *const Theme) Style {
    _ = th;
    return .{ .dir = .x };
}

/// A button of the bar.
pub fn buttonStyle(th: *const Theme, open: bool, hovered: bool) Style {
    _ = th;
    _ = open;
    _ = hovered;
    return .{ .dir = .x };
}

/// The layer the lists float in: out of flow, at the page's origin.
pub fn layerStyle() Style {
    return .{ .float = true };
}

// ---- runtime front end ------------------------------------------------------------------------

/// The bar named `name`, in the page's flow, showing `texts` (one per button).
pub fn bar(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: BarDef, st: *BarState, texts: []const []const u8) void {
    std.debug.assert(texts.len == def.names.len);
    const inter = &f.ctx.inter;
    _ = f.open(.from(partName(name, "bar")), barStyle(th));
    inline for (def.names, 0..) |n, i| {
        const bid: Id = .from(partName(name, n));
        _ = f.open(bid, buttonStyle(th, st.open == i, inter.response(bid).hovered));
        _ = base.label(f, th, texts[i]);
        f.close();
    }
    f.close();
}

/// The open menu's list (and submenu) of bar `name`, `texts` holding each menu's labels in
/// menu.zig's one sequence. Call it at the root's depth, after the rest of the page, so the
/// list is drawn on top.
pub fn menus(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: BarDef, st: *const BarState, texts: []const []const []const u8) void {
    _ = f.open(.none, layerStyle());
    inline for (def.names, def.menus, 0..) |n, m, i| if (st.open == i) {
        const mid = comptime partName(name, n);
        _ = f.open(.from(partName(mid, "panel")), menu.listStyle(th, f.lastRect(.from(mid))));
        inline for (0..m.items.len) |k| buildItem(f, th, mid, m, st.menu, k, texts[i][k]);
        f.close();
        if (m.sub_at) |at| if (st.menu.sub) {
            _ = f.open(.from(partName(mid, "sub")), menu.subStyle(th, f.lastRect(.from(partName(mid, m.items[at])))));
            inline for (m.items.len..comptime m.count()) |k| buildItem(f, th, mid, m, st.menu, k, texts[i][k]);
            f.close();
        };
    };
    f.close();
}

fn buildItem(f: *Frame, th: *const Theme, comptime mid: []const u8, comptime m: menu.Def, ms: menu.MenuState, comptime k: u8, text: []const u8) void {
    _ = f.open(.from(partName(mid, m.name(k))), menu.itemStyle(th, menu.highlighted(m, ms, k)));
    _ = base.label(f, th, text);
    f.close();
}

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;

const edit_menu: menu.Def = .{ .items = &.{ "undo", "redo" } };
const bar_def: BarDef = .{ .names = &.{ "file", "edit" }, .menus = &.{ menu.file_menu, edit_menu } };
const bar_texts = [_][]const u8{ "File", "Edit" };
const item_texts = [_][]const []const u8{ &menu.file_texts, &.{ "Undo", "Redo" } };

/// The test page: the bar above a status label, and its menus.
fn Page(comptime th: Theme) type {
    return struct {
        pub const App = struct {
            bar: BarState = .{},

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, .{});
                bar(f, &th, "main", bar_def, &app.bar, &bar_texts);
                _ = base.label(f, &th, "Ready");
                menus(f, &th, "main", bar_def, &app.bar, &item_texts);
                f.close();
            }
        };

        pub const State = struct {
            bar: BarState = .{},
            file: []const u8 = "File",
            edit: []const u8 = "Edit",
            status: []const u8 = "Ready",
            new: []const u8 = "New",
            open: []const u8 = "Open",
            recent: []const u8 = "Recent",
            quit: []const u8 = "Quit",
            scene1: []const u8 = "Scene 1",
            scene2: []const u8 = "Scene 2",
            undo: []const u8 = "Undo",
            redo: []const u8 = "Redo",
        };
        pub const B = MenuBar(th, .main, .bar, bar_def);
        pub const spec = spec_zig.col(.{}, .{ B.row(), base.ct.label(th, .status), B.layer() });
        pub const Ui = popover.ComptimePage(State, spec, th, B);
        pub const limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

/// Sets the bar's state in both front ends of `h` and builds two frames (the second sees the
/// first's rects); returns the second's tree.
fn setBar(h: anytype, st: BarState) !*const Tree {
    const in: Input = .{ .viewport = .{ 400, 300 } };
    h.app.bar = st;
    h.ui.signals.set(.bar, st);
    _ = try h.frame(&in);
    return (try h.frame(&in)).runtime.tree;
}

test "MenuBar: the page agrees in both front ends, closed and with each menu open" {
    const h = &harness;
    h.init();
    // root, page, bar, two buttons and their labels, status, layer
    var t = try setBar(h, .{});
    try testing.expectEqual(@as(u32, 9), t.len);
    t = try setBar(h, .{ .open = 0, .menu = .{ .open = true } });
    try testing.expectEqual(@as(u32, 9 + 1 + 8), t.len);
    try testing.expectEqual(t.rect(t.find(.from("main_file"))).x0, t.rect(t.find(.from("main_file_panel"))).x0);
    t = try setBar(h, .{ .open = 0, .menu = .{ .open = true, .sub = true } });
    try testing.expectEqual(@as(u32, 9 + 1 + 8 + 1 + 4), t.len);
    t = try setBar(h, .{ .open = 1, .menu = .{ .open = true } });
    try testing.expectEqual(@as(u32, 9 + 1 + 4), t.len);
    try testing.expectEqual(t.rect(t.find(.from("main_edit"))).x0, t.rect(t.find(.from("main_edit_panel"))).x0);
}

test "checkBar: the state field, one menu per button, the label fields" {
    try testing.expectEqual(null, comptime checkBar(Default.State, bar_def, "bar"));
    try testing.expectEqualStrings("menu bar: field 'bar' must be a menubar.BarState", comptime checkBar(struct { bar: u8 }, bar_def, "bar").?);
    try testing.expectEqualStrings("menu bar: one menu per button, at least one", comptime checkBar(Default.State, .{ .names = &.{"file"}, .menus = &.{} }, "bar").?);
    try testing.expectEqualStrings("menu bar: button 'view' needs a string field of its name", comptime checkBar(Default.State, .{ .names = &.{"view"}, .menus = &.{edit_menu} }, "bar").?);
    try testing.expectEqualStrings("menu bar: item 'paste' needs a string field of its name", comptime checkBar(Default.State, .{ .names = &.{"edit"}, .menus = &.{.{ .items = &.{"paste"} }} }, "bar").?);
}

test {
    std.testing.refAllDecls(@This());
}
