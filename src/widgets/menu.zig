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
const Tree = @import("../core/tree.zig").Tree;
const none = types.none;
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
        pub fn button(comptime text: anytype) Spec {
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

        /// The trigger, the scrim and the items' responses, then the keys, through `advance`.
        pub fn step(sig: anytype, v: anytype) void {
            var hits: Hits = .{ .toggle = v.responseOf(id).clicked, .outside = v.responseOf(partName(id, "scrim")).pressed };
            inline for (0..comptime def.count()) |k| hits.add(k, v.responseOf(partName(id, def.name(k))));
            sig.set(menu, advance(def, @field(sig.state, menu_name), hits, v.in.events));
        }

        pub fn part(comptime n: Spec, st: anytype, v: anytype) ?Part {
            const ms: MenuState = @field(st, menu_name);
            if (comptime named(n, partName(id, "scrim"))) {
                if (!ms.open) return null;
                return .{ .style = popover.scrimStyle(v.in.viewport) };
            }
            if (comptime named(n, partName(id, "panel"))) return .{ .style = listStyle(&th, v.last.of(id)), .role = .menu };
            if (comptime named(n, partName(id, "sub"))) {
                if (!ms.sub) return null;
                return .{ .style = subStyle(&th, v.last.of(partName(id, def.items[def.sub_at.?]))), .role = .menu };
            }
            if (comptime itemOf(def, id, n)) |k| return .{ .style = itemStyle(&th, highlighted(def, ms, k)), .role = .menu_item };
            return popover.plainPart(th, n, v.response);
        }
    };
}

/// Whether item `k` (in the one sequence) is highlighted: the active item of its list.
pub fn highlighted(comptime def: Def, st: MenuState, k: u8) bool {
    const n_top: u8 = def.items.len;
    if (k < n_top) return st.active == k;
    return st.sub and st.sub_active == k - n_top;
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

// ---- behaviour: a pure function of the state and what happened --------------------------------

/// What the pointer did to a menu this frame, from its widgets' responses.
pub const Hits = struct {
    /// The trigger was clicked.
    toggle: bool = false,
    /// The pointer went down on the scrim, outside the lists.
    outside: bool = false,
    /// The item clicked, in the one sequence, or `no_item`.
    clicked: u8 = no_item,
    /// The item under the pointer, or `no_item`.
    hovered: u8 = no_item,

    /// Notes item `k`'s response.
    pub fn add(h: *Hits, k: u8, r: Response) void {
        if (r.clicked) h.clicked = k;
        if (r.hovered) h.hovered = k;
    }
};

/// One frame of a menu (APG menu button and menu). The trigger's click toggles it, opening on
/// the first item; a press outside closes it. While it is open: the pointer reaching an item
/// highlights it (reaching the submenu's item opens the submenu); Down and Up move the
/// highlight in its list, wrapping, Home and End go to the ends; Right on the submenu's item
/// opens the submenu and Left closes it; Enter, Space or a click choose the highlighted item,
/// which closes the menu (or opens the submenu, for its item); Escape closes the submenu, else
/// the menu. Keys are read in order; a closed menu ignores them.
pub fn advance(comptime def: Def, st: MenuState, hits: Hits, evs: []const Input.Event) MenuState {
    const n_top: u8 = def.items.len;
    const n_sub: u8 = def.sub.len;
    const sub_at: u8 = def.sub_at orelse no_item;
    var s = st;
    s.chosen = 0;
    if (hits.toggle) s = if (st.open) .{} else .{ .open = true };
    if (hits.outside) return .{};
    if (!s.open) return s;
    if (hits.hovered != s.hover) {
        const k = hits.hovered;
        if (k < n_top) {
            s.active = k;
            s.sub = k == sub_at;
            s.sub_active = 0;
        } else if (k != no_item) s.sub_active = k - n_top;
        s.hover = k;
    }
    if (hits.clicked != no_item) s = choose(sub_at, s, hits.clicked);
    for (evs) |e| {
        if (!s.open) break;
        if (e.kind != .press and e.kind != .repeat) continue;
        const k = popover.keys;
        const in_sub = s.sub;
        const n = if (in_sub) n_sub else n_top;
        const at = if (in_sub) &s.sub_active else &s.active;
        switch (e.code) {
            k.down => at.* = (at.* + 1) % n,
            k.up => at.* = (at.* + n - 1) % n,
            k.home => at.* = 0,
            k.end => at.* = n - 1,
            k.right => if (!in_sub and s.active == sub_at) {
                s.sub = true;
                s.sub_active = 0;
            },
            k.left => s.sub = false,
            k.escape => s = if (in_sub) blk: {
                var t = s;
                t.sub = false;
                break :blk t;
            } else .{},
            k.enter, k.space => s = choose(sub_at, s, if (in_sub) n_top + s.sub_active else s.active),
            else => {},
        }
    }
    return s;
}

/// Choosing item `k`: the submenu's item opens the submenu, any other closes the menu and is
/// reported in `chosen`.
fn choose(sub_at: u8, st: MenuState, k: u8) MenuState {
    if (k != sub_at) return .{ .chosen = k + 1 };
    var s = st;
    s.active = k;
    s.sub = true;
    s.sub_active = 0;
    return s;
}

// ---- accessibility ------------------------------------------------------------------------------

/// The semantics of menu `name` the tree's columns cannot hold, written into `s` after
/// `Semantics.clear` and before `a11y.names` and `a11y.states`. The roles are in the columns:
/// the lists are `menu`, the items `menu_item` (named by their text, value 0), the trigger a
/// button. Here: the trigger is expandable, expanded while the list is in `t`
/// (`aria-expanded`), and names the list (`aria-labelledby`); the submenu's item likewise for
/// the submenu; the highlighted item is `selected`. Works on either front end's tree.
pub fn semantics(t: *const Tree, s: *a11y.Semantics, comptime name: []const u8, comptime def: Def, st: MenuState) void {
    expands(t, s, .from(name), .from(partName(name, "panel")));
    if (def.sub_at) |at| expands(t, s, .from(partName(name, def.items[at])), .from(partName(name, "sub")));
    inline for (0..comptime def.count()) |k| {
        const row = t.find(.from(partName(name, def.name(k))));
        if (row != none and highlighted(def, st, k)) s.c.state[row] |= a11y.State.bitsOf(.{ .selected = true });
    }
}

/// `opener` is expandable, expanded while `popup` is in `t`, and names it.
fn expands(t: *const Tree, s: *a11y.Semantics, opener: Id, popup: Id) void {
    const o = t.find(opener);
    if (o == none) return;
    const p = t.find(popup);
    s.c.state[o] |= a11y.State.bitsOf(.{ .expandable = true, .expanded = p != none });
    if (p != none) s.c.labelled_by[p] = o;
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
    // Every response is asked for before anything is built, so the state the rows show is
    // the frame's final state, as in the comptime front end.
    const inter = &f.ctx.inter;
    var hits: Hits = .{ .toggle = inter.response(.from(name)).clicked, .outside = inter.response(.from(partName(name, "scrim"))).pressed };
    inline for (0..comptime def.count()) |k| hits.add(k, inter.response(.from(partName(name, def.name(k)))));
    st.* = advance(def, st.*, hits, f.in.events);
    if (!st.open) return st.chosen;
    _ = f.interact(f.open(.from(partName(name, "scrim")), popover.scrimStyle(f.in.viewport)), popover.overlay_sense);
    const list = f.open(.from(partName(name, "panel")), listStyle(th, f.lastRect(.from(name))));
    _ = f.interact(list, popover.overlay_sense);
    f.tree().c.role[list.ix()] = @backingInt(a11y.Role.menu);
    inline for (0..def.items.len) |k| buildItem(f, th, name, def, st, k, texts[k]);
    f.close();
    if (def.sub_at) |at| if (st.sub) {
        const sub = f.open(.from(partName(name, "sub")), subStyle(th, f.lastRect(.from(partName(name, def.items[at])))));
        _ = f.interact(sub, popover.overlay_sense);
        f.tree().c.role[sub.ix()] = @backingInt(a11y.Role.menu);
        inline for (def.items.len..comptime def.count()) |k| buildItem(f, th, name, def, st, k, texts[k]);
        f.close();
    };
    f.close();
    return st.chosen;
}

fn buildItem(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: Def, st: *const MenuState, comptime k: u8, text: []const u8) void {
    const row = f.open(.from(partName(name, def.name(k))), itemStyle(th, highlighted(def, st.*, k)));
    _ = f.interact(row, popover.overlay_sense);
    f.tree().c.role[row.ix()] = @backingInt(a11y.Role.menu_item);
    _ = base.label(f, th, text);
    f.close();
}

// ---- example page, replay and golden frames ---------------------------------------------------

/// The example's menu: File with New, Open, Recent (a submenu of two scenes) and Quit.
pub const file_menu: Def = .{ .items = &.{ "new", "open", "recent", "quit" }, .sub_at = 2, .sub = &.{ "scene1", "scene2" } };
pub const file_texts = [_][]const u8{ "New", "Open", "Recent", "Quit", "Scene 1", "Scene 2" };

/// The example page: a toolbar with the File button and a label, and its menu, in both front
/// ends, in theme `th`. The tests and the golden images (tools/golden/) run it.
pub fn Example(comptime th: Theme) type {
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

/// Input for `Example(.default)` at 800 x 600, one commented line per frame.
pub const replay = @embedFile("testdata/menu.replay");

/// The frames of `replay` kept as golden images, by name (tools/golden/ref/widgets/<name>.png).
pub const golden_frames = .{
    .{ "menu-open", 2 },
    .{ "menu-keyed", 4 },
    .{ "menu-sub", 6 },
    .{ "menu-closed", 8 },
};

/// What tools/golden/ dumps: the page's harness over `replay`.
pub const golden = struct {
    pub const Run = Example(.default).Run;
    pub const src = replay;
    pub const frames = golden_frames;
};

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;
const Page = Example;

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

test "Menu: the example replay gives the same frames in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var r: Replay = .{ .src = replay };
    var st: [14]MenuState = undefined;
    while (try r.next(buf)) |in| {
        const k = h.frames;
        const out = try h.frame(in);
        const t = out.runtime.tree;
        try testing.expectEqual(h.app.menu, h.ui.signals.state.menu);
        st[k] = h.app.menu;
        if (k == 6) {
            // The rects the replay's comments give.
            const want = [_]struct { []const u8, Rect }{
                .{ "file", .{ .x0 = 8, .y0 = 8, .x1 = 58, .y1 = 42 } },
                .{ "file_panel", .{ .x0 = 8, .y0 = 48, .x1 = 80, .y1 = 172 } },
                .{ "file_open", .{ .x0 = 11, .y0 = 81, .x1 = 77, .y1 = 110 } },
                .{ "file_sub", .{ .x0 = 80, .y0 = 107, .x1 = 161, .y1 = 172 } },
                .{ "file_scene2", .{ .x0 = 83, .y0 = 140, .x1 = 158, .y1 = 169 } },
            };
            for (want) |w| try testing.expectEqual(w[1], t.rect(t.find(.hash(w[0]))));
        }
    }
    try testing.expectEqual(@as(u32, 14), h.frames);
    try testing.expect(!st[1].open and st[2].open and st[2].active == 0);
    try testing.expectEqual(@as(u8, 1), st[3].active);
    try testing.expectEqual(@as(u8, 2), st[4].active);
    try testing.expect(st[5].sub and st[6].sub_active == 1);
    try testing.expectEqual(MenuState{ .chosen = 6 }, st[8]);
    try testing.expect(st[10].open and !st[10].sub);
    try testing.expect(st[11].sub and st[11].active == 2);
    try testing.expect(st[12].open and !st[12].sub);
    try testing.expectEqual(MenuState{}, st[13]);
}

test "golden_frames: name frames the replay has" {
    inline for (golden_frames) |g| try testing.expect(g[1] < 14);
}

test "advance: keys move, open the submenu, choose and close" {
    const k = popover.keys;
    const press = struct {
        fn ev(comptime codes: []const u8) [codes.len]Input.Event {
            var out: [codes.len]Input.Event = undefined;
            for (&out, codes) |*e, c| e.* = .{ .kind = .press, .code = c };
            return out;
        }
    }.ev;
    var st: MenuState = advance(file_menu, .{}, .{ .toggle = true }, &.{});
    try testing.expectEqual(MenuState{ .open = true }, st);
    st = advance(file_menu, st, .{}, &press(&.{ k.down, k.down, k.down, k.down, k.down }));
    try testing.expectEqual(@as(u8, 1), st.active); // wrapped past Quit
    st = advance(file_menu, st, .{}, &press(&.{ k.end, k.up, k.right }));
    try testing.expect(st.sub and st.active == 2 and st.sub_active == 0);
    st = advance(file_menu, st, .{}, &press(&.{ k.up, k.escape }));
    try testing.expect(st.open and !st.sub and st.sub_active == 1);
    st = advance(file_menu, st, .{}, &press(&.{ k.enter, k.down, k.space }));
    try testing.expectEqual(MenuState{ .chosen = 6 }, st); // Recent opened the submenu, Scene 2 chosen
    st = advance(file_menu, st, .{}, &press(&.{k.down}));
    try testing.expectEqual(MenuState{}, st); // closed: keys ignored, chosen is one frame
    // The pointer: reaching an item highlights it once; a click chooses.
    st = advance(file_menu, .{ .open = true }, .{ .hovered = 3 }, &.{});
    try testing.expectEqual(@as(u8, 3), st.active);
    st = advance(file_menu, st, .{ .hovered = 3 }, &press(&.{k.up}));
    try testing.expectEqual(@as(u8, 2), st.active);
    st = advance(file_menu, st, .{ .hovered = 2 }, &.{});
    try testing.expect(st.sub);
    st = advance(file_menu, st, .{ .hovered = 4, .clicked = 4 }, &.{});
    try testing.expectEqual(@as(u8, 5), st.chosen);
    try testing.expectEqual(MenuState{}, advance(file_menu, .{ .open = true }, .{ .outside = true }, &.{}));
    try testing.expectEqual(MenuState{ .open = true }, advance(file_menu, .{ .open = true, .active = 1 }, .{}, &press(&.{ k.left, k.home })));
}

const Aim = union(enum) { part: []const u8, at: [2]f32 };
const Step = struct { aim: Aim, left: bool = false, key: ?u8 = null };

/// Runs `script` through both front ends, aiming at last frame's rects, with the menu state
/// equal in both after every step; returns the state and what was chosen after each step.
fn runScript(comptime n: usize, script: [n]Step) ![n]MenuState {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 400, 300 } };
    var ev: [1]Input.Event = undefined;
    var last = (try h.frame(&in)).runtime.tree;
    var out: [n]MenuState = undefined;
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
        try testing.expectEqual(h.app.menu, h.ui.signals.state.menu);
        try testing.expectEqual(h.app.chosen, h.app.menu.chosen);
        o.* = h.app.menu;
    }
    return out;
}

test "Menu: pointer and keys in both front ends" {
    const k = popover.keys;
    const s = try runScript(12, .{
        .{ .aim = .{ .part = "file" }, .left = true },
        .{ .aim = .{ .part = "file" } }, // open
        .{ .aim = .{ .part = "file_open" } }, // highlight Open
        .{ .aim = .{ .part = "file_open" }, .key = k.down }, // Recent
        .{ .aim = .{ .part = "file_open" }, .key = k.right }, // submenu
        .{ .aim = .{ .part = "file_scene2" } }, // highlight Scene 2
        .{ .aim = .{ .part = "file_scene2" }, .left = true },
        .{ .aim = .{ .part = "file_scene2" } }, // chosen: item 5, closed
        .{ .aim = .{ .part = "file" }, .left = true },
        .{ .aim = .{ .part = "file" } }, // open again
        .{ .aim = .{ .part = "file" }, .key = k.escape }, // closed
        .{ .aim = .{ .at = .{ 390, 290 } } },
    });
    try testing.expect(!s[0].open and s[1].open);
    try testing.expectEqual(@as(u8, 1), s[2].active);
    try testing.expectEqual(@as(u8, 2), s[3].active);
    try testing.expect(s[4].sub and !s[3].sub);
    try testing.expectEqual(@as(u8, 1), s[5].sub_active);
    try testing.expectEqual(MenuState{ .chosen = 6 }, s[7]);
    try testing.expect(s[9].open and !s[10].open);
    try testing.expectEqual(MenuState{}, s[11]);
}

var sem: [2]popover.Semantic(64) = .{ .{}, .{} };

test "Menu: lists are menus named by their openers, items menu items; the same in both front ends" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 400, 300 } };
    _ = try h.frame(&in);
    const st: MenuState = .{ .open = true, .sub = true, .active = 2, .sub_active = 1 };
    h.app.menu = st;
    h.ui.signals.set(.menu, st);
    _ = try h.frame(&in);
    const pair = try h.frame(&in);
    const rt = pair.runtime;
    const cp = pair.comptime_;
    semantics(rt.tree, sem[0].begin(), "file", file_menu, h.app.menu);
    semantics(cp.tree, sem[1].begin(), "file", file_menu, h.ui.signals.state.menu);
    const e = sem[0].finish(rt.tree, rt.texts, h.ctx.strings[h.ctx.cur].buf);
    try testing.expect(popover.sameSemantics(e, sem[1].finish(cp.tree, &h.ui.tables.tx, h.ui.tables.strings.buf)));
    const row = struct {
        fn of(x: *const a11y.Export, t: *const Tree, comptime id: []const u8) u32 {
            return popover.exportRow(x, t.find(.from(id)));
        }
    }.of;
    const t = rt.tree;
    const H = std.hash.Fnv1a_32;
    try testing.expectEqual(@backingInt(a11y.Role.menu), e.c.role[row(e, t, "file_panel")]);
    try testing.expectEqual(H.hash("File"), e.c.name_hash[row(e, t, "file_panel")]);
    try testing.expectEqual(@backingInt(a11y.Role.menu), e.c.role[row(e, t, "file_sub")]);
    try testing.expectEqual(H.hash("Recent"), e.c.name_hash[row(e, t, "file_sub")]);
    try testing.expectEqual(@backingInt(a11y.Role.menu_item), e.c.role[row(e, t, "file_quit")]);
    try testing.expectEqual(H.hash("Quit"), e.c.name_hash[row(e, t, "file_quit")]);
    try testing.expectEqual(@as(f32, 0), e.c.value[row(e, t, "file_quit")]);
    const open_state = a11y.State.bitsOf(.{ .expandable = true, .expanded = true });
    try testing.expectEqual(open_state, e.c.state[row(e, t, "file")]);
    try testing.expectEqual(open_state | a11y.State.bitsOf(.{ .selected = true }), e.c.state[row(e, t, "file_recent")]);
    try testing.expectEqual(a11y.State.bitsOf(.{ .selected = true }), e.c.state[row(e, t, "file_scene2")]);
    try testing.expectEqual(@as(u8, 0), e.c.state[row(e, t, "file_scene1")]);
    // The list has its four items as children.
    try testing.expectEqual(@as(u32, 4), e.c.kids[row(e, t, "file_panel")]);
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
