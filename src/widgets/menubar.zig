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

        /// Every widget's response, then the keys, through `advance`.
        pub fn step(sig: anytype, v: anytype) void {
            const bs: BarState = @field(sig.state, field_name);
            var hits: BarHits = .{ .inside = v.responseOf(partName(id, "bar")).pressed };
            inline for (def.names, def.menus, 0..) |mn, m, i| {
                const mid = comptime partName(id, mn);
                hits.addButton(i, v.responseOf(mid));
                hits.inside = hits.inside or v.responseOf(partName(mid, "panel")).pressed;
                if (m.sub.len != 0) hits.inside = hits.inside or v.responseOf(partName(mid, "sub")).pressed;
                inline for (0..comptime m.count()) |k| hits.addItem(bs.open == i, k, v.responseOf(partName(mid, m.name(k))));
            }
            sig.set(field, advance(def, bs, hits, v.in));
        }

        pub fn part(comptime n: Spec, st: anytype, v: anytype) ?Part {
            const bs: BarState = @field(st, field_name);
            if (comptime named(n, partName(id, "bar"))) return .{ .style = barStyle(&th), .role = .menu_bar };
            inline for (def.names, def.menus, 0..) |mn, m, i| {
                const mid = comptime partName(id, mn);
                const open = bs.open == i;
                if (comptime named(n, mid)) return .{ .style = buttonStyle(&th, open, v.response.hovered), .role = .menu_item };
                if (comptime named(n, partName(mid, "panel"))) {
                    if (!open) return null;
                    return .{ .style = menu.listStyle(&th, v.last.of(mid)), .role = .menu };
                }
                if (comptime m.sub_at != null and named(n, partName(mid, "sub"))) {
                    if (!open or !bs.menu.sub) return null;
                    return .{ .style = menu.subStyle(&th, v.last.of(partName(mid, m.items[m.sub_at.?]))), .role = .menu };
                }
                inline for (0..comptime m.count()) |k| {
                    if (comptime named(n, partName(mid, m.name(k)))) return .{ .style = menu.itemStyle(&th, menu.highlighted(m, bs.menu, k)), .role = .menu_item };
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

/// The bar: a panel-coloured strip across the page, half a gap of padding around its buttons.
pub fn barStyle(th: *const Theme) Style {
    return .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(th.gap * 0.5), .cross = .center, .fill = th.panel };
}

/// A button of the bar: padded like a menu item, filled while its menu is open or the pointer
/// is on it (`menu.itemFills`, indexed by either).
pub fn buttonStyle(th: *const Theme, open: bool, hovered: bool) Style {
    var s = menu.itemStyle(th, open or hovered);
    s.size = .{ .fit, .fit };
    return s;
}

/// The layer the lists float in: out of flow, at the page's origin.
pub fn layerStyle() Style {
    return .{ .float = true };
}

// ---- behaviour: a pure function of the state and what happened --------------------------------

/// What the pointer did to a menu bar this frame, from its widgets' responses.
pub const BarHits = struct {
    /// The button clicked, or `menu.no_item`.
    clicked: u8 = no_item,
    /// The button under the pointer, or `menu.no_item`.
    hovered: u8 = no_item,
    /// The left button went down on one of the bar's widgets.
    inside: bool = false,
    /// The open menu's items, as `menu.Hits`.
    menu: menu.Hits = .{},

    /// Notes button `i`'s response.
    pub fn addButton(h: *BarHits, i: u8, r: Response) void {
        if (r.clicked) h.clicked = i;
        if (r.hovered) h.hovered = i;
        h.inside = h.inside or r.pressed;
    }

    /// Notes the response of item `k` of a menu, which is the open one when `open`.
    pub fn addItem(h: *BarHits, open: bool, k: u8, r: Response) void {
        h.inside = h.inside or r.pressed;
        if (open) h.menu.add(k, r);
    }
};

/// One frame of a menu bar (APG menubar). A button's click opens its menu, or closes it if it
/// is the open one; while a menu is open, the pointer reaching another button opens that
/// one's instead. A press outside the bar's widgets closes it. The open menu follows
/// `menu.advance` (its pointer hits, then each key), except that Right and Left, outside a
/// submenu, open the next and previous menu (wrapping), Right only where it does not open
/// a submenu. Choosing an item or Escape closes the menu; `from` and `menu.chosen` say what
/// was chosen, for one frame.
pub fn advance(comptime def: BarDef, st: BarState, hits: BarHits, in: *const Input) BarState {
    const n: u8 = def.names.len;
    var s = st;
    s.from = no_item;
    s.menu.chosen = 0;
    s.down = in.buttons.left;
    const closed: BarState = .{ .hover = s.hover, .down = s.down };
    if (in.buttons.left and !st.down and !hits.inside) s = closed;
    if (hits.clicked != no_item) {
        const k = hits.clicked;
        s = if (s.open == k) closed else .{ .open = k, .menu = .{ .open = true }, .hover = s.hover, .down = s.down };
    }
    if (hits.hovered != s.hover) {
        const k = hits.hovered;
        if (s.open != no_item and k != no_item and k != s.open) {
            s.open = k;
            s.menu = .{ .open = true };
        }
        s.hover = k;
    }
    if (s.open == no_item) return s;
    // The pointer's hits on the items belong to the menu that was open last frame.
    if (s.open == st.open) s.menu = menuAdvance(def, s.open, s.menu, hits.menu, &.{});
    const k = popover.keys;
    for (in.events) |e| {
        if (!s.menu.open) break;
        if (e.kind != .press and e.kind != .repeat) continue;
        const next = e.code == k.right and !s.menu.sub and s.menu.active != subAt(def, s.open);
        const prev = e.code == k.left and !s.menu.sub;
        if (next or prev) {
            s.open = if (next) (s.open + 1) % n else (s.open + n - 1) % n;
            s.menu = .{ .open = true };
            continue;
        }
        s.menu = menuAdvance(def, s.open, s.menu, .{ .hovered = s.menu.hover }, (&e)[0..1]);
    }
    if (!s.menu.open) {
        s.from = if (s.menu.chosen != 0) s.open else no_item;
        s.open = no_item;
    }
    return s;
}

/// `menu.advance` for menu `i` of `def`, chosen at run time.
fn menuAdvance(comptime def: BarDef, i: u8, ms: menu.MenuState, hits: menu.Hits, evs: []const Input.Event) menu.MenuState {
    inline for (def.menus, 0..) |m, k| if (i == k) return menu.advance(m, ms, hits, evs);
    unreachable;
}

/// The submenu opener of menu `i` of `def`, or `menu.no_item`.
fn subAt(comptime def: BarDef, i: u8) u8 {
    inline for (def.menus, 0..) |m, k| if (i == k) return m.sub_at orelse no_item;
    unreachable;
}

// ---- accessibility ------------------------------------------------------------------------------

/// The semantics of menu bar `name` the tree's columns cannot hold, written into `s` after
/// `Semantics.clear` and before `a11y.names` and `a11y.states`. The roles are in the columns:
/// the bar is `menu_bar`, its buttons `menu_item` (named by their text, value 0), the lists
/// `menu` and their items `menu_item`. Here, per menu as `menu.semantics` writes it: each
/// button is expandable, expanded while its list is shown, and names it; the open menu's
/// highlighted item is `selected`.
pub fn semantics(t: *const Tree, s: *a11y.Semantics, comptime name: []const u8, comptime def: BarDef, st: BarState) void {
    inline for (def.names, def.menus, 0..) |n, m, i| {
        menu.semantics(t, s, comptime partName(name, n), m, if (st.open == i) st.menu else .{});
    }
}

// ---- runtime front end ------------------------------------------------------------------------

/// The bar named `name`, in the page's flow, showing `texts` (one per button).
pub fn bar(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: BarDef, st: *BarState, texts: []const []const u8) void {
    std.debug.assert(texts.len == def.names.len);
    // Every response is asked for before anything is built, so the rows show the frame's
    // final state, as in the comptime front end.
    const inter = &f.ctx.inter;
    const bar_id: Id = .from(partName(name, "bar"));
    var hits: BarHits = .{ .inside = inter.response(bar_id).pressed };
    inline for (def.names, def.menus, 0..) |n, m, i| {
        const mid = comptime partName(name, n);
        hits.addButton(i, inter.response(.from(mid)));
        hits.inside = hits.inside or inter.response(.from(partName(mid, "panel"))).pressed;
        if (m.sub.len != 0) hits.inside = hits.inside or inter.response(.from(partName(mid, "sub"))).pressed;
        inline for (0..comptime m.count()) |k| hits.addItem(st.open == i, k, inter.response(.from(partName(mid, m.name(k)))));
    }
    st.* = advance(def, st.*, hits, f.in);
    const b = f.open(bar_id, barStyle(th));
    _ = f.interact(b, popover.overlay_sense);
    role(f, b, .menu_bar);
    inline for (def.names, 0..) |n, i| {
        const bid: Id = .from(partName(name, n));
        const button = f.open(bid, buttonStyle(th, st.open == i, inter.response(bid).hovered));
        _ = f.interact(button, .button);
        role(f, button, .menu_item);
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
        const list = f.open(.from(partName(mid, "panel")), menu.listStyle(th, f.lastRect(.from(mid))));
        _ = f.interact(list, popover.overlay_sense);
        role(f, list, .menu);
        inline for (0..m.items.len) |k| buildItem(f, th, mid, m, st.menu, k, texts[i][k]);
        f.close();
        if (m.sub_at) |at| if (st.menu.sub) {
            const sub = f.open(.from(partName(mid, "sub")), menu.subStyle(th, f.lastRect(.from(partName(mid, m.items[at])))));
            _ = f.interact(sub, popover.overlay_sense);
            role(f, sub, .menu);
            inline for (m.items.len..comptime m.count()) |k| buildItem(f, th, mid, m, st.menu, k, texts[i][k]);
            f.close();
        };
    };
    f.close();
}

fn role(f: *Frame, n: types.Node, r: a11y.Role) void {
    f.tree().c.role[n.ix()] = @backingInt(r);
}

fn buildItem(f: *Frame, th: *const Theme, comptime mid: []const u8, comptime m: menu.Def, ms: menu.MenuState, comptime k: u8, text: []const u8) void {
    const row = f.open(.from(partName(mid, m.name(k))), menu.itemStyle(th, menu.highlighted(m, ms, k)));
    _ = f.interact(row, popover.overlay_sense);
    role(f, row, .menu_item);
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

test "barStyle, buttonStyle: the theme's tokens" {
    const th: Theme = .default;
    try testing.expectEqual(th.panel, barStyle(&th).fill);
    try testing.expectEqual([4]f32{ 3, 3, 3, 3 }, barStyle(&th).pad);
    try testing.expectEqual(types.Color.transparent, buttonStyle(&th, false, false).fill);
    try testing.expectEqual(th.control_hot, buttonStyle(&th, true, false).fill);
    try testing.expectEqual(th.control_hot, buttonStyle(&th, false, true).fill);
    try testing.expectEqual([4]f32{ th.pad, th.gap, th.pad, th.gap }, buttonStyle(&th, false, false).pad);
}

const light: Theme = .{ .panel = .rgb(240, 240, 240), .control_hot = .rgb(180, 180, 190), .text = .rgb(20, 20, 20), .pad = 12, .gap = 10, .radius = 0 };

test "MenuBar: another theme restyles both front ends alike" {
    const S = struct {
        var h: Page(light).Run = .{};
    };
    S.h.init();
    const t = try setBar(&S.h, .{ .open = 1, .menu = .{ .open = true } });
    try testing.expectEqual(light.control_hot.bitsOf(), t.c.look[t.find(.from("main_edit"))].fill);
    try testing.expectEqual(light.panel.bitsOf(), t.c.look[t.find(.from("main_bar"))].fill);
    // The list hangs th.gap below its button.
    try testing.expectEqual(t.rect(t.find(.from("main_edit"))).y1 + 10, t.rect(t.find(.from("main_edit_panel"))).y0);
}

test "advance: buttons, hover between menus, Left and Right, choosing" {
    const k = popover.keys;
    const in = struct {
        fn keys(comptime codes: []const u8) Input {
            const evs = comptime blk: {
                var out: [codes.len]Input.Event = undefined;
                for (&out, codes) |*e, c| e.* = .{ .kind = .press, .code = c };
                break :blk out;
            };
            return .{ .events = &evs };
        }
    }.keys;
    const idle: Input = .{};
    var s = advance(bar_def, .{}, .{ .clicked = 0, .hovered = 0 }, &idle);
    try testing.expectEqual(@as(u8, 0), s.open);
    try testing.expect(s.menu.open);
    // The pointer reaching Edit while File is open opens Edit.
    s = advance(bar_def, s, .{ .hovered = 1 }, &idle);
    try testing.expectEqual(@as(u8, 1), s.open);
    // Right wraps to File; Down, Down: Recent; Right there opens the submenu, not the next menu.
    s = advance(bar_def, s, .{ .hovered = 1 }, &in(&.{ k.right, k.down, k.down, k.right }));
    try testing.expect(s.open == 0 and s.menu.sub and s.menu.active == 2);
    // Left closes the submenu, Left again goes to Edit.
    s = advance(bar_def, s, .{ .hovered = 1 }, &in(&.{ k.left, k.left }));
    try testing.expect(s.open == 1 and !s.menu.sub and s.menu.active == 0);
    // Enter chooses Undo: closed, chosen from Edit.
    s = advance(bar_def, s, .{ .hovered = 1 }, &in(&.{k.enter}));
    try testing.expectEqual(no_item, s.open);
    try testing.expectEqual(@as(u8, 1), s.from);
    try testing.expectEqual(@as(u8, 1), s.menu.chosen);
    // One frame only.
    s = advance(bar_def, s, .{ .hovered = 1 }, &idle);
    try testing.expect(s.from == no_item and s.menu.chosen == 0);
    // Clicking the open menu's button closes it; a press outside closes it too.
    s = advance(bar_def, s, .{ .clicked = 1, .hovered = 1 }, &idle);
    try testing.expectEqual(@as(u8, 1), s.open);
    s = advance(bar_def, s, .{ .clicked = 1, .hovered = 1 }, &idle);
    try testing.expectEqual(no_item, s.open);
    s = advance(bar_def, s, .{ .clicked = 0, .hovered = 0 }, &idle);
    const down: Input = .{ .buttons = .{ .left = true } };
    try testing.expectEqual(@as(u8, 0), advance(bar_def, s, .{ .hovered = 0, .inside = true }, &down).open);
    s = advance(bar_def, s, .{}, &down);
    try testing.expectEqual(no_item, s.open);
    try testing.expect(s.down);
}

const Aim = union(enum) { part: []const u8, at: [2]f32 };
const Step = struct { aim: Aim, left: bool = false, key: ?u8 = null };

/// Runs `script` through both front ends, aiming at last frame's rects, with the bar's state
/// equal in both after every step; returns the state after each step.
fn runScript(comptime n: usize, script: [n]Step) ![n]BarState {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 400, 300 } };
    var ev: [1]Input.Event = undefined;
    var last = (try h.frame(&in)).runtime.tree;
    var out: [n]BarState = undefined;
    for (script, &out) |st, *o| {
        in.pointer = switch (st.aim) {
            .at => |p| p,
            .part => |name| blk: {
                const r = last.rect(last.find(.hash(name)));
                break :blk .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
            },
        };
        in.buttons.left = st.left;
        in.events = &.{};
        if (st.key) |k| {
            ev[0] = .{ .kind = .press, .code = k };
            in.events = &ev;
        }
        last = (try h.frame(&in)).runtime.tree;
        try testing.expectEqual(h.app.bar, h.ui.signals.state.bar);
        o.* = h.app.bar;
    }
    return out;
}

test "MenuBar: pointer and keys in both front ends" {
    const k = popover.keys;
    const s = try runScript(10, .{
        .{ .aim = .{ .part = "main_file" }, .left = true },
        .{ .aim = .{ .part = "main_file" } }, // File open
        .{ .aim = .{ .part = "main_edit" } }, // Edit open
        .{ .aim = .{ .part = "main_edit" }, .key = k.left }, // File open
        .{ .aim = .{ .part = "main_file_quit" } }, // Quit highlighted
        .{ .aim = .{ .part = "main_file_quit" }, .left = true },
        .{ .aim = .{ .part = "main_file_quit" } }, // Quit chosen
        .{ .aim = .{ .part = "main_edit" }, .left = true },
        .{ .aim = .{ .part = "main_edit" } }, // Edit open
        .{ .aim = .{ .at = .{ 390, 290 } }, .left = true }, // press outside: closed
    });
    try testing.expectEqual(no_item, s[0].open);
    try testing.expectEqual(@as(u8, 0), s[1].open);
    try testing.expectEqual(@as(u8, 1), s[2].open);
    try testing.expectEqual(@as(u8, 0), s[3].open);
    try testing.expectEqual(@as(u8, 3), s[4].menu.active);
    try testing.expect(s[6].open == no_item and s[6].from == 0 and s[6].menu.chosen == 4);
    try testing.expectEqual(@as(u8, 1), s[8].open);
    try testing.expectEqual(no_item, s[9].open);
}

var sem: [2]popover.Semantic(64) = .{ .{}, .{} };

test "MenuBar: a menu bar of expandable menu items, the open one's list a menu; the same in both front ends" {
    const h = &harness;
    h.init();
    const st: BarState = .{ .open = 1, .menu = .{ .open = true, .active = 1 } };
    const t = try setBar(h, st);
    const rt_tree = t;
    const cp_tree = &h.ui.tables.t;
    semantics(rt_tree, sem[0].begin(), "main", bar_def, h.app.bar);
    semantics(cp_tree, sem[1].begin(), "main", bar_def, h.ui.signals.state.bar);
    const rt_texts = &h.ctx.texts[h.ctx.cur];
    const e = sem[0].finish(rt_tree, rt_texts, h.ctx.strings[h.ctx.cur].buf);
    try testing.expect(popover.sameSemantics(e, sem[1].finish(cp_tree, &h.ui.tables.tx, h.ui.tables.strings.buf)));
    const row = struct {
        fn of(x: *const a11y.Export, tr: *const Tree, comptime id: []const u8) u32 {
            return popover.exportRow(x, tr.find(.from(id)));
        }
    }.of;
    const H = std.hash.Fnv1a_32;
    const R = a11y.Role;
    try testing.expectEqual(@backingInt(R.menu_bar), e.c.role[row(e, t, "main_bar")]);
    try testing.expectEqual(@as(u32, 2), e.c.kids[row(e, t, "main_bar")]);
    try testing.expectEqual(@backingInt(R.menu_item), e.c.role[row(e, t, "main_file")]);
    try testing.expectEqual(H.hash("File"), e.c.name_hash[row(e, t, "main_file")]);
    try testing.expectEqual(a11y.State.bitsOf(.{ .expandable = true }), e.c.state[row(e, t, "main_file")]);
    try testing.expectEqual(a11y.State.bitsOf(.{ .expandable = true, .expanded = true }), e.c.state[row(e, t, "main_edit")]);
    try testing.expectEqual(@backingInt(R.menu), e.c.role[row(e, t, "main_edit_panel")]);
    try testing.expectEqual(H.hash("Edit"), e.c.name_hash[row(e, t, "main_edit_panel")]);
    try testing.expectEqual(a11y.State.bitsOf(.{ .selected = true }), e.c.state[row(e, t, "main_edit_redo")]);
    try testing.expectEqual(@as(f32, 0), e.c.value[row(e, t, "main_edit_redo")]);
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
