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
//! the chosen option's field. Or, in `base.ComptimeUi` beside any other widget:
//! `ct.select(th, .shape, .shape, opts)` in the flow and `ct.list(th, .shape, .shape, opts)`
//! last in the root, the options given by their captions (`Options`).

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

    /// Whether the list is shown: what `spec.when` over this field selects by (`ct.list`).
    pub fn visible(s: SelectState) bool {
        return s.menu.open;
    }
};

/// The options of a select known by their captions only (`ct.select`, HTML `<option>`), and
/// the headers of their groups (`<optgroup label>`).
pub const Options = struct {
    /// One caption per option, in order.
    texts: []const []const u8,
    /// Group headers, in order, each shown in the list before the option at `at`. A header
    /// is not an option: the keys and the pointer pass over it.
    groups: []const Group = &.{},
    /// Every option row's face (CSS on `<option>`), filled by `optionFaced`; null for
    /// `menu.itemStyle`'s.
    option: ?Style = null,
    /// Every option's text (text CSS on `<option>`); null for the label's.
    option_text: ?types.TextStyle = null,
};

pub const Group = struct { at: u8, label: []const u8 };

/// The `menu.Def` of `n` options named by position: "0", "1", ..., so option k's id is
/// `name_k`. For the runtime twin of `ct.select`: `button(f, th, "name", positional(n), ...)`.
pub fn positional(comptime n: usize) menu.Def {
    comptime {
        var items: [n][:0]const u8 = undefined;
        for (&items, 0..) |*it, k| it.* = std.fmt.comptimePrint("{d}", .{k});
        const out = items;
        return .{ .items = &out };
    }
}

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
    s.min = .{ 120, 0 };
    s.main = .start;
    return faced(th, s, r);
}

/// The button's `face` (its style, or as CSS restyles it) filled by its response, as a
/// button's is.
pub fn faced(th: *const Theme, face: Style, r: Response) Style {
    var s = face;
    s.fill = base.buttonFill(th, r);
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
    return optionFaced(th, menu.itemStyle(th, false), active, selected);
}

/// An option row laid out by `face` (CSS on `<option>`): its own fill while neither
/// highlighted nor chosen, else `optionFills`'.
pub fn optionFaced(th: *const Theme, face: Style, active: bool, selected: bool) Style {
    var fills = optionFills(th);
    fills[0] = face.fill;
    var s = face;
    s.fill = fills[(@as(u2, @intFromBool(active)) << 1) | @intFromBool(selected)];
    return s;
}

/// A group's header row: an option's padding, no fill.
pub fn headerStyle(th: *const Theme) Style {
    var s = menu.itemStyle(th, false);
    s.fill = .transparent;
    return s;
}

/// A group's header text: the label's, in the hot control colour (dimmer than the options).
pub fn headerText(th: *const Theme) types.TextStyle {
    var ts = base.labelText(th);
    ts.color = th.control_hot;
    return ts;
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
    return buttonFace(f, th, name, def, st, texts, buttonStyle(th, .{}));
}

/// `button` laid out by `face` instead of `buttonStyle`, as `spec.styled` restyles
/// `ct.select` (CSS on a `<select>`); the fill still follows hover and held.
pub fn buttonFace(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: menu.Def, st: *SelectState, texts: []const []const u8, face: Style) Response {
    std.debug.assert(texts.len == def.items.len);
    // Every response is asked for before anything is built, so the rows show the frame's
    // final state, as in the comptime front end.
    const inter = &f.ctx.inter;
    const r = inter.response(.from(name));
    var hits: menu.Hits = .{ .toggle = r.clicked, .outside = inter.response(.from(partName(name, "scrim"))).pressed };
    inline for (def.items, 0..) |o, k| hits.add(k, inter.response(.from(partName(name, o))));
    st.* = advance(def, st.*, hits, f.in.events);
    const b = f.open(.from(name), valued(faced(th, face, r), st.*));
    _ = f.interact(b, .button);
    role(f, b, .combobox);
    _ = base.label(f, th, texts[st.selected]);
    f.close();
    return r;
}

/// The list of select `name`, if it is open. Call it at the root's depth, after the rest of
/// the page, so it is drawn on top.
pub fn list(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: menu.Def, st: *const SelectState, texts: []const []const u8) void {
    listGrouped(f, th, name, def, st, texts, &.{});
}

/// `list`, with group headers (`Options.groups`) among the options.
pub fn listGrouped(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: menu.Def, st: *const SelectState, texts: []const []const u8, comptime groups: []const Group) void {
    listFace(f, th, name, def, st, texts, groups, menu.itemStyle(th, false), base.labelText(th));
}

/// `listGrouped` with every option row laid out by `face` (`optionFaced`) and its text in
/// `text`, as `Options.option` and `Options.option_text` restyle `ct.list` (CSS on `<option>`).
pub fn listFace(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: menu.Def, st: *const SelectState, texts: []const []const u8, comptime groups: []const Group, face: Style, text: types.TextStyle) void {
    if (!st.menu.open) return;
    _ = f.interact(f.open(.from(partName(name, "scrim")), popover.scrimStyle(f.in.viewport)), popover.overlay_sense);
    const l = f.open(.from(partName(name, "panel")), listStyle(th, f.lastRect(.from(name))));
    _ = f.interact(l, popover.overlay_sense);
    role(f, l, .listbox);
    inline for (def.items, 0..) |o, k| {
        inline for (groups) |g| if (g.at == k) {
            _ = f.open(.none, headerStyle(th));
            _ = f.text(g.label, headerText(th));
            f.close();
        };
        const row = f.open(.from(partName(name, o)), optionFaced(th, face, st.menu.active == k, st.selected == k));
        _ = f.interact(row, popover.overlay_sense);
        role(f, row, .option);
        _ = f.text(texts[k], text);
        f.close();
    }
    f.close();
    f.close();
}

// ---- comptime front end in base.ComptimeUi ----------------------------------------------------

/// The select as spec nodes of `base.ComptimeUi`: the button in the page's flow, and its list,
/// last in the page's root (so it is drawn above the rest), live while the list is open
/// (`spec.when` over the field, `SelectState.visible`). Their runtime twins are `button` and
/// `listGrouped` with `positional(opts.texts.len)`.
pub const ct = struct {
    /// The button of select `id`, bound to the `SelectState` field `field`, showing the chosen
    /// one of `opts.texts`.
    pub fn select(comptime th: Theme, comptime id: @EnumLiteral(), comptime field: @EnumLiteral(), comptime opts: Options) Spec {
        const W = Comptime(th, @tagName(id), @tagName(field), opts);
        return .{ .kind = .row, .style = buttonStyle(&th, .{}), .id = @tagName(id), .bind = @tagName(field), .widget = W.Button, .children = &.{.{ .kind = .label }} };
    }

    /// The scrim and the list of select `id`, with the same arguments as its `select`.
    pub fn list(comptime th: Theme, comptime id: @EnumLiteral(), comptime field: @EnumLiteral(), comptime opts: Options) Spec {
        return listOf(Comptime(th, @tagName(id), @tagName(field), opts), @tagName(id), field, opts);
    }

    /// `list` for the comptime select `W` (`ComptimeWith`), whose button draws another way.
    pub fn listOf(comptime W: type, comptime name: [:0]const u8, comptime field: @EnumLiteral(), comptime opts: Options) Spec {
        comptime var rows: []const Spec = &.{};
        inline for (opts.texts, 0..) |_, k| {
            inline for (opts.groups) |g| if (g.at == k) {
                rows = rows ++ .{Spec{ .kind = .col, .children = &.{.{ .kind = .label }} }};
            };
            rows = rows ++ .{Spec{ .kind = .row, .id = partName(name, W.def.items[k]), .children = &.{.{ .kind = .label }} }};
        }
        const panel: Spec = .{ .kind = .col, .id = partName(name, "panel"), .children = rows };
        return spec_zig.when(field, .{ .kind = .col, .id = partName(name, "scrim"), .widget = W.List, .children = &.{panel} });
    }
};

/// The custom widgets (`Spec.widget`) of `ct.select` and `ct.list`: the button's `step` reads
/// every part's response and the keys through `advance`, as `button` does at run time, and
/// keeps the button's rect for the list's `push`.
pub fn Comptime(comptime th: Theme, comptime id: [:0]const u8, comptime field: []const u8, comptime opts: Options) type {
    return ComptimeWith(th, id, field, opts, null);
}

/// `Comptime` whose button `Face.push` builds instead (a recipe's look, `recipes.ct.select`);
/// the list, the keys and the pointer stay this select's.
pub fn ComptimeWith(comptime th: Theme, comptime id: [:0]const u8, comptime field: []const u8, comptime opts: Options, comptime Face: ?type) type {
    if (opts.texts.len == 0) @compileError("select '" ++ id ++ "': no options");
    if (opts.texts.len >= menu.no_item) @compileError("select '" ++ id ++ "': too many options");
    return struct {
        pub const def = positional(opts.texts.len);

        pub const Button = struct {
            pub fn bindError(comptime State: type, comptime bound: []const u8) ?[]const u8 {
                return base.fieldError(State, "select", bound, SelectState);
            }

            pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
                const U = @TypeOf(ui.*);
                const at = ui.lastRect(row);
                ui.keep(Button).* = .{ at.x0, at.y0, at.x1, at.y1 };
                const scrim = comptime base_widgetRow(U, partName(id, "scrim"));
                var hits: menu.Hits = .{
                    .toggle = base.ctResponse(ui, row, event, in).clicked,
                    .outside = ui.pointer.pressed == @as(U.Events.Widget, @fromBackingInt(scrim)),
                };
                inline for (def.items, 0..) |o, k| hits.add(k, base.ctResponse(ui, comptime base_widgetRow(U, partName(id, o)), event, in));
                ui.signals.set(comptime U.field(field), advance(def, @field(ui.signals.state, field), hits, in.events));
            }

            pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
                if (Face) |F| return F.push(ui, n, parent, next, in);
                const tb = &ui.tables;
                const st: SelectState = @field(ui.signals.state, field);
                const b = tb.t.push(parent, .hash(id), &valued(faced(&th, n.style, ui.response(next.*, in)), st));
                tb.t.c.role[b] = @backingInt(a11y.Role.combobox);
                pushText(tb, b, opts.texts[st.selected], base.labelText(&th));
                tb.t.seal(b);
                next.* += comptime @import("../comptime/flatten.zig").count(n);
            }
        };

        pub const List = struct {
            pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
                const tb = &ui.tables;
                const t = &tb.t;
                const st: SelectState = @field(ui.signals.state, field);
                const k4 = ui.keep(Button).*;
                const sc = t.push(parent, .hash(partName(id, "scrim")), &popover.scrimStyle(in.viewport));
                const l = t.push(sc, .hash(partName(id, "panel")), &listStyle(&th, .{ .x0 = k4[0], .y0 = k4[1], .x1 = k4[2], .y1 = k4[3] }));
                t.c.role[l] = @backingInt(a11y.Role.listbox);
                inline for (def.items, 0..) |o, k| {
                    inline for (opts.groups) |g| if (g.at == k) {
                        const h = t.push(l, .none, &headerStyle(&th));
                        pushText(tb, h, g.label, headerText(&th));
                        t.seal(h);
                    };
                    const r = t.push(l, .hash(partName(id, o)), &optionFaced(&th, opts.option orelse menu.itemStyle(&th, false), st.menu.active == k, st.selected == k));
                    t.c.role[r] = @backingInt(a11y.Role.option);
                    pushText(tb, r, opts.texts[k], opts.option_text orelse base.labelText(&th));
                    t.seal(r);
                }
                t.seal(l);
                t.seal(sc);
                next.* += comptime @import("../comptime/flatten.zig").count(n);
            }
        };
    };
}

fn base_widgetRow(comptime Ui: type, comptime name: []const u8) u32 {
    return @backingInt(@field(Ui.Events.Widget, name));
}

/// A text leaf as `Frame.text` makes it, under tree row `parent` of the tables `tb`.
fn pushText(tb: anytype, parent: u32, str: []const u8, ts: types.TextStyle) void {
    const i = tb.t.push(parent, .none, &.{ .role = .label });
    tb.t.c.text[i] = tb.tx.push(i, tb.strings.add(str), &ts);
    tb.t.seal(i);
}

// ---- example page, replay and golden frames ---------------------------------------------------

/// The example's options.
pub const shapes: menu.Def = .{ .items = &.{ "circle", "square", "triangle" } };
pub const shape_texts = [_][]const u8{ "Circle", "Square", "Triangle" };

/// The example page: a toolbar with a caption and the select, and the select's list, in both
/// front ends, in theme `th`. The tests and the golden images (tools/golden/) run it.
pub fn Example(comptime th: Theme) type {
    return struct {
        pub const toolbar_style: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel };
        pub const page_style: Style = .{ .size = .{ .fill, .fill } };

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

/// The example page with the select as `ct.select` and `ct.list` in `base.ComptimeUi`, and,
/// for the group test, `groups` headers among its options; the runtime side is `Example`'s
/// app, or `listGrouped` with the same groups.
fn CtPage(comptime groups: []const Group) type {
    const th: Theme = .default;
    const E = Example(th);
    const opts: Options = .{ .texts = &shape_texts, .groups = groups };
    return struct {
        pub const App = struct {
            shape: SelectState = .{},

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, E.page_style);
                _ = f.open(.none, E.toolbar_style);
                _ = base.label(f, &th, "Shape");
                _ = button(f, &th, "shape", positional(3), &app.shape, &shape_texts);
                f.close();
                listGrouped(f, &th, "shape", positional(3), &app.shape, &shape_texts, groups);
                f.close();
            }
        };
        pub const State = struct { shape: SelectState = .{} };
        pub const spec = spec_zig.col(E.page_style, .{
            spec_zig.row(E.toolbar_style, .{ base.ct.label(th, "Shape"), ct.select(th, .shape, .shape, opts) }),
            ct.list(th, .shape, .shape, opts),
        });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, E.limits);
    };
}

fn expectCtReplay(h: anytype, last: u8) !void {
    const Replay = @import("../core/input.zig").Replay;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    var r: Replay = .{ .src = replay };
    var open: u32 = 0;
    while (try r.next(.{ .text = &text, .events = &evs, .contacts = &contacts })) |in| {
        _ = try h.frame(in);
        try testing.expectEqual(h.app.shape.selected, h.ui.signals.state.shape.selected);
        try testing.expectEqual(h.app.shape.menu.open, h.ui.signals.state.shape.menu.open);
        open += @intFromBool(h.app.shape.menu.open);
    }
    try testing.expect(open > 0);
    try testing.expectEqual(last, h.app.shape.selected);
}

var ct_harness: CtPage(&.{}).Run = .{};
var ct_grouped: CtPage(&.{ .{ .at = 0, .label = "Round" }, .{ .at = 1, .label = "Angular" } }).Run = .{};

test "ct.select, ct.list: the example replay in base.ComptimeUi gives the runtime select's frames" {
    // Triangle by keys, then Square by a click; Escape at the end keeps it.
    try expectCtReplay(&ct_harness, 1);
}

test "ct.list: group headers sit before their options in both front ends, and the keys pass over them" {
    // The first header moves the options down: the click at Square's place chooses Circle.
    try expectCtReplay(&ct_grouped, 0);
    const h = &ct_grouped;
    const st: SelectState = .{ .selected = 1, .menu = .{ .open = true, .active = 1 } };
    h.app.shape = st;
    h.ui.signals.set(.shape, st);
    const in: Input = .{ .viewport = .{ 400, 300 } };
    _ = try h.frame(&in);
    const t = (try h.frame(&in)).runtime.tree;
    // Header "Round", option 0, header "Angular", option 1, option 2: 2 + 2 + 2 + 2 + 2 rows.
    const panel = t.find(.from("shape_panel"));
    try testing.expectEqual(panel + 1 + 10, t.c.end[panel]);
    try testing.expect(t.find(.from("shape_0")) == panel + 3);
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
