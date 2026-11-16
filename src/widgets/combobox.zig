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
const Tree = @import("../core/tree.zig").Tree;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
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

        pub fn step(sig: anytype, v: anytype) void {
            _ = .{ sig, v };
        }

        pub fn part(comptime n: Spec, st: anytype, v: anytype) ?Part {
            const cs: ComboState = @field(st, field_name);
            if (comptime named(n, id)) return .{ .style = inputStyle(&th, cs.focused, v.response) };
            if (comptime named(n, partName(id, "scrim"))) {
                if (!cs.open) return null;
                return .{ .style = popover.scrimStyle(v.in.viewport) };
            }
            if (comptime named(n, partName(id, "panel"))) return .{ .style = listStyle(&th, v.last.of(id)) };
            inline for (def.items, 0..) |o, k| {
                if (comptime named(n, partName(id, o))) return .{ .style = optionStyle(&th, cs.active == k, cs.selected == k) };
            }
            return popover.plainPart(th, n, v.response);
        }
    };
}

fn named(comptime n: Spec, comptime want: []const u8) bool {
    return n.id != null and std.mem.eql(u8, n.id.?, want);
}

// ---- look -------------------------------------------------------------------------------------

/// The box: a theme button.
pub fn inputStyle(th: *const Theme, focused: bool, r: Response) Style {
    _ = focused;
    var s = base.buttonStyle(th);
    s.fill = base.buttonFill(th, r);
    return s;
}

/// The list, below the box's rect `at` (last frame's).
pub fn listStyle(th: *const Theme, at: Rect) Style {
    return menu.listStyle(th, at);
}

/// An option row.
pub fn optionStyle(th: *const Theme, active: bool, selected: bool) Style {
    _ = selected;
    return menu.itemStyle(th, active);
}

// ---- runtime front end ------------------------------------------------------------------------

/// The box of combo box `name` (options `def`, labelled `texts`), in the page's flow, showing
/// its text.
pub fn input(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: menu.Def, st: *ComboState, texts: []const []const u8) Response {
    std.debug.assert(texts.len == def.items.len);
    const r = f.ctx.inter.response(.from(name));
    const b = f.open(.from(name), inputStyle(th, st.focused, r));
    _ = f.interact(b, .button);
    _ = base.label(f, th, st.text());
    f.close();
    return r;
}

/// The list of combo box `name`, if it is open. Call it at the root's depth, after the rest of
/// the page, so it is drawn on top.
pub fn list(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: menu.Def, st: *const ComboState, texts: []const []const u8) void {
    if (!st.open) return;
    _ = f.interact(f.open(.from(partName(name, "scrim")), popover.scrimStyle(f.in.viewport)), popover.overlay_sense);
    _ = f.interact(f.open(.from(partName(name, "panel")), listStyle(th, f.lastRect(.from(name)))), popover.overlay_sense);
    inline for (def.items, 0..) |o, k| {
        _ = f.interact(f.open(.from(partName(name, o)), optionStyle(th, st.active == k, st.selected == k)), popover.overlay_sense);
        _ = base.label(f, th, texts[k]);
        f.close();
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
    try testing.expectEqual(@as(u32, 6 + 2 + 2 * 4), t.len);
    const at = t.rect(t.find(.from("fruit")));
    try testing.expectEqual(at.x0, t.rect(t.find(.from("fruit_panel"))).x0);
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
