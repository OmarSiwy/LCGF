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

        /// The button's, the scrim's and the options' responses and the keys, through
        /// `advance`; then the button's text follows the value.
        pub fn step(sig: anytype, v: anytype) void {
            var hits: menu.Hits = .{ .toggle = v.responseOf(id).clicked, .outside = v.responseOf(partName(id, "scrim")).pressed };
            inline for (def.items, 0..) |o, k| hits.add(k, v.responseOf(partName(id, o)));
            const ss = advance(def, @field(sig.state, field_name), hits, v.in.events);
            sig.set(field, ss);
            inline for (def.items, 0..) |o, k| if (ss.selected == k) sig.set(text, @field(sig.state, o));
        }

        pub fn part(comptime n: Spec, st: anytype, v: anytype) ?Part {
            const ss: SelectState = @field(st, field_name);
            if (comptime named(n, id)) return .{ .style = valued(buttonStyle(&th, v.response), ss), .role = .combobox };
            if (comptime named(n, partName(id, "scrim"))) {
                if (!ss.menu.open) return null;
                return .{ .style = popover.scrimStyle(v.in.viewport) };
            }
            if (comptime named(n, partName(id, "panel"))) return .{ .style = listStyle(&th, v.last.of(id)), .role = .listbox };
            inline for (def.items, 0..) |o, k| {
                if (comptime named(n, partName(id, o))) return .{ .style = optionStyle(&th, ss.menu.active == k, ss.selected == k), .role = .option };
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

// ---- behaviour: a pure function of the state and what happened --------------------------------

/// One frame of a select (APG select-only combobox): the list works as `menu.advance` works a
/// menu (the button's click toggles it, a press outside closes it, the pointer and Up, Down,
/// Home and End move the highlight, Enter, Space or a click choose and close, Escape closes),
/// but it opens with the chosen option highlighted, and a choice becomes the value.
pub fn advance(comptime def: menu.Def, st: SelectState, hits: menu.Hits, evs: []const Input.Event) SelectState {
    var s = st;
    s.menu = menu.advance(def, st.menu, hits, evs);
    if (s.menu.open and !st.menu.open) s.menu.active = st.selected;
    if (s.menu.chosen != 0) s.selected = s.menu.chosen - 1;
    return s;
}

// ---- accessibility ------------------------------------------------------------------------------

/// The button's style with the value column set: the chosen option's position.
pub fn valued(s: Style, st: SelectState) Style {
    var out = s;
    out.value = @floatFromInt(st.selected);
    return out;
}

/// The semantics of select `name` the tree's columns cannot hold, written into `s` after
/// `Semantics.clear` and before `a11y.names` and `a11y.states`. The columns hold the roles
/// (the button `combobox`, its value the chosen option's position; the list `listbox`; the
/// options `option`, named by their text). Here: the combobox is named by the row `label` (its
/// caption, `aria-labelledby`; `none` for none), is expandable and expanded while the list is
/// shown (`aria-expanded`), and names the list; the chosen option is `selected`
/// (`aria-selected`). Works on either front end's tree.
pub fn semantics(t: *const Tree, s: *a11y.Semantics, comptime name: []const u8, comptime def: menu.Def, st: SelectState, label: u32) void {
    const b = t.find(.from(name));
    if (b == types.none) return;
    const l = t.find(.from(partName(name, "panel")));
    s.c.state[b] |= a11y.State.bitsOf(.{ .expandable = true, .expanded = l != types.none });
    if (label != types.none) s.c.labelled_by[b] = label;
    if (l == types.none) return;
    s.c.labelled_by[l] = if (label != types.none) label else b;
    inline for (def.items, 0..) |o, k| {
        const row = t.find(.from(partName(name, o)));
        if (row != types.none and st.selected == k) s.c.state[row] |= a11y.State.bitsOf(.{ .selected = true });
    }
}

fn role(f: *Frame, n: types.Node, r: a11y.Role) void {
    f.tree().c.role[n.ix()] = @backingInt(r);
}

// ---- runtime front end ------------------------------------------------------------------------

/// The button of select `name` (options `def`, labelled `texts`), in the page's flow, showing
/// the chosen option.
pub fn button(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: menu.Def, st: *SelectState, texts: []const []const u8) Response {
    std.debug.assert(texts.len == def.items.len);
    // Every response is asked for before anything is built, so the rows show the frame's
    // final state, as in the comptime front end.
    const inter = &f.ctx.inter;
    const r = inter.response(.from(name));
    var hits: menu.Hits = .{ .toggle = r.clicked, .outside = inter.response(.from(partName(name, "scrim"))).pressed };
    inline for (def.items, 0..) |o, k| hits.add(k, inter.response(.from(partName(name, o))));
    st.* = advance(def, st.*, hits, f.in.events);
    const b = f.open(.from(name), valued(buttonStyle(th, r), st.*));
    _ = f.interact(b, .button);
    role(f, b, .combobox);
    _ = base.label(f, th, texts[st.selected]);
    f.close();
    return r;
}

/// The list of select `name`, if it is open. Call it at the root's depth, after the rest of
/// the page, so it is drawn on top.
pub fn list(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: menu.Def, st: *const SelectState, texts: []const []const u8) void {
    if (!st.menu.open) return;
    _ = f.interact(f.open(.from(partName(name, "scrim")), popover.scrimStyle(f.in.viewport)), popover.overlay_sense);
    const l = f.open(.from(partName(name, "panel")), listStyle(th, f.lastRect(.from(name))));
    _ = f.interact(l, popover.overlay_sense);
    role(f, l, .listbox);
    inline for (def.items, 0..) |o, k| {
        const row = f.open(.from(partName(name, o)), optionStyle(th, st.menu.active == k, st.selected == k));
        _ = f.interact(row, popover.overlay_sense);
        role(f, row, .option);
        _ = base.label(f, th, texts[k]);
        f.close();
    }
    f.close();
    f.close();
}

// ---- example page, replay and golden frames ---------------------------------------------------

/// The example's options.
pub const shapes: menu.Def = .{ .items = &.{ "circle", "square", "triangle" } };
pub const shape_texts = [_][]const u8{ "Circle", "Square", "Triangle" };

/// The example page: a toolbar with a caption and the select, and the select's list, in both
/// front ends, in theme `th`. The tests and the golden images (tools/golden/) run it.
pub fn Example(comptime th: Theme) type {
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

/// Input for `Example(.default)` at 800 x 600, one commented line per frame.
pub const replay = @embedFile("testdata/select.replay");

/// The frames of `replay` kept as golden images, by name (tools/golden/ref/widgets/<name>.png).
pub const golden_frames = .{
    .{ "select-open", 2 },
    .{ "select-keyed", 4 },
    .{ "select-chosen", 5 },
    .{ "select-hover", 8 },
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

test "Select: the example replay gives the same frames in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var r: Replay = .{ .src = replay };
    var st: [14]SelectState = undefined;
    while (try r.next(buf)) |in| {
        const k = h.frames;
        const out = try h.frame(in);
        const t = out.runtime.tree;
        try testing.expectEqual(h.app.shape, h.ui.signals.state.shape);
        try testing.expectEqualStrings(shape_texts[h.app.shape.selected], h.ui.signals.state.shape_text);
        st[k] = h.app.shape;
        if (k == 2) {
            // The rects the replay's comments give.
            const want = [_]struct { []const u8, Rect }{
                .{ "shape", .{ .x0 = 58, .y0 = 8, .x1 = 178, .y1 = 42 } },
                .{ "shape_panel", .{ .x0 = 58, .y0 = 48, .x1 = 178, .y1 = 143 } },
                .{ "shape_square", .{ .x0 = 61, .y0 = 81, .x1 = 175, .y1 = 110 } },
            };
            for (want) |w| try testing.expectEqual(w[1], t.rect(t.find(.hash(w[0]))));
        }
    }
    try testing.expectEqual(@as(u32, 14), h.frames);
    const open = [_]bool{ false, false, true, true, true, false, false, true, true, true, false, false, true, false };
    const value = [_]u8{ 0, 0, 0, 0, 0, 2, 2, 2, 2, 2, 1, 1, 1, 1 };
    for (st, open, value) |s, o, v| {
        try testing.expectEqual(o, s.menu.open);
        try testing.expectEqual(v, s.selected);
    }
    try testing.expectEqual(@as(u8, 2), st[4].menu.active);
    try testing.expectEqual(@as(u8, 2), st[7].menu.active);
    try testing.expectEqual(@as(u8, 1), st[8].menu.active);
}

test "golden_frames: name frames the replay has" {
    inline for (golden_frames) |g| try testing.expect(g[1] < 14);
}

test "advance: opens on the chosen option; a choice becomes the value" {
    const k = popover.keys;
    const ev = struct {
        fn of(comptime codes: []const u8) [codes.len]Input.Event {
            var out: [codes.len]Input.Event = undefined;
            for (&out, codes) |*e, c| e.* = .{ .kind = .press, .code = c };
            return out;
        }
    }.of;
    var s = advance(shapes, .{ .selected = 2 }, .{ .toggle = true }, &.{});
    try testing.expect(s.menu.open);
    try testing.expectEqual(@as(u8, 2), s.menu.active);
    s = advance(shapes, s, .{}, &ev(&.{ k.down, k.enter }));
    try testing.expectEqual(@as(u8, 0), s.selected); // wrapped to Circle, chosen
    try testing.expect(!s.menu.open);
    s = advance(shapes, s, .{ .toggle = true }, &.{});
    s = advance(shapes, s, .{}, &ev(&.{ k.end, k.escape }));
    try testing.expectEqual(@as(u8, 0), s.selected); // Escape keeps the value
    s = advance(shapes, s, .{ .toggle = true }, &.{});
    s = advance(shapes, s, .{ .hovered = 1, .clicked = 1 }, &.{});
    try testing.expectEqual(@as(u8, 1), s.selected);
}

const Aim = union(enum) { part: []const u8, at: [2]f32 };
const Step = struct { aim: Aim, left: bool = false, key: ?u8 = null };

/// Runs `script` through both front ends, aiming at last frame's rects, with the select's
/// state and the button's text equal in both after every step; returns the state after each.
fn runScript(comptime n: usize, script: [n]Step) ![n]SelectState {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 400, 300 } };
    var ev: [1]Input.Event = undefined;
    var last = (try h.frame(&in)).runtime.tree;
    var out: [n]SelectState = undefined;
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
        try testing.expectEqual(h.app.shape, h.ui.signals.state.shape);
        try testing.expectEqualStrings(shape_texts[h.app.shape.selected], h.ui.signals.state.shape_text);
        o.* = h.app.shape;
    }
    return out;
}

test "Select: open, arrows, Enter, Escape and clicks in both front ends" {
    const k = popover.keys;
    const s = try runScript(13, .{
        .{ .aim = .{ .part = "shape" }, .left = true },
        .{ .aim = .{ .part = "shape" } }, // open on Circle
        .{ .aim = .{ .part = "shape" }, .key = k.down }, // Square
        .{ .aim = .{ .part = "shape" }, .key = k.down }, // Triangle
        .{ .aim = .{ .part = "shape" }, .key = k.enter }, // chosen
        .{ .aim = .{ .part = "shape" }, .left = true },
        .{ .aim = .{ .part = "shape" } }, // open on Triangle
        .{ .aim = .{ .part = "shape" }, .key = k.home }, // Circle highlighted
        .{ .aim = .{ .part = "shape" }, .key = k.escape }, // closed, still Triangle
        .{ .aim = .{ .part = "shape" }, .left = true },
        .{ .aim = .{ .part = "shape" } }, // open
        .{ .aim = .{ .part = "shape_square" } }, // the pointer reaches Square
        .{ .aim = .{ .at = .{ 390, 290 } }, .left = true }, // press outside: closed
    });
    try testing.expect(s[1].menu.open and s[1].menu.active == 0);
    try testing.expectEqual(@as(u8, 2), s[3].menu.active);
    try testing.expect(!s[4].menu.open and s[4].selected == 2);
    try testing.expectEqual(@as(u8, 2), s[6].menu.active);
    try testing.expectEqual(@as(u8, 0), s[7].menu.active);
    try testing.expect(!s[8].menu.open and s[8].selected == 2);
    try testing.expectEqual(@as(u8, 1), s[11].menu.active);
    try testing.expect(!s[12].menu.open and s[12].selected == 2);
}

var sem: [2]popover.Semantic(64) = .{ .{}, .{} };

test "Select: a combobox named by its caption, valued by its choice, with a listbox of options" {
    const h = &harness;
    h.init();
    const t = try setState(h, .{ .selected = 1, .menu = .{ .open = true, .active = 2 } });
    const cp = &h.ui.tables.t;
    // The caption is the row before the button.
    const caption = t.find(.from("shape")) - 1;
    semantics(t, sem[0].begin(), "shape", shapes, h.app.shape, caption);
    semantics(cp, sem[1].begin(), "shape", shapes, h.ui.signals.state.shape, caption);
    const e = sem[0].finish(t, &h.ctx.texts[h.ctx.cur], h.ctx.strings[h.ctx.cur].buf);
    try testing.expect(popover.sameSemantics(e, sem[1].finish(cp, &h.ui.tables.tx, h.ui.tables.strings.buf)));
    const row = struct {
        fn of(x: *const a11y.Export, tr: *const Tree, comptime id: []const u8) u32 {
            return popover.exportRow(x, tr.find(.from(id)));
        }
    }.of;
    const H = std.hash.Fnv1a_32;
    const b = row(e, t, "shape");
    try testing.expectEqual(@backingInt(a11y.Role.combobox), e.c.role[b]);
    try testing.expectEqual(H.hash("Shape"), e.c.name_hash[b]);
    try testing.expectEqual(@as(f32, 1), e.c.value[b]);
    try testing.expectEqual(a11y.State.bitsOf(.{ .expandable = true, .expanded = true }), e.c.state[b]);
    try testing.expectEqual(@backingInt(a11y.Role.listbox), e.c.role[row(e, t, "shape_panel")]);
    try testing.expectEqual(H.hash("Shape"), e.c.name_hash[row(e, t, "shape_panel")]);
    try testing.expectEqual(@backingInt(a11y.Role.option), e.c.role[row(e, t, "shape_square")]);
    try testing.expectEqual(H.hash("Square"), e.c.name_hash[row(e, t, "shape_square")]);
    try testing.expectEqual(a11y.State.bitsOf(.{ .selected = true }), e.c.state[row(e, t, "shape_square")]);
    try testing.expectEqual(@as(u8, 0), e.c.state[row(e, t, "shape_triangle")]);
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
