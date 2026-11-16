//! Context menu (tier 2): a menu that opens where the secondary button is pressed on a target,
//! the WAI-ARIA APG menu pattern opened from a context. Written against the public API of tiers
//! 0 and 1, after the recipe in base.zig, from menu.zig's parts (`menu.Def`, `menu.MenuState`,
//! `menu.advance`, the list and item looks): only how it opens and where its list sits differ.
//! The list floats under the root on a scrim, its corner at the point it was opened from
//! (`Input.Buttons.right`, prototype/ui.zig).
//!
//! Runtime: build the target (any widget with an id), then `show(...)` under the root after the
//! page.
//!
//! Comptime: `const C = ContextMenu(th, .ctx, .canvas, .ctx_state, def);` gives the spec builder
//! `C.layer` and the hooks `popover.ComptimePage(State, spec, th, C)` runs.

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

// ---- spec: what the context menu takes and keeps ---------------------------------------------

/// A context menu's state, owned by the application.
pub const ContextState = struct {
    /// The menu, as menu.zig keeps it.
    menu: menu.MenuState = .{},
    /// Where the list's corner sits: the point the menu was opened from.
    at: [2]f32 = .{ 0, 0 },
    /// The secondary button was down last frame, so a press is seen once.
    right: bool = false,
};

/// `null` if `State` can hold context menu `def` bound to `field`, else the compile error:
/// `field` must be a `ContextState`, and the items as `menu.checkMenu` wants them.
pub fn checkContext(comptime State: type, comptime def: menu.Def, comptime field: []const u8) ?[]const u8 {
    if (!@hasField(State, field)) return "context menu: state " ++ @typeName(State) ++ " has no field '" ++ field ++ "'";
    if (@FieldType(State, field) != ContextState) return "context menu: field '" ++ field ++ "' must be a contextmenu.ContextState";
    if (def.items.len == 0) return "context menu: no items";
    if (def.count() >= menu.no_item) return "context menu: too many items";
    if ((def.sub_at == null) != (def.sub.len == 0)) return "context menu: a submenu needs both sub_at and sub items";
    if (def.sub_at) |k| if (k >= def.items.len) return "context menu: sub_at is past the items";
    inline for (0..comptime def.count()) |k| {
        const n = comptime def.name(k);
        if (!@hasField(State, n) or @FieldType(State, n) != []const u8) return "context menu: item '" ++ n ++ "' needs a string field of its name";
    }
    return null;
}

/// Context menu `name` of the widget `target`, with items `def`, bound to the `ContextState`
/// field `field`, in theme `th`: its spec builder and the hooks `popover.ComptimePage` calls.
pub fn ContextMenu(comptime th: Theme, comptime name: @EnumLiteral(), comptime target: @EnumLiteral(), comptime field: @EnumLiteral(), comptime def: menu.Def) type {
    const id = @tagName(name);
    const field_name = @tagName(field);
    const target_name = @tagName(target);
    return struct {
        /// The scrim, the list and the submenu, shown while the menu is open, as menu.zig
        /// builds them. Put it last in the page's root so it is drawn above the rest.
        pub fn layer() Spec {
            return menu.Menu(th, name, field, def).layer();
        }

        pub fn check(comptime State: type) ?[]const u8 {
            return checkContext(State, def, field_name);
        }

        /// The target's rect, the scrim's and the items' responses and the keys, through
        /// `advance`.
        pub fn step(sig: anytype, v: anytype) void {
            var hits: menu.Hits = .{ .outside = v.responseOf(partName(id, "scrim")).pressed };
            inline for (0..comptime def.count()) |k| hits.add(k, v.responseOf(partName(id, def.name(k))));
            sig.set(field, advance(def, @field(sig.state, field_name), v.last.of(target_name), hits, v.in));
        }

        pub fn part(comptime n: Spec, st: anytype, v: anytype) ?Part {
            const cs: ContextState = @field(st, field_name);
            if (comptime named(n, partName(id, "scrim"))) {
                if (!cs.menu.open) return null;
                return .{ .style = popover.scrimStyle(v.in.viewport) };
            }
            if (comptime named(n, partName(id, "panel"))) return .{ .style = listStyle(&th, cs.at), .role = .menu };
            if (comptime def.sub_at != null and named(n, partName(id, "sub"))) {
                if (!cs.menu.sub) return null;
                return .{ .style = menu.subStyle(&th, v.last.of(partName(id, def.items[def.sub_at.?]))), .role = .menu };
            }
            inline for (0..comptime def.count()) |k| {
                if (comptime named(n, partName(id, def.name(k)))) return .{ .style = menu.itemStyle(&th, menu.highlighted(def, cs.menu, k)), .role = .menu_item };
            }
            return popover.plainPart(th, n, v.response);
        }
    };
}

fn named(comptime n: Spec, comptime want: []const u8) bool {
    return n.id != null and std.mem.eql(u8, n.id.?, want);
}

// ---- look -------------------------------------------------------------------------------------

/// The list, its top-left corner at `at`: menu.zig's list (panel fill, control outline, half a
/// gap of padding), placed at a point instead of below a button.
pub fn listStyle(th: *const Theme, at: [2]f32) Style {
    var s = menu.listStyle(th, .{});
    s.offset = at;
    return s;
}

// ---- behaviour: a pure function of the state and what happened --------------------------------

/// One frame of a context menu. A press of the secondary button on the target (its rect last
/// frame) opens the menu with its corner at the pointer, also when it is already open; one
/// anywhere else closes it. The context-menu key, or Shift+F10 (the APG's keys for it), opens a
/// closed menu at the target's top-left corner. While it is open it follows `menu.advance`
/// (a primary press outside it closes it, keys move, choose and close).
pub fn advance(comptime def: menu.Def, st: ContextState, target: Rect, hits: menu.Hits, in: *const Input) ContextState {
    var s = st;
    s.right = in.buttons.right;
    s.menu.chosen = 0;
    const p = in.pointer;
    if (in.buttons.right and !st.right) {
        const on = p[0] >= target.x0 and p[0] < target.x1 and p[1] >= target.y0 and p[1] < target.y1;
        s.menu = if (on) .{ .open = true } else .{};
        s.at = if (on) p else s.at;
        return s;
    }
    if (!s.menu.open) {
        const k = popover.keys;
        const key = popover.keyCount(in, k.menu, .{}, false) + popover.keyCount(in, k.f10, .{ .shift = true }, true);
        if (key != 0) {
            s.menu = .{ .open = true };
            s.at = .{ target.x0, target.y0 };
        }
        return s;
    }
    s.menu = menu.advance(def, s.menu, hits, in.events);
    return s;
}

// ---- accessibility ------------------------------------------------------------------------------

/// The semantics of context menu `name` of widget `target` the tree's columns cannot hold,
/// written into `s` after `Semantics.clear` and before `a11y.names` and `a11y.states`. The
/// roles are in the columns: the lists are `menu`, the items `menu_item` (named by their text,
/// value 0). Here: the list is named by the target (`aria-labelledby`), the submenu's item is
/// expandable and names the submenu, and the highlighted item is `selected` (`menu.semantics`).
pub fn semantics(t: *const Tree, s: *a11y.Semantics, comptime name: []const u8, comptime target: []const u8, comptime def: menu.Def, st: ContextState) void {
    menu.semantics(t, s, name, def, st.menu);
    const list = t.find(.from(partName(name, "panel")));
    const on = t.find(.from(target));
    if (list != types.none and on != types.none) s.c.labelled_by[list] = on;
}

// ---- runtime front end ------------------------------------------------------------------------

/// Builds context menu `name` of widget `target` (items `def`, labels `texts` in menu.zig's
/// one sequence) if it is open. Call it at the root's depth, after the rest of the page, so it
/// is drawn on top. Returns the item chosen this frame plus one, or 0.
pub fn show(f: *Frame, th: *const Theme, comptime name: []const u8, comptime target: []const u8, comptime def: menu.Def, st: *ContextState, texts: []const []const u8) u8 {
    std.debug.assert(texts.len == def.count());
    // Every response is asked for before anything is built, so the rows show the frame's
    // final state, as in the comptime front end.
    const inter = &f.ctx.inter;
    var hits: menu.Hits = .{ .outside = inter.response(.from(partName(name, "scrim"))).pressed };
    inline for (0..comptime def.count()) |k| hits.add(k, inter.response(.from(partName(name, def.name(k)))));
    st.* = advance(def, st.*, f.lastRect(.from(target)), hits, f.in);
    if (!st.menu.open) return st.menu.chosen;
    _ = f.interact(f.open(.from(partName(name, "scrim")), popover.scrimStyle(f.in.viewport)), popover.overlay_sense);
    const list = f.open(.from(partName(name, "panel")), listStyle(th, st.at));
    _ = f.interact(list, popover.overlay_sense);
    role(f, list, .menu);
    inline for (0..def.items.len) |k| buildItem(f, th, name, def, st.menu, k, texts[k]);
    f.close();
    if (def.sub_at) |at| if (st.menu.sub) {
        const sub = f.open(.from(partName(name, "sub")), menu.subStyle(th, f.lastRect(.from(partName(name, def.items[at])))));
        _ = f.interact(sub, popover.overlay_sense);
        role(f, sub, .menu);
        inline for (def.items.len..comptime def.count()) |k| buildItem(f, th, name, def, st.menu, k, texts[k]);
        f.close();
    };
    f.close();
    return st.menu.chosen;
}

fn role(f: *Frame, n: types.Node, r: a11y.Role) void {
    f.tree().c.role[n.ix()] = @backingInt(r);
}

fn buildItem(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: menu.Def, ms: menu.MenuState, comptime k: u8, text: []const u8) void {
    const row = f.open(.from(partName(name, def.name(k))), menu.itemStyle(th, menu.highlighted(def, ms, k)));
    _ = f.interact(row, popover.overlay_sense);
    role(f, row, .menu_item);
    _ = base.label(f, th, text);
    f.close();
}

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;

const edit_menu: menu.Def = .{ .items = &.{ "cut", "copy", "paste", "arrange" }, .sub_at = 3, .sub = &.{ "front", "back" } };
const edit_texts = [_][]const u8{ "Cut", "Copy", "Paste", "Arrange", "To front", "To back" };

/// The test page: a caption, the canvas the menu belongs to, and the menu.
fn Page(comptime th: Theme) type {
    return struct {
        const canvas_style: Style = .{ .dir = .x, .size = .{ .px(300), .px(160) }, .pad = @splat(th.pad), .radius = th.radius };
        // The scrim floats at its parent's content origin, so the page that holds it is not
        // padded: the content's padding is in a column of its own.
        const page_style: Style = .{ .size = .{ .fill, .fill } };
        const content_style: Style = .{ .pad = @splat(8), .gap = 8 };

        pub const App = struct {
            ctx: ContextState = .{},
            chosen: u8 = 0,

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, page_style);
                _ = f.open(.none, content_style);
                _ = base.label(f, &th, "Right-click the canvas");
                const c = f.open(.from("canvas"), canvas_style);
                f.setFill(c, base.buttonFill(&th, f.interact(c, .button)));
                _ = base.label(f, &th, "Canvas");
                f.close();
                f.close();
                app.chosen = show(f, &th, "ctx", "canvas", edit_menu, &app.ctx, &edit_texts);
                f.close();
            }
        };

        pub const State = struct {
            ctx: ContextState = .{},
            hint: []const u8 = "Right-click the canvas",
            canvas_text: []const u8 = "Canvas",
            cut: []const u8 = "Cut",
            copy: []const u8 = "Copy",
            paste: []const u8 = "Paste",
            arrange: []const u8 = "Arrange",
            front: []const u8 = "To front",
            back: []const u8 = "To back",
        };
        pub const C = ContextMenu(th, .ctx, .canvas, .ctx, edit_menu);
        pub const spec = blk: {
            var canvas = spec_zig.row(canvas_style, .{base.ct.label(th, .canvas_text)});
            canvas.id = "canvas";
            break :blk spec_zig.col(page_style, .{ spec_zig.col(content_style, .{ base.ct.label(th, .hint), canvas }), C.layer() });
        };
        pub const Ui = popover.ComptimePage(State, spec, th, C);
        pub const limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

/// Sets the context menu's state in both front ends of `h` and builds two frames (the second
/// sees the first's rects); returns the second's tree.
fn setState(h: anytype, st: ContextState) !*const Tree {
    const in: Input = .{ .viewport = .{ 400, 300 } };
    h.app.ctx = st;
    h.ui.signals.set(.ctx, st);
    _ = try h.frame(&in);
    return (try h.frame(&in)).runtime.tree;
}

test "ContextMenu: the page agrees in both front ends, closed, open and with the submenu" {
    const h = &harness;
    h.init();
    var t = try setState(h, .{});
    try testing.expectEqual(@as(u32, 6), t.len);
    t = try setState(h, .{ .menu = .{ .open = true }, .at = .{ 120, 90 } });
    try testing.expectEqual(@as(u32, 6 + 2 + 8), t.len);
    const list = t.rect(t.find(.from("ctx_panel")));
    try testing.expectEqual([2]f32{ 120, 90 }, [2]f32{ list.x0, list.y0 });
    t = try setState(h, .{ .menu = .{ .open = true, .sub = true }, .at = .{ 120, 90 } });
    try testing.expectEqual(@as(u32, 6 + 2 + 8 + 1 + 4), t.len);
}

test "listStyle: menu.zig's list at a point" {
    const th: Theme = .default;
    const s = listStyle(&th, .{ 5, 7 });
    var want = menu.listStyle(&th, .{});
    want.offset = .{ 5, 7 };
    try testing.expectEqual(want, s);
    try testing.expectEqual(th.panel, s.fill);
}

const light: Theme = .{ .panel = .rgb(240, 240, 240), .control_hot = .rgb(180, 180, 190), .text = .rgb(20, 20, 20), .pad = 12, .gap = 10, .radius = 0 };

test "ContextMenu: another theme restyles both front ends alike" {
    const S = struct {
        var h: Page(light).Run = .{};
    };
    S.h.init();
    const t = try setState(&S.h, .{ .menu = .{ .open = true, .active = 1 }, .at = .{ 50, 60 } });
    try testing.expectEqual(light.panel.bitsOf(), t.c.look[t.find(.from("ctx_panel"))].fill);
    try testing.expectEqual(light.control_hot.bitsOf(), t.c.look[t.find(.from("ctx_copy"))].fill);
}

test "advance: the secondary button and the menu key open it; it then works as a menu" {
    const target: Rect = .{ .x0 = 10, .y0 = 20, .x1 = 110, .y1 = 120 };
    const k = popover.keys;
    var in: Input = .{ .pointer = .{ 50, 60 }, .buttons = .{ .right = true } };
    var s = advance(edit_menu, .{}, target, .{}, &in);
    try testing.expect(s.menu.open and s.right);
    try testing.expectEqual([2]f32{ 50, 60 }, s.at);
    // Held: not a new press.
    in.pointer = .{ 70, 80 };
    s = advance(edit_menu, s, target, .{}, &in);
    try testing.expectEqual([2]f32{ 50, 60 }, s.at);
    in.buttons.right = false;
    s = advance(edit_menu, s, target, .{}, &in);
    // Pressed again elsewhere on the target: opens there; off the target: closes.
    in.buttons.right = true;
    s = advance(edit_menu, s, target, .{}, &in);
    try testing.expect(s.menu.open);
    try testing.expectEqual([2]f32{ 70, 80 }, s.at);
    in.buttons.right = false;
    s = advance(edit_menu, s, target, .{}, &in);
    in = .{ .pointer = .{ 300, 300 }, .buttons = .{ .right = true } };
    s = advance(edit_menu, s, target, .{}, &in);
    try testing.expect(!s.menu.open);
    // The menu key and Shift+F10 open at the target's corner; F10 alone does not.
    const ev = struct {
        fn of(code: u8, mods: Input.Mods) [1]Input.Event {
            return .{.{ .kind = .press, .code = code, .mods = mods }};
        }
    }.of;
    var e = ev(k.f10, .{});
    in = .{ .events = &e };
    try testing.expect(!advance(edit_menu, .{}, target, .{}, &in).menu.open);
    e = ev(k.f10, .{ .shift = true });
    s = advance(edit_menu, .{}, target, .{}, &in);
    try testing.expect(s.menu.open);
    try testing.expectEqual([2]f32{ 10, 20 }, s.at);
    e = ev(k.menu, .{});
    try testing.expect(advance(edit_menu, .{}, target, .{}, &in).menu.open);
    // Open, it is a menu: Down, Enter chooses Copy.
    e = ev(k.down, .{});
    s = advance(edit_menu, s, target, .{}, &in);
    e = ev(k.enter, .{});
    s = advance(edit_menu, s, target, .{}, &in);
    try testing.expectEqual(@as(u8, 2), s.menu.chosen);
    try testing.expect(!s.menu.open);
}

const Aim = union(enum) { part: []const u8, at: [2]f32 };
const Step = struct { aim: Aim, left: bool = false, right: bool = false, key: ?u8 = null };

/// Runs `script` through both front ends, aiming at last frame's rects, with the context
/// menu's state equal in both after every step; returns the state after each step.
fn runScript(comptime n: usize, script: [n]Step) ![n]ContextState {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 400, 300 } };
    var ev: [1]Input.Event = undefined;
    var last = (try h.frame(&in)).runtime.tree;
    var out: [n]ContextState = undefined;
    for (script, &out) |st, *o| {
        in.pointer = switch (st.aim) {
            .at => |p| p,
            .part => |name| blk: {
                const r = last.rect(last.find(.hash(name)));
                break :blk .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
            },
        };
        in.buttons = .{ .left = st.left, .right = st.right };
        in.events = &.{};
        if (st.key) |k| {
            ev[0] = .{ .kind = .press, .code = k };
            in.events = &ev;
        }
        last = (try h.frame(&in)).runtime.tree;
        try testing.expectEqual(h.app.ctx, h.ui.signals.state.ctx);
        try testing.expectEqual(h.app.chosen, h.app.ctx.menu.chosen);
        o.* = h.app.ctx;
    }
    return out;
}

test "ContextMenu: secondary click, pointer and keys in both front ends" {
    const k = popover.keys;
    const s = try runScript(10, .{
        .{ .aim = .{ .at = .{ 100, 80 } }, .right = true }, // on the canvas: open at the pointer
        .{ .aim = .{ .at = .{ 100, 80 } } },
        .{ .aim = .{ .part = "ctx_paste" } }, // highlight Paste
        .{ .aim = .{ .part = "ctx_paste" }, .left = true },
        .{ .aim = .{ .part = "ctx_paste" } }, // chosen: 3
        .{ .aim = .{ .at = .{ 390, 290 } }, .key = k.menu }, // the menu key: open at the canvas
        .{ .aim = .{ .at = .{ 390, 290 } }, .key = k.up }, // wraps to Arrange
        .{ .aim = .{ .at = .{ 390, 290 } }, .key = k.right }, // its submenu
        .{ .aim = .{ .at = .{ 390, 290 } }, .left = true }, // press outside: closed
        .{ .aim = .{ .at = .{ 390, 290 } }, .right = true }, // secondary press off the canvas: stays closed
    });
    try testing.expect(s[0].menu.open);
    try testing.expectEqual([2]f32{ 100, 80 }, s[0].at);
    try testing.expectEqual(@as(u8, 2), s[2].menu.active);
    try testing.expectEqual(@as(u8, 3), s[4].menu.chosen);
    try testing.expect(s[5].menu.open);
    try testing.expectEqual(@as(u8, 3), s[6].menu.active);
    try testing.expect(s[7].menu.sub);
    try testing.expect(!s[8].menu.open and !s[9].menu.open);
}

var sem: [2]popover.Semantic(64) = .{ .{}, .{} };

test "ContextMenu: a menu named by its target, of menu items; the same in both front ends" {
    const h = &harness;
    h.init();
    const t = try setState(h, .{ .menu = .{ .open = true, .sub = true, .active = 3 }, .at = .{ 100, 80 } });
    const cp = &h.ui.tables.t;
    semantics(t, sem[0].begin(), "ctx", "canvas", edit_menu, h.app.ctx);
    semantics(cp, sem[1].begin(), "ctx", "canvas", edit_menu, h.ui.signals.state.ctx);
    const e = sem[0].finish(t, &h.ctx.texts[h.ctx.cur], h.ctx.strings[h.ctx.cur].buf);
    try testing.expect(popover.sameSemantics(e, sem[1].finish(cp, &h.ui.tables.tx, h.ui.tables.strings.buf)));
    const row = struct {
        fn of(x: *const a11y.Export, tr: *const Tree, comptime id: []const u8) u32 {
            return popover.exportRow(x, tr.find(.from(id)));
        }
    }.of;
    const H = std.hash.Fnv1a_32;
    try testing.expectEqual(@backingInt(a11y.Role.menu), e.c.role[row(e, t, "ctx_panel")]);
    try testing.expectEqual(H.hash("Canvas"), e.c.name_hash[row(e, t, "ctx_panel")]);
    try testing.expectEqual(@backingInt(a11y.Role.menu_item), e.c.role[row(e, t, "ctx_cut")]);
    try testing.expectEqual(H.hash("Cut"), e.c.name_hash[row(e, t, "ctx_cut")]);
    try testing.expectEqual(a11y.State.bitsOf(.{ .expandable = true, .expanded = true, .selected = true }), e.c.state[row(e, t, "ctx_arrange")]);
    try testing.expectEqual(H.hash("Arrange"), e.c.name_hash[row(e, t, "ctx_sub")]);
    try testing.expectEqual(@as(u32, 4), e.c.kids[row(e, t, "ctx_panel")]);
}

test "checkContext: the state field and the items" {
    try testing.expectEqual(null, comptime checkContext(Default.State, edit_menu, "ctx"));
    try testing.expectEqualStrings("context menu: field 'ctx' must be a contextmenu.ContextState", comptime checkContext(struct { ctx: menu.MenuState }, edit_menu, "ctx").?);
    try testing.expectEqualStrings("context menu: item 'cut' needs a string field of its name", comptime checkContext(struct { ctx: ContextState }, edit_menu, "ctx").?);
    try testing.expectEqualStrings("context menu: no items", comptime checkContext(Default.State, .{ .items = &.{} }, "ctx").?);
}

test {
    std.testing.refAllDecls(@This());
}
