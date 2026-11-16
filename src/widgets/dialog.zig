//! Dialog (tier 2): a modal window over the page, with a title, a message and buttons, the
//! WAI-ARIA APG modal dialog pattern. Written against the public API of tiers 0 and 1, after
//! the recipe in base.zig. The dialog sits centred on a backdrop, a float the size of the
//! viewport (`Style.float`), which takes the pointer so the page under it is inert.
//!
//! Focus stays inside the dialog while it is open (the APG's focus trap): which of its buttons
//! has focus is part of the dialog's state, `DialogState.focus`, and Tab moves it among them
//! only. The runtime front end's `Interaction.focus` is not used, so the comptime front end
//! (which has none) keeps the same state (prototype/ui.zig, `Interaction.focus`, is where the
//! pointer would set it).
//!
//! Runtime: `trigger` in the page's flow, then `show(...)` under the root after the page.
//!
//! Comptime: `const D = Dialog(th, .delete, .dialog, def);` gives the spec builders `D.button`
//! and `D.layer` and the hooks `popover.ComptimePage(State, spec, th, D)` runs.

const std = @import("std");
const base = @import("base.zig");
const popover = @import("popover.zig");
const types = @import("../core/types.zig");
const Input = @import("../core/input.zig").Input;
const Tree = @import("../core/tree.zig").Tree;
const Frame = @import("../runtime/frame.zig").Frame;
const context = @import("../runtime/context.zig");
const spec_zig = @import("../comptime/spec.zig");
const a11y = @import("../a11y/tree.zig");
const focus = @import("../interact/focus.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Rect = types.Rect;
const Style = types.Style;
const Color = types.Color;
const Response = types.Response;
const Part = popover.Part;
const partName = popover.partName;

// ---- spec: what the dialog takes and keeps ---------------------------------------------------

/// A dialog's buttons, fixed when compiling, in focus order. Each has a name: its id is
/// `dialog_button`, and in the comptime front end its label shows the string field of that
/// name. The title and the message show string fields the spec names.
pub const Def = struct {
    buttons: []const [:0]const u8,
};

/// A dialog's state, owned by the application.
pub const DialogState = struct {
    open: bool = false,
    /// The button with focus, by position.
    focus: u8 = 0,
    /// The button chosen this frame, by position plus one; 0 when none. Escape closes the
    /// dialog with 0.
    result: u8 = 0,
};

/// `null` if `State` can hold dialog `def` bound to `field`, else the compile error.
pub fn checkDialog(comptime State: type, comptime def: Def, comptime field: []const u8) ?[]const u8 {
    if (!@hasField(State, field)) return "dialog: state " ++ @typeName(State) ++ " has no field '" ++ field ++ "'";
    if (@FieldType(State, field) != DialogState) return "dialog: field '" ++ field ++ "' must be a dialog.DialogState";
    if (def.buttons.len == 0) return "dialog: no buttons";
    if (def.buttons.len >= 0xff) return "dialog: too many buttons";
    for (def.buttons) |b| {
        if (!@hasField(State, b) or @FieldType(State, b) != []const u8) return "dialog: button '" ++ b ++ "' needs a string field of its name";
    }
    return null;
}

/// Dialog `name` with buttons `def`, bound to the `DialogState` field `field`, in theme `th`:
/// its spec builders and the hooks `popover.ComptimePage` calls.
pub fn Dialog(comptime th: Theme, comptime name: @EnumLiteral(), comptime field: @EnumLiteral(), comptime def: Def) type {
    const id = @tagName(name);
    const field_name = @tagName(field);
    return struct {
        /// The button that opens the dialog, showing the string field `text`.
        pub fn button(comptime text: @EnumLiteral()) Spec {
            return base.ct.button(th, name, text);
        }

        /// The backdrop and the dialog showing the string fields `title` and `message`, then
        /// its buttons. Put it last in the page's root so it is drawn above the rest.
        pub fn layer(comptime title: @EnumLiteral(), comptime message: @EnumLiteral()) Spec {
            var buttons: [def.buttons.len]Spec = undefined;
            for (&buttons, def.buttons) |*s, b| {
                // As `base.ct.button` builds one, from a name instead of an enum literal.
                s.* = spec_zig.row(base.buttonStyle(&th), .{Spec{ .kind = .label, .bind = b, .style = .{ .role = .label } }});
                s.id = partName(id, b);
            }
            var panel = spec_zig.col(.{}, .{ base.ct.label(th, title), base.ct.label(th, message), spec_zig.row(.{}, buttons) });
            panel.id = partName(id, "panel");
            var backdrop = spec_zig.col(.{}, .{panel});
            backdrop.id = partName(id, "backdrop");
            return backdrop;
        }

        pub fn check(comptime State: type) ?[]const u8 {
            return checkDialog(State, def, field_name);
        }

        /// The opener's and the buttons' responses, then the keys, through `advance`.
        pub fn step(sig: anytype, v: anytype) void {
            var hits: Hits = .{ .open = v.responseOf(id).clicked };
            inline for (def.buttons, 0..) |b, k| hits.add(k, v.responseOf(partName(id, b)));
            sig.set(field, advance(def, @field(sig.state, field_name), hits, v.in.events));
        }

        pub fn part(comptime n: Spec, st: anytype, v: anytype) ?Part {
            const ds: DialogState = @field(st, field_name);
            if (comptime named(n, partName(id, "backdrop"))) {
                if (!ds.open) return null;
                return .{ .style = backdropStyle(&th, v.in.viewport) };
            }
            if (comptime named(n, partName(id, "panel"))) return .{ .style = panelStyle(&th), .role = role };
            inline for (def.buttons, 0..) |b, k| {
                if (comptime named(n, partName(id, b))) return .{ .style = buttonStyle(&th, v.response, ds.focus == k) };
            }
            // The button row: the panel's third child, the only unnamed row in the layer.
            if (comptime n.kind == .row and n.id == null and n.children.len == def.buttons.len and
                n.children[0].id != null and named(n.children[0], partName(id, def.buttons[0]))) return .{ .style = rowStyle(&th) };
            return popover.plainPart(th, n, v.response);
        }
    };
}

fn named(comptime n: Spec, comptime want: []const u8) bool {
    return n.id != null and std.mem.eql(u8, n.id.?, want);
}

// ---- look -------------------------------------------------------------------------------------

/// What the backdrop lays over the page: black at 55% opacity.
pub const dim: Color = .rgba(0, 0, 0, 140);

/// The backdrop: over the whole viewport, dimming the page, centring the dialog.
pub fn backdropStyle(th: *const Theme, viewport: [2]f32) Style {
    _ = th;
    return .{ .float = true, .size = .{ .px(viewport[0]), .px(viewport[1]) }, .main = .center, .cross = .center, .fill = dim };
}

/// The dialog's panel: panel-coloured with the control outline, twice a button's padding and
/// corner radius, its parts a double gap apart, at least 260 wide.
pub fn panelStyle(th: *const Theme) Style {
    return .{
        .pad = @splat(th.pad * 2),
        .gap = th.gap * 2,
        .min = .{ 260, 0 },
        .fill = th.panel,
        .border = 1,
        .border_color = th.control_hot,
        .radius = th.radius * 2,
    };
}

/// The row of buttons: across the dialog, the buttons at its end.
pub fn rowStyle(th: *const Theme) Style {
    return .{ .dir = .x, .size = .{ .fill, .fit }, .gap = th.gap, .main = .end };
}

/// A button of the dialog: a theme button, filled by its response; the focused one has the
/// focus ring, a 2 px accent border (by table index, `ring`).
pub fn buttonStyle(th: *const Theme, r: Response, focused: bool) Style {
    var s = base.buttonStyle(th);
    s.fill = base.buttonFill(th, r);
    const k = @intFromBool(focused);
    s.border = ring_width[k];
    s.border_color = ring(th)[k];
    return s;
}

/// The focus ring's width and colour, indexed by focus: none, then 2 px of the accent.
pub const ring_width = [2]f32{ 0, 2 };
pub fn ring(th: *const Theme) base.OnOff {
    return .{ .transparent, th.accent };
}

// ---- behaviour: a pure function of the state and what happened --------------------------------

/// No button.
pub const no_button: u8 = 0xff;

/// What the pointer did to a dialog this frame, from its widgets' responses.
pub const Hits = struct {
    /// The opener was clicked.
    open: bool = false,
    /// The button the left button went down on, or `no_button`.
    pressed: u8 = no_button,
    /// The button clicked, or `no_button`.
    clicked: u8 = no_button,

    /// Notes button `k`'s response.
    pub fn add(h: *Hits, k: u8, r: Response) void {
        if (r.pressed) h.pressed = k;
        if (r.clicked) h.clicked = k;
    }
};

/// One frame of a modal dialog (APG modal dialog). The opener's click opens it with focus on
/// the first button. While it is open, focus stays on its buttons: Tab and Shift+Tab move it
/// among them, wrapping, and a press on a button focuses it; Enter or Space choose the focused
/// button, a click chooses the clicked one, and either closes the dialog with `result` set for
/// one frame; Escape closes it with `result` 0. The backdrop takes every other press, so
/// nothing behind the dialog reacts. Keys are read in order.
pub fn advance(comptime def: Def, st: DialogState, hits: Hits, evs: []const Input.Event) DialogState {
    const n: u8 = def.buttons.len;
    var s = st;
    s.result = 0;
    if (!s.open) {
        if (hits.open) s = .{ .open = true };
        return s;
    }
    if (hits.pressed != no_button) s.focus = hits.pressed;
    if (hits.clicked != no_button) return .{ .focus = hits.clicked, .result = hits.clicked + 1 };
    const k = popover.keys;
    for (evs) |e| {
        if (e.kind != .press and e.kind != .repeat) continue;
        switch (e.code) {
            k.tab => s.focus = if (e.mods.shift) (s.focus + n - 1) % n else (s.focus + 1) % n,
            k.enter, k.space => return .{ .focus = s.focus, .result = s.focus + 1 },
            k.escape => return .{ .focus = s.focus },
            else => {},
        }
    }
    return s;
}

// ---- accessibility ------------------------------------------------------------------------------

/// The panel's role (APG modal dialog); its value is 0. The buttons are buttons, named by their
/// text.
pub const role: a11y.Role = .dialog;

/// The semantics of dialog `name` the tree's columns cannot hold, written into `s` after
/// `Semantics.clear` and before `a11y.names` and `a11y.states`: the dialog is named by its
/// title, the panel's first child (`aria-labelledby`). Works on either front end's tree.
pub fn semantics(t: *const Tree, s: *a11y.Semantics, comptime name: []const u8) void {
    const panel = t.find(.from(partName(name, "panel")));
    if (panel != types.none) s.c.labelled_by[panel] = panel + 1;
}

/// Marks dialog `name`'s panel as a modal layer in `sc` (`focus.Scopes.trap`), for an
/// application that runs `focus.Focus` over the tree: Tab then stays inside it, and focus goes
/// back to what had it when the dialog closes. Call after the tree is built, before
/// `focus.scan`.
pub fn trapFocus(t: *const Tree, sc: *focus.Scopes, comptime name: []const u8) void {
    const panel = t.find(.from(partName(name, "panel")));
    if (panel != types.none) sc.c.kind[panel] |= focus.Scopes.trap;
}

// ---- runtime front end ------------------------------------------------------------------------

/// The button that opens dialog `name`, showing `text`.
pub fn trigger(f: *Frame, th: *const Theme, comptime name: []const u8, text: []const u8) Response {
    return base.button(f, th, .from(name), text);
}

/// Builds dialog `name` (buttons `def`, labelled `texts`) showing `title` and `message`, if it
/// is open. Call it at the root's depth, after the rest of the page, so it is drawn on top.
/// Returns the button chosen this frame plus one, or 0.
pub fn show(f: *Frame, th: *const Theme, comptime name: []const u8, comptime def: Def, st: *DialogState, title: []const u8, message: []const u8, texts: []const []const u8) u8 {
    std.debug.assert(texts.len == def.buttons.len);
    // Every response is asked for before anything is built, so the rows show the frame's
    // final state, as in the comptime front end.
    const inter = &f.ctx.inter;
    var hits: Hits = .{ .open = inter.response(.from(name)).clicked };
    inline for (def.buttons, 0..) |b, k| hits.add(k, inter.response(.from(partName(name, b))));
    st.* = advance(def, st.*, hits, f.in.events);
    if (!st.open) return st.result;
    _ = f.interact(f.open(.from(partName(name, "backdrop")), backdropStyle(th, f.in.viewport)), popover.overlay_sense);
    const panel = f.open(.from(partName(name, "panel")), panelStyle(th));
    _ = f.interact(panel, popover.overlay_sense);
    f.tree().c.role[panel.ix()] = @backingInt(role);
    _ = base.label(f, th, title);
    _ = base.label(f, th, message);
    _ = f.open(.none, rowStyle(th));
    inline for (def.buttons, 0..) |b, k| {
        const bid: Id = .from(partName(name, b));
        _ = f.interact(f.open(bid, buttonStyle(th, inter.response(bid), st.focus == k)), .button);
        _ = base.label(f, th, texts[k]);
        f.close();
    }
    f.close();
    f.close();
    f.close();
    return st.result;
}

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;

const confirm: Def = .{ .buttons = &.{ "cancel", "ok" } };
const confirm_texts = [_][]const u8{ "Cancel", "Delete" };

/// The test page: a toolbar with the button that opens the dialog and a label, and the dialog.
fn Page(comptime th: Theme) type {
    return struct {
        const toolbar_style: Style = .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(8), .gap = 8, .cross = .center, .fill = th.panel };
        const page_style: Style = .{ .size = .{ .fill, .fill } };

        pub const App = struct {
            dialog: DialogState = .{},
            result: u8 = 0,

            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, page_style);
                _ = f.open(.none, toolbar_style);
                _ = trigger(f, &th, "delete", "Delete scene");
                _ = base.label(f, &th, "Scene 1");
                f.close();
                app.result = show(f, &th, "delete", confirm, &app.dialog, "Delete scene?", "This cannot be undone.", &confirm_texts);
                f.close();
            }
        };

        pub const State = struct {
            dialog: DialogState = .{},
            delete_text: []const u8 = "Delete scene",
            scene: []const u8 = "Scene 1",
            title: []const u8 = "Delete scene?",
            message: []const u8 = "This cannot be undone.",
            cancel: []const u8 = "Cancel",
            ok: []const u8 = "Delete",
        };
        pub const D = Dialog(th, .delete, .dialog, confirm);
        pub const spec = spec_zig.col(page_style, .{
            spec_zig.row(toolbar_style, .{ D.button(.delete_text), base.ct.label(th, .scene) }),
            D.layer(.title, .message),
        });
        pub const Ui = popover.ComptimePage(State, spec, th, D);
        pub const limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .depth = 8 };
        pub const Run = base.Harness(App, Ui, limits);
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

/// Sets the dialog's state in both front ends of `h` and builds two frames (the second sees
/// the first's rects); returns the second's tree.
fn setState(h: anytype, st: DialogState) !*const Tree {
    const in: Input = .{ .viewport = .{ 400, 300 } };
    h.app.dialog = st;
    h.ui.signals.set(.dialog, st);
    _ = try h.frame(&in);
    return (try h.frame(&in)).runtime.tree;
}

test "Dialog: the page agrees in both front ends, closed and open" {
    const h = &harness;
    h.init();
    var t = try setState(h, .{});
    try testing.expectEqual(@as(u32, 6), t.len);
    t = try setState(h, .{ .open = true });
    // Backdrop, panel, title, message, row, two buttons with their labels.
    try testing.expectEqual(@as(u32, 6 + 9), t.len);
    // The dialog is centred on the backdrop.
    const p = t.rect(t.find(.from("delete_panel")));
    try testing.expectApproxEqAbs(@as(f32, 200), (p.x0 + p.x1) * 0.5, 1);
    try testing.expectApproxEqAbs(@as(f32, 150), (p.y0 + p.y1) * 0.5, 1);
}

test "backdropStyle, panelStyle, rowStyle, buttonStyle: the theme's tokens" {
    const th: Theme = .default;
    try testing.expectEqual(dim, backdropStyle(&th, .{ 400, 300 }).fill);
    const p = panelStyle(&th);
    try testing.expectEqual(th.panel, p.fill);
    try testing.expectEqual(th.control_hot, p.border_color);
    try testing.expectEqual([4]f32{ 16, 16, 16, 16 }, p.pad);
    try testing.expectEqual(types.Align.end, rowStyle(&th).main);
    const plain = buttonStyle(&th, .{}, false);
    try testing.expectEqual(@as(f32, 0), plain.border);
    try testing.expectEqual(th.control, plain.fill);
    const focused = buttonStyle(&th, .{ .hovered = true }, true);
    try testing.expectEqual(@as(f32, 2), focused.border);
    try testing.expectEqual(th.accent, focused.border_color);
    try testing.expectEqual(th.control_hot, focused.fill);
}

const light: Theme = .{ .panel = .rgb(240, 240, 240), .control = .rgb(200, 200, 205), .accent = .rgb(0, 120, 60), .text = .rgb(20, 20, 20), .pad = 12, .gap = 10, .radius = 0 };

test "Dialog: another theme restyles both front ends alike" {
    const S = struct {
        var h: Page(light).Run = .{};
    };
    S.h.init();
    const t = try setState(&S.h, .{ .open = true, .focus = 1 });
    try testing.expectEqual(light.panel.bitsOf(), t.c.look[t.find(.from("delete_panel"))].fill);
    try testing.expectEqual(light.accent.bitsOf(), t.c.look[t.find(.from("delete_ok"))].border_color);
}

test "advance: opens on the first button, traps Tab, chooses, Escape closes" {
    const k = popover.keys;
    const ev = struct {
        fn of(comptime codes: []const u8, mods: Input.Mods) [codes.len]Input.Event {
            var out: [codes.len]Input.Event = undefined;
            for (&out, codes) |*e, c| e.* = .{ .kind = .press, .code = c, .mods = mods };
            return out;
        }
    }.of;
    var s = advance(confirm, .{}, .{}, &ev(&.{k.enter}, .{}));
    try testing.expectEqual(DialogState{}, s); // closed: keys do nothing
    s = advance(confirm, s, .{ .open = true }, &.{});
    try testing.expectEqual(DialogState{ .open = true }, s);
    s = advance(confirm, s, .{}, &ev(&.{ k.tab, k.tab, k.tab }, .{}));
    try testing.expectEqual(@as(u8, 1), s.focus); // wraps inside the dialog
    s = advance(confirm, s, .{}, &ev(&.{k.tab}, .{ .shift = true }));
    try testing.expectEqual(@as(u8, 0), s.focus);
    s = advance(confirm, s, .{}, &ev(&.{ k.tab, k.space }, .{}));
    try testing.expectEqual(DialogState{ .focus = 1, .result = 2 }, s);
    s = advance(confirm, s, .{}, &.{});
    try testing.expectEqual(@as(u8, 0), s.result); // one frame
    s = advance(confirm, .{ .open = true }, .{}, &ev(&.{k.escape}, .{}));
    try testing.expectEqual(DialogState{}, s);
    s = advance(confirm, .{ .open = true }, .{ .pressed = 1 }, &.{});
    try testing.expectEqual(DialogState{ .open = true, .focus = 1 }, s);
    s = advance(confirm, s, .{ .clicked = 0 }, &.{});
    try testing.expectEqual(DialogState{ .result = 1 }, s);
}

const Aim = union(enum) { part: []const u8, at: [2]f32 };
const Step = struct { aim: Aim, left: bool = false, key: ?u8 = null, shift: bool = false };

/// Runs `script` through both front ends, aiming at last frame's rects, with the dialog's
/// state equal in both after every step; returns the state after each step.
fn runScript(comptime n: usize, script: [n]Step) ![n]DialogState {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 400, 300 } };
    var ev: [1]Input.Event = undefined;
    var last = (try h.frame(&in)).runtime.tree;
    var out: [n]DialogState = undefined;
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
            ev[0] = .{ .kind = .press, .code = k, .mods = .{ .shift = st.shift } };
            in.events = &ev;
        }
        last = (try h.frame(&in)).runtime.tree;
        try testing.expectEqual(h.app.dialog, h.ui.signals.state.dialog);
        try testing.expectEqual(h.app.result, h.app.dialog.result);
        o.* = h.app.dialog;
    }
    return out;
}

test "Dialog: opener, focus trap, keys and clicks in both front ends" {
    const k = popover.keys;
    const s = try runScript(12, .{
        .{ .aim = .{ .part = "delete" }, .left = true },
        .{ .aim = .{ .part = "delete" } }, // open, Cancel focused
        .{ .aim = .{ .part = "delete" }, .key = k.tab }, // Delete
        .{ .aim = .{ .part = "delete" }, .key = k.tab }, // wraps to Cancel
        .{ .aim = .{ .part = "delete" }, .key = k.tab, .shift = true }, // back to Delete
        .{ .aim = .{ .part = "delete" }, .left = true }, // a press behind the dialog: nothing
        .{ .aim = .{ .part = "delete" } },
        .{ .aim = .{ .part = "delete" }, .key = k.enter }, // Delete chosen
        .{ .aim = .{ .part = "delete" }, .left = true },
        .{ .aim = .{ .part = "delete" } }, // open again
        .{ .aim = .{ .part = "delete_cancel" }, .left = true }, // press Cancel: focused
        .{ .aim = .{ .part = "delete_cancel" } }, // click: chosen
    });
    try testing.expect(!s[0].open and s[1].open and s[1].focus == 0);
    try testing.expectEqual(@as(u8, 1), s[2].focus);
    try testing.expectEqual(@as(u8, 0), s[3].focus);
    try testing.expectEqual(@as(u8, 1), s[4].focus);
    try testing.expect(s[6].open and s[6].focus == 1);
    try testing.expectEqual(DialogState{ .focus = 1, .result = 2 }, s[7]);
    try testing.expect(s[9].open and s[9].focus == 0);
    try testing.expect(s[10].open and s[10].focus == 0);
    try testing.expectEqual(DialogState{ .result = 1 }, s[11]);
}

var sem: [2]popover.Semantic(64) = .{ .{}, .{} };

test "Dialog: a dialog named by its title, with its buttons; the same in both front ends" {
    const h = &harness;
    h.init();
    const t = try setState(h, .{ .open = true });
    const cp = &h.ui.tables.t;
    semantics(t, sem[0].begin(), "delete");
    semantics(cp, sem[1].begin(), "delete");
    const e = sem[0].finish(t, &h.ctx.texts[h.ctx.cur], h.ctx.strings[h.ctx.cur].buf);
    try testing.expect(popover.sameSemantics(e, sem[1].finish(cp, &h.ui.tables.tx, h.ui.tables.strings.buf)));
    const d = popover.exportRow(e, t.find(.from("delete_panel")));
    try testing.expectEqual(@backingInt(a11y.Role.dialog), e.c.role[d]);
    try testing.expectEqual(std.hash.Fnv1a_32.hash("Delete scene?"), e.c.name_hash[d]);
    try testing.expectEqual(@as(f32, 0), e.c.value[d]);
    const ok = popover.exportRow(e, t.find(.from("delete_ok")));
    try testing.expectEqual(@backingInt(a11y.Role.button), e.c.role[ok]);
    try testing.expectEqual(std.hash.Fnv1a_32.hash("Delete"), e.c.name_hash[ok]);
}

test "trapFocus: the panel is the modal layer focus.scan finds" {
    const h = &harness;
    h.init();
    const t = try setState(h, .{ .open = true });
    const S = struct {
        var buf: [64 * 1024]u8 align(@import("../core/mem.zig").column_align) = undefined;
    };
    var carver: @import("../core/mem.zig").Carver = .{ .buf = &S.buf };
    var sc = focus.Scopes.init(&carver, t.cap);
    sc.reset();
    trapFocus(t, &sc, "delete");
    focus.scan(t, &sc);
    try testing.expectEqual(t.find(.from("delete_panel")), sc.modal);
}

test "checkDialog: the state field and the buttons" {
    try testing.expectEqual(null, comptime checkDialog(Default.State, confirm, "dialog"));
    try testing.expectEqualStrings("dialog: field 'dialog' must be a dialog.DialogState", comptime checkDialog(struct { dialog: bool }, confirm, "dialog").?);
    try testing.expectEqualStrings("dialog: button 'cancel' needs a string field of its name", comptime checkDialog(struct { dialog: DialogState }, confirm, "dialog").?);
    try testing.expectEqualStrings("dialog: no buttons", comptime checkDialog(Default.State, .{ .buttons = &.{} }, "dialog").?);
}

test {
    std.testing.refAllDecls(@This());
}
