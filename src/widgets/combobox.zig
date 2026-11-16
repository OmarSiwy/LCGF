//! Combo box (tier 2): a one-line text box with a list of options below it, the WAI-ARIA APG
//! editable combobox with list autocomplete. Written against the public API of tiers 0 and 1,
//! after the recipe in base.zig and from select.zig's parts: the list is a menu's list
//! (`menu.Def` holds the options, `menu.Menu`'s layer is the scrim and list spec), floating
//! under the root below the box (`Style.float`, `Style.offset`, prototype/ui.zig). What differs
//! from a select: the box holds text the user types, through src/text/edit/, and the list shows
//! only the options that start with it.
//!
//! Runtime: `input(...)` in the page's flow, then `list(...)` under the root after the page.
//!
//! Comptime: `const C = Combobox(th, .fruit, .fruit, .fruit_text, def);` gives the spec
//! builders `C.input` and `C.layer` and the hooks `popover.ComptimePage(State, spec, th, C)`
//! runs. The box's label shows the string field `fruit_text`, which the hooks keep equal to the
//! box's text.

const std = @import("std");
const base = @import("base.zig");
const popover = @import("popover.zig");
const menu = @import("menu.zig");
const types = @import("../core/types.zig");
const Input = @import("../core/input.zig").Input;
const Keyboard = @import("../interact/keyboard.zig").Keyboard;
const Editor = @import("../text/edit/edit.zig").Editor;
const Tree = @import("../core/tree.zig").Tree;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const a11y = @import("../a11y/tree.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Rect = types.Rect;
const Style = types.Style;
const Response = types.Response;
const Part = popover.Part;
const partName = popover.partName;
const no_item = menu.no_item;

// ---- spec: what the combo box takes and keeps -------------------------------------------------

/// Bytes the box holds.
pub const capacity = 24;

/// A combo box's state, owned by the application: plain data, copied by value, so both front
/// ends keep their own and the tests compare them.
pub const ComboState = struct {
    /// The box's text is `buf[0..len]`: the value.
    buf: [capacity]u8 = @splat(0),
    len: u8 = 0,
    /// The editor's caret and the other end of its selection, byte offsets into the text.
    caret: u8 = 0,
    anchor: u8 = 0,
    /// The option last chosen, by position, or `menu.no_item`; editing the text clears it.
    selected: u8 = no_item,
    /// The list is shown.
    open: bool = false,
    /// The highlighted option, by position, or `menu.no_item`.
    active: u8 = no_item,
    /// The option last under the pointer, or `menu.no_item` (as `menu.MenuState.hover`).
    hover: u8 = no_item,
    /// The box has the keyboard: a press on it gives it, a press elsewhere takes it.
    focused: bool = false,
    /// The left button was down last frame, so a press is told from a hold.
    down: bool = false,

    /// The box's text.
    pub fn text(st: *const ComboState) []const u8 {
        return st.buf[0..st.len];
    }

    /// Replaces the text with `s` (cut to `capacity` bytes), the caret at its end.
    pub fn setText(st: *ComboState, s: []const u8) void {
        const n: u8 = @intCast(@min(s.len, capacity));
        @memcpy(st.buf[0..n], s[0..n]);
        @memset(st.buf[n..], 0);
        st.len = n;
        st.caret = n;
        st.anchor = n;
    }
};

/// `null` if `State` can hold combo box `def` bound to `field`, its box showing `text`, else
/// the compile error: `field` must be a `ComboState`, `text` and every option's field strings,
/// and the options a flat list of at most 64 (the filter is one bit per option).
pub fn checkCombobox(comptime State: type, comptime def: menu.Def, comptime field: []const u8, comptime text: []const u8) ?[]const u8 {
    if (!@hasField(State, field)) return "combobox: state " ++ @typeName(State) ++ " has no field '" ++ field ++ "'";
    if (@FieldType(State, field) != ComboState) return "combobox: field '" ++ field ++ "' must be a combobox.ComboState";
    if (!@hasField(State, text) or @FieldType(State, text) != []const u8) return "combobox: the box needs a string field '" ++ text ++ "'";
    if (def.items.len == 0) return "combobox: no options";
    if (def.items.len > 64) return "combobox: more than 64 options";
    if (def.sub.len != 0 or def.sub_at != null) return "combobox: options are a flat list";
    for (def.items) |o| {
        if (!@hasField(State, o) or @FieldType(State, o) != []const u8) return "combobox: option '" ++ o ++ "' needs a string field of its name";
    }
    return null;
}

/// Combo box `name` with options `def`, bound to the `ComboState` field `field`, its box
/// showing the string field `text`, in theme `th`: its spec builders and the hooks
/// `popover.ComptimePage` calls.
pub fn Combobox(comptime th: Theme, comptime name: @EnumLiteral(), comptime field: @EnumLiteral(), comptime text: @EnumLiteral(), comptime def: menu.Def) type {
    const id = @tagName(name);
    const field_name = @tagName(field);
    return struct {
        /// The box, showing the string field `text`.
        pub fn input() Spec {
            return base.ct.button(th, name, text);
        }

        /// The scrim and the list, shown while it is open, as menu.zig builds a menu's. Put it
        /// last in the page's root so it is drawn above the rest.
        pub fn layer() Spec {
            return menu.Menu(th, name, field, def).layer();
        }

        pub fn check(comptime State: type) ?[]const u8 {
            return checkCombobox(State, def, field_name, @tagName(text));
        }

        /// The options' texts: their string fields.
        fn optionTexts(st: anytype) [def.items.len][]const u8 {
            var out: [def.items.len][]const u8 = undefined;
            inline for (def.items, 0..) |o, k| out[k] = @field(st, o);
            return out;
        }

        /// The box's, the scrim's and the options' responses, the rects of last frame and the
        /// keys, through `advance`; then the box's text field points at the state's text.
        pub fn step(sig: anytype, v: anytype) void {
            const p = v.in.pointer;
            var hits: Hits = .{
                .toggle = v.responseOf(id).clicked,
                .outside = v.responseOf(partName(id, "scrim")).pressed,
                .down = v.in.buttons.left,
                .inside = within(v.last.of(id), p) or within(v.last.of(partName(id, "panel")), p),
            };
            inline for (def.items, 0..) |o, k| hits.add(k, v.responseOf(partName(id, o)));
            const texts = optionTexts(sig.state);
            sig.set(field, advance(&texts, @field(sig.state, field_name), hits, v.in));
            sig.set(text, @field(sig.state, field_name).text());
        }

        pub fn part(comptime n: Spec, st: anytype, v: anytype) ?Part {
            const cs: ComboState = @field(st, field_name);
            if (comptime named(n, id)) return .{ .style = valued(inputStyle(&th, cs.focused, v.response), cs), .role = .combobox };
            if (comptime named(n, partName(id, "scrim"))) {
                if (!cs.open) return null;
                return .{ .style = popover.scrimStyle(v.in.viewport) };
            }
            if (comptime named(n, partName(id, "panel"))) return .{ .style = listStyle(&th, v.last.of(id)), .role = .listbox };
            inline for (def.items, 0..) |o, k| {
                if (comptime named(n, partName(id, o))) {
                    const texts = optionTexts(st);
                    if ((filter(&texts, cs.text()) >> k) & 1 == 0) return null;
                    return .{ .style = optionStyle(&th, cs.active == k, cs.selected == k), .role = .option };
                }
            }
            return popover.plainPart(th, n, v.response);
        }
    };
}

fn named(comptime n: Spec, comptime want: []const u8) bool {
    return n.id != null and std.mem.eql(u8, n.id.?, want);
}

// ---- look -------------------------------------------------------------------------------------

/// The box: a theme button filled by its response, at least 160 wide, its text at the start,
/// outlined in the accent colour while it has the keyboard (`focusBorders`).
pub fn inputStyle(th: *const Theme, focused: bool, r: Response) Style {
    var s = base.buttonStyle(th);
    s.fill = base.buttonFill(th, r);
    s.min = .{ 160, 0 };
    s.main = .start;
    s.border = 1;
    s.border_color = focusBorders(th)[@intFromBool(focused)];
    return s;
}

/// The box's outline, indexed by focus: the hot control colour, then the accent.
pub fn focusBorders(th: *const Theme) base.OnOff {
    return .{ th.control_hot, th.accent };
}

/// The list: menu.zig's list below the box's rect `at` (last frame's), at least as wide as the
/// box.
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

/// What the pointer did to a combo box this frame, from its parts' responses and last frame's
/// rects.
pub const Hits = struct {
    /// The box was clicked.
    toggle: bool = false,
    /// The pointer went down on the scrim, outside the list.
    outside: bool = false,
    /// The option clicked, or `menu.no_item`.
    clicked: u8 = no_item,
    /// The option under the pointer, or `menu.no_item`.
    hovered: u8 = no_item,
    /// The left button is down.
    down: bool = false,
    /// The pointer is over the box or the shown list.
    inside: bool = false,

    /// Notes option `k`'s response.
    pub fn add(h: *Hits, k: u8, r: Response) void {
        if (r.clicked) h.clicked = k;
        if (r.hovered) h.hovered = k;
    }
};

/// Whether `p` is inside `r` (an empty rect holds nothing).
pub fn within(r: Rect, p: [2]f32) bool {
    return p[0] >= r.x0 and p[0] < r.x1 and p[1] >= r.y0 and p[1] < r.y1;
}

/// The options shown for `typed`: those whose text starts with it, ASCII case folded, one bit
/// per option (all of them for no text).
pub fn filter(texts: []const []const u8, typed: []const u8) u64 {
    var m: u64 = 0;
    for (texts, 0..) |t, k| m |= @as(u64, @intFromBool(std.ascii.startsWithIgnoreCase(t, typed))) << @intCast(k);
    return m;
}

/// The next shown option after `from` (before it when `back`), wrapping, among `n`; from
/// `menu.no_item` the first (last) shown one; `menu.no_item` when none is shown.
pub fn nextShown(shown: u64, n: u8, from: u8, back: bool) u8 {
    if (shown == 0) return no_item;
    const step: u8 = if (back) n - 1 else 1;
    var k: u8 = if (from != no_item) from else if (back) 0 else n - 1;
    while (true) {
        k = (k + step) % n;
        if ((shown >> @intCast(k)) & 1 != 0) return k;
    }
}

/// The id the box's editor reads its keys as (a `Keyboard` aimed at it while focused).
const edit_id = types.Id.from("combobox");

/// Applies this frame's keys to the box's text through src/text/edit/ (one line), all but the
/// list's keys (Up, Down, Enter, Escape), which `advance` reads. True when the text changed.
fn edit(s: *ComboState, in: *const Input) bool {
    const k = popover.keys;
    var taken: u64 = 0;
    for (in.events[0..@min(in.events.len, 64)], 0..) |e, i| {
        const list_key = e.code == k.up or e.code == k.down or e.code == k.enter or e.code == k.escape;
        taken |= @as(u64, @intFromBool(e.kind != .text and list_key)) << @intCast(i);
    }
    const kb: Keyboard = .{ .in = in, .target = @backingInt(edit_id), .taken = taken };
    var ed: Editor = .{ .b = .{ .buf = &s.buf, .gap = s.len }, .caret = s.caret, .anchor = s.anchor, .mode = .{ .single_line = true } };
    const r = ed.update(&kb, edit_id, .{});
    // The gap to the end, the rest zeroed: equal texts are equal states.
    s.len = @intCast(ed.text().len);
    @memset(s.buf[s.len..], 0);
    s.caret = @intCast(ed.caret);
    s.anchor = @intCast(ed.anchor);
    return r.changed;
}

/// Choosing option `k`: its text becomes the box's, it becomes the selection, the list closes.
fn choose(s: *ComboState, texts: []const []const u8, k: u8) void {
    s.setText(texts[k]);
    s.selected = k;
    s.open = false;
}

/// One frame of a combo box (APG editable combobox with list autocomplete, manual selection).
/// A press on the box or the list gives it the keyboard, a press elsewhere takes it. The box's
/// click toggles the list (opening on the chosen option if it is shown), a press outside
/// closes it, the pointer reaching a shown option highlights it, a click chooses it. While
/// focused, typing edits the text (src/text/edit/: Left, Right, Home, End, Backspace, Delete,
/// select-all, ...), which clears the choice, opens the list and filters it to the options
/// starting with the text; then, in order, Down and Up open the list or move the highlight
/// among the shown options, wrapping, Enter chooses the highlighted option (its text becomes
/// the box's), Escape closes the list, or with the list closed clears the text. Within one
/// frame the text edits come before the list's keys.
pub fn advance(texts: []const []const u8, st: ComboState, hits: Hits, in: *const Input) ComboState {
    const n: u8 = @intCast(texts.len);
    var s = st;
    const press = hits.down and !st.down;
    s.down = hits.down;
    if (press) s.focused = hits.inside;
    if (hits.outside) s.open = false;
    if (hits.toggle) {
        s.open = !st.open;
        const shown = filter(texts, s.text());
        const on_choice = st.selected != no_item and (shown >> @intCast(st.selected)) & 1 != 0;
        s.active = if (on_choice) st.selected else no_item;
        s.hover = no_item;
    }
    if (s.open and hits.hovered != s.hover) {
        if (hits.hovered != no_item) s.active = hits.hovered;
        s.hover = hits.hovered;
    }
    if (s.open and hits.clicked != no_item) choose(&s, texts, hits.clicked);
    if (s.focused) {
        if (edit(&s, in)) {
            s.selected = no_item;
            s.open = true;
            s.active = no_item;
        }
        const shown = filter(texts, s.text());
        const k = popover.keys;
        for (in.events) |e| {
            if (e.kind != .press and e.kind != .repeat) continue;
            switch (e.code) {
                k.down, k.up => {
                    s.active = if (s.open) nextShown(shown, n, s.active, e.code == k.up) else nextShown(shown, n, no_item, e.code == k.up);
                    s.open = true;
                },
                k.enter => if (s.open and s.active != no_item) choose(&s, texts, s.active),
                k.escape => if (s.open) {
                    s.open = false;
                } else {
                    s.setText("");
                    s.selected = no_item;
                },
                else => {},
            }
        }
    }
    if (!s.open) {
        s.active = no_item;
        s.hover = no_item;
    }
    return s;
}

// ---- accessibility ------------------------------------------------------------------------------

/// The box's style with the value column set: the chosen option's position, -1 for none (the
/// text itself is the box's content, its label).
pub fn valued(s: Style, st: ComboState) Style {
    var out = s;
    out.value = if (st.selected == no_item) -1 else @floatFromInt(st.selected);
    return out;
}

/// The semantics of combo box `name` the tree's columns cannot hold, written into `s` after
/// `Semantics.clear` and before `a11y.names` and `a11y.states`. The columns hold the roles
/// (the box `combobox`, valued by `valued`; the list `listbox`; the shown options `option`,
/// named by their text). Here: the combobox is named by the row `label` (its caption,
/// `aria-labelledby`; `none` for none), is expandable and expanded while the list is shown
/// (`aria-expanded`), and names the list; the highlighted option is `selected`, as the APG
/// combobox marks the option the arrows reach (`aria-selected`). Works on either front end's
/// tree.
pub fn semantics(t: *const Tree, s: *a11y.Semantics, comptime name: []const u8, comptime def: menu.Def, st: ComboState, label: u32) void {
    const b = t.find(.from(name));
    if (b == types.none) return;
    const l = t.find(.from(partName(name, "panel")));
    s.c.state[b] |= a11y.State.bitsOf(.{ .expandable = true, .expanded = l != types.none });
    if (label != types.none) s.c.labelled_by[b] = label;
    if (l == types.none) return;
    s.c.labelled_by[l] = if (label != types.none) label else b;
    inline for (def.items, 0..) |o, k| {
        const row = t.find(.from(partName(name, o)));
        if (row != types.none and st.active == k) s.c.state[row] |= a11y.State.bitsOf(.{ .selected = true });
    }
}

fn role(f: *Frame, n: types.Node, r: a11y.Role) void {
    f.tree().c.role[n.ix()] = @backingInt(r);
}

// ---- runtime front end ------------------------------------------------------------------------

/// The box of combo box `name` (options `def`, labelled `texts`), in the page's flow, showing
/// its text.
pub fn input(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: menu.Def, st: *ComboState, texts: []const []const u8) Response {
    std.debug.assert(texts.len == def.items.len);
    // Every response is asked for before anything is built, so the rows show the frame's
    // final state, as in the comptime front end.
    const inter = &f.ctx.inter;
    const r = inter.response(.from(name));
    const p = f.in.pointer;
    var hits: Hits = .{
        .toggle = r.clicked,
        .outside = inter.response(.from(partName(name, "scrim"))).pressed,
        .down = f.in.buttons.left,
        .inside = within(f.lastRect(.from(name)), p) or within(f.lastRect(.from(partName(name, "panel"))), p),
    };
    inline for (def.items, 0..) |o, k| hits.add(k, inter.response(.from(partName(name, o))));
    st.* = advance(texts, st.*, hits, f.in);
    const b = f.open(.from(name), valued(inputStyle(th, st.focused, r), st.*));
    _ = f.interact(b, .button);
    role(f, b, .combobox);
    _ = base.label(f, th, st.text());
    f.close();
    return r;
}

/// The list of combo box `name`, if it is open. Call it at the root's depth, after the rest of
/// the page, so it is drawn on top.
pub fn list(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: menu.Def, st: *const ComboState, texts: []const []const u8) void {
    if (!st.open) return;
    _ = f.interact(f.open(.from(partName(name, "scrim")), popover.scrimStyle(f.in.viewport)), popover.overlay_sense);
    const l = f.open(.from(partName(name, "panel")), listStyle(th, f.lastRect(.from(name))));
    _ = f.interact(l, popover.overlay_sense);
    role(f, l, .listbox);
    const shown = filter(texts, st.text());
    inline for (def.items, 0..) |o, k| {
        if ((shown >> k) & 1 != 0) {
            const row = f.open(.from(partName(name, o)), optionStyle(th, st.active == k, st.selected == k));
            _ = f.interact(row, popover.overlay_sense);
            role(f, row, .option);
            _ = base.label(f, th, texts[k]);
            f.close();
        }
    }
    f.close();
    f.close();
}

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;

const fruits: menu.Def = .{ .items = &.{ "apple", "apricot", "banana", "cherry" } };
const fruit_texts = [_][]const u8{ "Apple", "Apricot", "Banana", "Cherry" };

/// The test page: a toolbar with a caption and the combo box, and the combo box's list.
fn Page(comptime th: Theme) type {
    return struct {
        const toolbar_style: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel };
        const page_style: Style = .{ .size = .{ .fill, .fill } };

        pub const App = struct {
            fruit: ComboState = .{},

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, page_style);
                _ = f.open(.none, toolbar_style);
                _ = base.label(f, &th, "Fruit");
                _ = input(f, &th, "fruit", fruits, &app.fruit, &fruit_texts);
                f.close();
                list(f, &th, "fruit", fruits, &app.fruit, &fruit_texts);
                f.close();
            }
        };

        pub const State = struct {
            fruit: ComboState = .{},
            caption: []const u8 = "Fruit",
            fruit_text: []const u8 = "",
            apple: []const u8 = "Apple",
            apricot: []const u8 = "Apricot",
            banana: []const u8 = "Banana",
            cherry: []const u8 = "Cherry",
        };
        pub const C = Combobox(th, .fruit, .fruit, .fruit_text, fruits);
        pub const spec = spec_zig.col(page_style, .{
            spec_zig.row(toolbar_style, .{ base.ct.label(th, .caption), C.input() }),
            C.layer(),
        });
        pub const Ui = popover.ComptimePage(State, spec, th, C);
        pub const limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

/// Sets the combo box's state in both front ends of `h` (and the comptime box's text, which
/// points into that state) and builds two frames (the second sees the first's rects); returns
/// the second's tree.
fn setState(h: anytype, st: ComboState) !*const Tree {
    const in: Input = .{ .viewport = .{ 400, 300 } };
    h.app.fruit = st;
    h.ui.signals.set(.fruit, st);
    h.ui.signals.set(.fruit_text, h.ui.signals.state.fruit.text());
    _ = try h.frame(&in);
    return (try h.frame(&in)).runtime.tree;
}

fn withText(s: []const u8) ComboState {
    var st: ComboState = .{};
    st.setText(s);
    return st;
}

test "Combobox: the page agrees in both front ends, closed and open" {
    const h = &harness;
    h.init();
    var t = try setState(h, withText("Banana"));
    try testing.expectEqual(@as(u32, 6), t.len);
    var st = withText("Ap");
    st.open = true;
    t = try setState(h, st);
    try testing.expectEqual(@as(u32, 6 + 2 + 2 * 2), t.len); // Apple, Apricot
    const at = t.rect(t.find(.from("fruit")));
    try testing.expectEqual(at.x0, t.rect(t.find(.from("fruit_panel"))).x0);
}

test "inputStyle, listStyle, optionStyle: the theme's tokens" {
    const th: Theme = .default;
    try testing.expectEqual(th.control_hot, inputStyle(&th, false, .{ .hovered = true }).fill);
    try testing.expectEqual([2]f32{ 160, 0 }, inputStyle(&th, false, .{}).min);
    try testing.expectEqual(th.control_hot, inputStyle(&th, false, .{}).border_color);
    try testing.expectEqual(th.accent, inputStyle(&th, true, .{}).border_color);
    const l = listStyle(&th, .{ .x0 = 10, .y0 = 0, .x1 = 190, .y1 = 30 });
    try testing.expectEqual([2]f32{ 180, 0 }, l.min);
    try testing.expectEqual(th.panel, l.fill);
    try testing.expectEqual(types.Color.transparent, optionStyle(&th, false, false).fill);
    try testing.expectEqual(th.control, optionStyle(&th, false, true).fill);
    try testing.expectEqual(th.control_hot, optionStyle(&th, true, false).fill);
    try testing.expectEqual(th.control_hot, optionStyle(&th, true, true).fill);
}

const light: Theme = .{ .panel = .rgb(240, 240, 240), .control = .rgb(200, 200, 205), .control_hot = .rgb(180, 180, 190), .text = .rgb(20, 20, 20), .accent = .rgb(0, 90, 200), .pad = 12, .gap = 10, .radius = 0 };

test "Combobox: another theme restyles both front ends alike" {
    const S = struct {
        var h: Page(light).Run = .{};
    };
    S.h.init();
    var st = withText("Ap");
    st.open = true;
    st.focused = true;
    st.selected = 1;
    st.active = 0;
    const t = try setState(&S.h, st);
    try testing.expectEqual(light.control.bitsOf(), t.c.look[t.find(.from("fruit_apricot"))].fill);
    try testing.expectEqual(light.control_hot.bitsOf(), t.c.look[t.find(.from("fruit_apple"))].fill);
    try testing.expectEqual(light.accent.bitsOf(), t.c.look[t.find(.from("fruit"))].border_color);
    // The list is at least as wide as the box.
    try testing.expect(t.rect(t.find(.from("fruit_panel"))).w() >= t.rect(t.find(.from("fruit"))).w());
}

test "filter, nextShown: options starting with the text; moves among them, wrapping" {
    try testing.expectEqual(@as(u64, 0b1111), filter(&fruit_texts, ""));
    try testing.expectEqual(@as(u64, 0b0011), filter(&fruit_texts, "aP"));
    try testing.expectEqual(@as(u64, 0b0010), filter(&fruit_texts, "apr"));
    try testing.expectEqual(@as(u64, 0), filter(&fruit_texts, "kiwi"));
    try testing.expectEqual(@as(u8, 2), nextShown(0b1100, 4, no_item, false));
    try testing.expectEqual(@as(u8, 3), nextShown(0b1100, 4, 2, false));
    try testing.expectEqual(@as(u8, 2), nextShown(0b1100, 4, 3, false));
    try testing.expectEqual(@as(u8, 3), nextShown(0b1100, 4, no_item, true));
    try testing.expectEqual(@as(u8, 3), nextShown(0b1100, 4, 2, true));
    try testing.expectEqual(no_item, nextShown(0, 4, no_item, false));
}

/// `advance` over the frames of replay `src` (focused, no pointer), from `st`.
fn typeIn(st: ComboState, src: []const u8) !ComboState {
    const Replay = @import("../core/input.zig").Replay;
    var text: [32]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    var r: Replay = .{ .src = src };
    var s = st;
    while (try r.next(.{ .text = &text, .events = &evs, .contacts = &contacts })) |in| s = advance(&fruit_texts, s, .{}, in);
    return s;
}

test "advance: typing filters and opens; arrows move among the shown options; Enter chooses" {
    const focused: ComboState = .{ .focused = true };
    var s = try typeIn(focused, "frame\ntext ap\n");
    try testing.expectEqualStrings("ap", s.text());
    try testing.expect(s.open and s.active == no_item);
    s = try typeIn(s, "frame\npress 81\nframe\npress 81\nframe\npress 81\n"); // Apple, Apricot, Apple
    try testing.expectEqual(@as(u8, 0), s.active);
    s = try typeIn(s, "frame\npress 82\npress 40\n"); // Up wraps to Apricot; Enter
    try testing.expectEqualStrings("Apricot", s.text());
    try testing.expect(!s.open and s.selected == 1 and s.caret == 7);
    s = try typeIn(s, "frame\npress 42\n"); // Backspace: edited, the choice cleared
    try testing.expectEqualStrings("Aprico", s.text());
    try testing.expect(s.open and s.selected == no_item);
    s = try typeIn(s, "frame\npress 41\nframe\npress 41\n"); // Escape closes, then clears
    try testing.expectEqualStrings("", s.text());
    try testing.expect(!s.open);
    s = try typeIn(s, "frame\npress 82\n"); // Up opens on the last option
    try testing.expect(s.open and s.active == 3);
    // Unfocused, keys do nothing.
    s = try typeIn(.{}, "frame\ntext b\npress 81\n");
    try testing.expect(s.len == 0 and !s.open);
}

test "advance: a press on the box focuses, elsewhere unfocuses; a click on an option chooses" {
    var s = advance(&fruit_texts, .{}, .{ .down = true, .inside = true }, &.{});
    try testing.expect(s.focused);
    s = advance(&fruit_texts, s, .{ .toggle = true }, &.{});
    try testing.expect(s.open and !s.down);
    s = advance(&fruit_texts, s, .{ .hovered = 2 }, &.{});
    try testing.expectEqual(@as(u8, 2), s.active);
    s = advance(&fruit_texts, s, .{ .hovered = 2, .clicked = 2 }, &.{});
    try testing.expectEqualStrings("Banana", s.text());
    try testing.expect(!s.open and s.selected == 2 and s.focused);
    s = advance(&fruit_texts, s, .{ .toggle = true }, &.{});
    try testing.expectEqual(@as(u8, 2), s.active); // reopens on the choice
    s = advance(&fruit_texts, s, .{ .down = true, .outside = true }, &.{});
    try testing.expect(!s.open and !s.focused);
}

const Aim = union(enum) { part: []const u8, at: [2]f32 };
const Step = struct { aim: Aim, left: bool = false, key: ?u8 = null, text: []const u8 = "" };

/// Runs `script` through both front ends, aiming at last frame's rects, with the combo box's
/// state and the box's text equal in both after every step; returns the state after each.
fn runScript(comptime n: usize, script: [n]Step) ![n]ComboState {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 400, 300 } };
    var ev: [2]Input.Event = undefined;
    var last = (try h.frame(&in)).runtime.tree;
    var out: [n]ComboState = undefined;
    for (script, &out) |st, *o| {
        in.pointer = switch (st.aim) {
            .at => |p| p,
            .part => |name| blk: {
                const r = last.rect(last.find(.hash(name)));
                break :blk .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
            },
        };
        in.buttons.left = st.left;
        in.text = st.text;
        var k: usize = 0;
        if (st.text.len != 0) {
            ev[k] = .{ .kind = .text, .len = @intCast(st.text.len) };
            k += 1;
        }
        if (st.key) |code| {
            ev[k] = .{ .kind = .press, .code = code };
            k += 1;
        }
        in.events = ev[0..k];
        last = (try h.frame(&in)).runtime.tree;
        try testing.expectEqual(h.app.fruit, h.ui.signals.state.fruit);
        try testing.expectEqualStrings(h.app.fruit.text(), h.ui.signals.state.fruit_text);
        o.* = h.app.fruit;
    }
    return out;
}

test "Combobox: focus, typing, arrows, Enter, clicks and Escape in both front ends" {
    const k = popover.keys;
    const s = try runScript(12, .{
        .{ .aim = .{ .part = "fruit" }, .left = true }, // focus
        .{ .aim = .{ .part = "fruit" } }, // click: the list opens, all shown
        .{ .aim = .{ .part = "fruit" }, .text = "a" }, // Apple, Apricot
        .{ .aim = .{ .part = "fruit" }, .text = "pr" }, // Apricot
        .{ .aim = .{ .part = "fruit" }, .key = k.down },
        .{ .aim = .{ .part = "fruit" }, .key = k.enter }, // chosen
        .{ .aim = .{ .part = "fruit" }, .key = k.escape }, // cleared
        .{ .aim = .{ .part = "fruit" }, .key = k.down }, // opens on Apple
        .{ .aim = .{ .part = "fruit_cherry" } }, // the pointer reaches Cherry
        .{ .aim = .{ .part = "fruit_cherry" }, .left = true },
        .{ .aim = .{ .part = "fruit_cherry" } }, // chosen by click
        .{ .aim = .{ .at = .{ 390, 290 } }, .left = true }, // press elsewhere: unfocused
    });
    try testing.expect(s[0].focused and !s[0].open);
    try testing.expect(s[1].open);
    try testing.expectEqualStrings("a", s[2].text());
    try testing.expectEqual(no_item, s[3].active);
    try testing.expectEqual(@as(u8, 1), s[4].active);
    try testing.expect(!s[5].open and s[5].selected == 1);
    try testing.expectEqualStrings("Apricot", s[5].text());
    try testing.expectEqual(@as(u8, 0), s[6].len);
    try testing.expect(s[7].open and s[7].active == 0);
    try testing.expectEqual(@as(u8, 3), s[8].active);
    try testing.expectEqualStrings("Cherry", s[10].text());
    try testing.expect(!s[10].open and s[10].selected == 3 and s[10].focused);
    try testing.expect(!s[11].focused);
}

var sem: [2]popover.Semantic(64) = .{ .{}, .{} };

test "Combobox: a combobox named by its caption, valued by its choice, with a listbox of shown options" {
    const h = &harness;
    h.init();
    var st = withText("Ap");
    st.open = true;
    st.active = 1;
    st.selected = 0;
    const t = try setState(h, st);
    const cp = &h.ui.tables.t;
    // The caption is the row before the box.
    const caption = t.find(.from("fruit")) - 1;
    semantics(t, sem[0].begin(), "fruit", fruits, h.app.fruit, caption);
    semantics(cp, sem[1].begin(), "fruit", fruits, h.ui.signals.state.fruit, caption);
    const e = sem[0].finish(t, &h.ctx.texts[h.ctx.cur], h.ctx.strings[h.ctx.cur].buf);
    try testing.expect(popover.sameSemantics(e, sem[1].finish(cp, &h.ui.tables.tx, h.ui.tables.strings.buf)));
    const row = struct {
        fn of(x: *const a11y.Export, tr: *const Tree, comptime id: []const u8) u32 {
            return popover.exportRow(x, tr.find(.from(id)));
        }
    }.of;
    const H = std.hash.Fnv1a_32;
    const b = row(e, t, "fruit");
    try testing.expectEqual(@backingInt(a11y.Role.combobox), e.c.role[b]);
    try testing.expectEqual(H.hash("Fruit"), e.c.name_hash[b]);
    try testing.expectEqual(@as(f32, 0), e.c.value[b]);
    try testing.expectEqual(a11y.State.bitsOf(.{ .expandable = true, .expanded = true }), e.c.state[b]);
    try testing.expectEqual(@backingInt(a11y.Role.listbox), e.c.role[row(e, t, "fruit_panel")]);
    try testing.expectEqual(H.hash("Fruit"), e.c.name_hash[row(e, t, "fruit_panel")]);
    try testing.expectEqual(@backingInt(a11y.Role.option), e.c.role[row(e, t, "fruit_apricot")]);
    try testing.expectEqual(H.hash("Apricot"), e.c.name_hash[row(e, t, "fruit_apricot")]);
    try testing.expectEqual(a11y.State.bitsOf(.{ .selected = true }), e.c.state[row(e, t, "fruit_apricot")]);
    try testing.expectEqual(@as(u8, 0), e.c.state[row(e, t, "fruit_apple")]);
    // Filtered out: not in the tree, not exported.
    try testing.expectEqual(types.none, t.find(.from("fruit_banana")));
    // Closed, no choice: collapsed, value -1.
    const t2 = try setState(h, withText("Kiwi"));
    semantics(t2, sem[0].begin(), "fruit", fruits, h.app.fruit, caption);
    const e2 = sem[0].finish(t2, &h.ctx.texts[h.ctx.cur], h.ctx.strings[h.ctx.cur].buf);
    const b2 = row(e2, t2, "fruit");
    try testing.expectEqual(@as(f32, -1), e2.c.value[b2]);
    try testing.expectEqual(a11y.State.bitsOf(.{ .expandable = true }), e2.c.state[b2]);
}

test "ComboState.setText: cut to the capacity, the caret at the end" {
    var st = withText("Cherry");
    try testing.expectEqualStrings("Cherry", st.text());
    try testing.expectEqual(@as(u8, 6), st.caret);
    const long: [40]u8 = @splat('x');
    st.setText(&long);
    try testing.expectEqual(@as(u8, capacity), st.len);
    try testing.expectEqual(st.len, st.anchor);
}

test "checkCombobox: the state field, the box's text and the options" {
    try testing.expectEqual(null, comptime checkCombobox(Default.State, fruits, "fruit", "fruit_text"));
    try testing.expectEqualStrings("combobox: field 'fruit' must be a combobox.ComboState", comptime checkCombobox(struct { fruit: u8 }, fruits, "fruit", "fruit_text").?);
    try testing.expectEqualStrings("combobox: the box needs a string field 'fruit_text'", comptime checkCombobox(struct { fruit: ComboState }, fruits, "fruit", "fruit_text").?);
    try testing.expectEqualStrings("combobox: options are a flat list", comptime checkCombobox(Default.State, .{ .items = &.{"apple"}, .sub_at = 0, .sub = &.{"banana"} }, "fruit", "fruit_text").?);
    try testing.expectEqualStrings("combobox: option 'kiwi' needs a string field of its name", comptime checkCombobox(Default.State, .{ .items = &.{"kiwi"} }, "fruit", "fruit_text").?);
}

test {
    std.testing.refAllDecls(@This());
}
