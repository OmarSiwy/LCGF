//! Select (tier 2): a button showing the chosen option of a fixed list, which opens the list
//! below it, the WAI-ARIA APG select-only combobox pattern. Written against the public API of
//! tiers 0 and 1, after the recipe in base.zig, from menu.zig's parts: the list is a menu's list
//! (`menu.Def` holds the options, `menu.MenuState` its open state and highlight, `menu.advance`
//! its keys and pointer), floating under the root on a scrim below the button
//! (`Style.float`, `Style.offset`, prototype/ui.zig); only what a choice does differs, it
//! becomes the value.
//!
//! Runtime: `button(...)` in the page's flow, then `list(...)` under the root after the page.
//!
//! Comptime: `const S = Select(th, .shape, .shape_state, .shape_text, def);` gives the spec
//! builders `S.button` and `S.layer` and the hooks `popover.ComptimePage(State, spec, th, S)`
//! runs. The button's label shows the string field `shape_text`, which the hooks keep equal to
//! the chosen option's field.

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

// ---- spec: what the select takes and keeps ---------------------------------------------------

/// A select's state, owned by the application.
pub const SelectState = struct {
    /// The chosen option, by position: the value.
    selected: u8 = 0,
    /// The open list, as menu.zig keeps a menu.
    menu: menu.MenuState = .{},
};

/// `null` if `State` can hold select `def` bound to `field`, its button showing `text`, else
/// the compile error: `field` must be a `SelectState`, `text` and every option's field strings,
/// and the options a flat list (no submenu).
pub fn checkSelect(comptime State: type, comptime def: menu.Def, comptime field: []const u8, comptime text: []const u8) ?[]const u8 {
    if (!@hasField(State, field)) return "select: state " ++ @typeName(State) ++ " has no field '" ++ field ++ "'";
    if (@FieldType(State, field) != SelectState) return "select: field '" ++ field ++ "' must be a select.SelectState";
    if (!@hasField(State, text) or @FieldType(State, text) != []const u8) return "select: the button needs a string field '" ++ text ++ "'";
    if (def.items.len == 0) return "select: no options";
    if (def.items.len >= menu.no_item) return "select: too many options";
    if (def.sub.len != 0 or def.sub_at != null) return "select: options are a flat list";
    for (def.items) |o| {
        if (!@hasField(State, o) or @FieldType(State, o) != []const u8) return "select: option '" ++ o ++ "' needs a string field of its name";
    }
    return null;
}

/// Select `name` with options `def`, bound to the `SelectState` field `field`, its button
/// showing the string field `text`, in theme `th`: its spec builders and the hooks
/// `popover.ComptimePage` calls.
pub fn Select(comptime th: Theme, comptime name: @EnumLiteral(), comptime field: @EnumLiteral(), comptime text: @EnumLiteral(), comptime def: menu.Def) type {
    const id = @tagName(name);
    const field_name = @tagName(field);
    return struct {
        /// The button, showing the chosen option (the string field `text`).
        pub fn button() Spec {
            return base.ct.button(th, name, text);
        }

        /// The scrim and the list, shown while it is open, as menu.zig builds a menu's. Put it
        /// last in the page's root so it is drawn above the rest.
        pub fn layer() Spec {
            return menu.Menu(th, name, field, def).layer();
        }

        pub fn check(comptime State: type) ?[]const u8 {
            return checkSelect(State, def, field_name, @tagName(text));
        }

        pub fn step(sig: anytype, v: anytype) void {
            _ = sig;
            _ = v;
        }

        pub fn part(comptime n: Spec, st: anytype, v: anytype) ?Part {
            const ss: SelectState = @field(st, field_name);
            if (comptime named(n, id)) return .{ .style = buttonStyle(&th, v.response) };
            if (comptime named(n, partName(id, "scrim"))) {
                if (!ss.menu.open) return null;
                return .{ .style = popover.scrimStyle(v.in.viewport) };
            }
            if (comptime named(n, partName(id, "panel"))) return .{ .style = listStyle(&th, v.last.of(id)) };
            inline for (def.items, 0..) |o, k| {
                if (comptime named(n, partName(id, o))) return .{ .style = optionStyle(&th, ss.menu.active == k, ss.selected == k) };
            }
            return popover.plainPart(th, n, v.response);
        }
    };
}

fn named(comptime n: Spec, comptime want: []const u8) bool {
    return n.id != null and std.mem.eql(u8, n.id.?, want);
}

// ---- look -------------------------------------------------------------------------------------

/// The button: a theme button filled by its response, at least 120 wide, its text at the
/// start.
pub fn buttonStyle(th: *const Theme, r: Response) Style {
    var s = base.buttonStyle(th);
    s.fill = base.buttonFill(th, r);
    s.min = .{ 120, 0 };
    s.main = .start;
    return s;
}

/// The list: menu.zig's list below the button's rect `at` (last frame's), at least as wide as
/// the button.
pub fn listStyle(th: *const Theme, at: Rect) Style {
    var s = menu.listStyle(th, at);
    s.min = .{ at.w(), 0 };
    return s;
}

/// An option row: menu.zig's item, filled from `optionFills` by highlight and choice.
pub fn optionStyle(th: *const Theme, active: bool, selected: bool) Style {
    var s = menu.itemStyle(th, active);
    s.fill = optionFills(th)[(@as(u2, @intFromBool(active)) << 1) | @intFromBool(selected)];
    return s;
}

/// An option's fill, indexed by `active << 1 | selected`: none, the control colour for the
/// chosen one, the hot control colour for the highlighted one, chosen or not.
pub fn optionFills(th: *const Theme) base.StateColors {
    return .{ .transparent, th.control, th.control_hot, th.control_hot };
}

// ---- runtime front end ------------------------------------------------------------------------

/// The button of select `name` (options `def`, labelled `texts`), in the page's flow, showing
/// the chosen option.
pub fn button(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: menu.Def, st: *SelectState, texts: []const []const u8) Response {
    std.debug.assert(texts.len == def.items.len);
    const inter = &f.ctx.inter;
    const r = inter.response(.from(name));
    const b = f.open(.from(name), buttonStyle(th, r));
    _ = f.interact(b, .button);
    _ = base.label(f, th, texts[st.selected]);
    f.close();
    return r;
}

/// The list of select `name`, if it is open. Call it at the root's depth, after the rest of
/// the page, so it is drawn on top.
pub fn list(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: menu.Def, st: *const SelectState, texts: []const []const u8) void {
    if (!st.menu.open) return;
    _ = f.open(.from(partName(name, "scrim")), popover.scrimStyle(f.in.viewport));
    _ = f.open(.from(partName(name, "panel")), listStyle(th, f.lastRect(.from(name))));
    inline for (def.items, 0..) |o, k| {
        _ = f.open(.from(partName(name, o)), optionStyle(th, st.menu.active == k, st.selected == k));
        _ = base.label(f, th, texts[k]);
        f.close();
    }
    f.close();
    f.close();
}

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;

const shapes: menu.Def = .{ .items = &.{ "circle", "square", "triangle" } };
const shape_texts = [_][]const u8{ "Circle", "Square", "Triangle" };

/// The test page: a toolbar with a caption and the select, and the select's list.
fn Page(comptime th: Theme) type {
    return struct {
        const toolbar_style: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel };
        const page_style: Style = .{ .size = .{ .fill, .fill } };

        pub const App = struct {
            shape: SelectState = .{},

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, page_style);
                _ = f.open(.none, toolbar_style);
                _ = base.label(f, &th, "Shape");
                _ = button(f, &th, "shape", shapes, &app.shape, &shape_texts);
                f.close();
                list(f, &th, "shape", shapes, &app.shape, &shape_texts);
                f.close();
            }
        };

        pub const State = struct {
            shape: SelectState = .{},
            caption: []const u8 = "Shape",
            shape_text: []const u8 = "Circle",
            circle: []const u8 = "Circle",
            square: []const u8 = "Square",
            triangle: []const u8 = "Triangle",
        };
        pub const S = Select(th, .shape, .shape, .shape_text, shapes);
        pub const spec = spec_zig.col(page_style, .{
            spec_zig.row(toolbar_style, .{ base.ct.label(th, .caption), S.button() }),
            S.layer(),
        });
        pub const Ui = popover.ComptimePage(State, spec, th, S);
        pub const limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

/// Sets the select's state in both front ends of `h` (and the comptime button's text) and
/// builds two frames (the second sees the first's rects); returns the second's tree.
fn setState(h: anytype, st: SelectState) !*const Tree {
    const in: Input = .{ .viewport = .{ 400, 300 } };
    h.app.shape = st;
    h.ui.signals.set(.shape, st);
    h.ui.signals.set(.shape_text, shape_texts[st.selected]);
    _ = try h.frame(&in);
    return (try h.frame(&in)).runtime.tree;
}

test "Select: the page agrees in both front ends, closed and open" {
    const h = &harness;
    h.init();
    var t = try setState(h, .{ .selected = 2 });
    try testing.expectEqual(@as(u32, 6), t.len);
    t = try setState(h, .{ .selected = 1, .menu = .{ .open = true, .active = 1 } });
    try testing.expectEqual(@as(u32, 6 + 2 + 6), t.len);
    const at = t.rect(t.find(.from("shape")));
    try testing.expectEqual(at.x0, t.rect(t.find(.from("shape_panel"))).x0);
}

test "buttonStyle, listStyle, optionStyle: the theme's tokens" {
    const th: Theme = .default;
    try testing.expectEqual(th.control_hot, buttonStyle(&th, .{ .hovered = true }).fill);
    try testing.expectEqual([2]f32{ 120, 0 }, buttonStyle(&th, .{}).min);
    const l = listStyle(&th, .{ .x0 = 10, .y0 = 0, .x1 = 150, .y1 = 30 });
    try testing.expectEqual([2]f32{ 140, 0 }, l.min);
    try testing.expectEqual(th.panel, l.fill);
    try testing.expectEqual(types.Color.transparent, optionStyle(&th, false, false).fill);
    try testing.expectEqual(th.control, optionStyle(&th, false, true).fill);
    try testing.expectEqual(th.control_hot, optionStyle(&th, true, false).fill);
    try testing.expectEqual(th.control_hot, optionStyle(&th, true, true).fill);
}

const light: Theme = .{ .panel = .rgb(240, 240, 240), .control = .rgb(200, 200, 205), .control_hot = .rgb(180, 180, 190), .text = .rgb(20, 20, 20), .pad = 12, .gap = 10, .radius = 0 };

test "Select: another theme restyles both front ends alike" {
    const S = struct {
        var h: Page(light).Run = .{};
    };
    S.h.init();
    const t = try setState(&S.h, .{ .selected = 2, .menu = .{ .open = true } });
    try testing.expectEqual(light.control.bitsOf(), t.c.look[t.find(.from("shape_triangle"))].fill);
    try testing.expectEqual(light.control_hot.bitsOf(), t.c.look[t.find(.from("shape_circle"))].fill);
    // The list is at least as wide as the button.
    try testing.expect(t.rect(t.find(.from("shape_panel"))).w() >= t.rect(t.find(.from("shape"))).w());
}

test "checkSelect: the state field, the button's text and the options" {
    try testing.expectEqual(null, comptime checkSelect(Default.State, shapes, "shape", "shape_text"));
    try testing.expectEqualStrings("select: field 'shape' must be a select.SelectState", comptime checkSelect(struct { shape: u8 }, shapes, "shape", "shape_text").?);
    try testing.expectEqualStrings("select: the button needs a string field 'shape_text'", comptime checkSelect(struct { shape: SelectState }, shapes, "shape", "shape_text").?);
    try testing.expectEqualStrings("select: options are a flat list", comptime checkSelect(Default.State, .{ .items = &.{"circle"}, .sub_at = 0, .sub = &.{"square"} }, "shape", "shape_text").?);
    try testing.expectEqualStrings("select: option 'hexagon' needs a string field of its name", comptime checkSelect(Default.State, .{ .items = &.{"hexagon"} }, "shape", "shape_text").?);
}

test {
    std.testing.refAllDecls(@This());
}
