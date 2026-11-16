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
    _ = target;
    return struct {
        /// The scrim, the list and the submenu, shown while the menu is open, as menu.zig
        /// builds them. Put it last in the page's root so it is drawn above the rest.
        pub fn layer() Spec {
            return menu.Menu(th, name, field, def).layer();
        }

        pub fn check(comptime State: type) ?[]const u8 {
            return checkContext(State, def, field_name);
        }

        pub fn step(sig: anytype, v: anytype) void {
            _ = sig;
            _ = v;
        }

        pub fn part(comptime n: Spec, st: anytype, v: anytype) ?Part {
            const cs: ContextState = @field(st, field_name);
            if (comptime named(n, partName(id, "scrim"))) {
                if (!cs.menu.open) return null;
                return .{ .style = popover.scrimStyle(v.in.viewport) };
            }
            if (comptime named(n, partName(id, "panel"))) return .{ .style = listStyle(&th, cs.at) };
            if (comptime def.sub_at != null and named(n, partName(id, "sub"))) {
                if (!cs.menu.sub) return null;
                return .{ .style = menu.subStyle(&th, v.last.of(partName(id, def.items[def.sub_at.?]))) };
            }
            inline for (0..comptime def.count()) |k| {
                if (comptime named(n, partName(id, def.name(k)))) return .{ .style = menu.itemStyle(&th, menu.highlighted(def, cs.menu, k)) };
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

// ---- runtime front end ------------------------------------------------------------------------

/// Builds context menu `name` of widget `target` (items `def`, labels `texts` in menu.zig's
/// one sequence) if it is open. Call it at the root's depth, after the rest of the page, so it
/// is drawn on top. Returns the item chosen this frame plus one, or 0.
pub fn show(f: *Frame, th: *const Theme, comptime name: []const u8, comptime target: []const u8, comptime def: menu.Def, st: *ContextState, texts: []const []const u8) u8 {
    _ = target;
    std.debug.assert(texts.len == def.count());
    if (!st.menu.open) return st.menu.chosen;
    _ = f.open(.from(partName(name, "scrim")), popover.scrimStyle(f.in.viewport));
    _ = f.open(.from(partName(name, "panel")), listStyle(th, st.at));
    inline for (0..def.items.len) |k| buildItem(f, th, name, def, st.menu, k, texts[k]);
    f.close();
    if (def.sub_at) |at| if (st.menu.sub) {
        _ = f.open(.from(partName(name, "sub")), menu.subStyle(th, f.lastRect(.from(partName(name, def.items[at])))));
        inline for (def.items.len..comptime def.count()) |k| buildItem(f, th, name, def, st.menu, k, texts[k]);
        f.close();
    };
    f.close();
    return st.menu.chosen;
}

fn buildItem(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: menu.Def, ms: menu.MenuState, comptime k: u8, text: []const u8) void {
    _ = f.open(.from(partName(name, def.name(k))), menu.itemStyle(th, menu.highlighted(def, ms, k)));
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

test "checkContext: the state field and the items" {
    try testing.expectEqual(null, comptime checkContext(Default.State, edit_menu, "ctx"));
    try testing.expectEqualStrings("context menu: field 'ctx' must be a contextmenu.ContextState", comptime checkContext(struct { ctx: menu.MenuState }, edit_menu, "ctx").?);
    try testing.expectEqualStrings("context menu: item 'cut' needs a string field of its name", comptime checkContext(struct { ctx: ContextState }, edit_menu, "ctx").?);
    try testing.expectEqualStrings("context menu: no items", comptime checkContext(Default.State, .{ .items = &.{} }, "ctx").?);
}

test {
    std.testing.refAllDecls(@This());
}
