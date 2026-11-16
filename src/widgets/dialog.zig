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

        pub fn step(sig: anytype, v: anytype) void {
            _ = sig;
            _ = v;
        }

        pub fn part(comptime n: Spec, st: anytype, v: anytype) ?Part {
            const ds: DialogState = @field(st, field_name);
            if (comptime named(n, partName(id, "backdrop"))) {
                if (!ds.open) return null;
                return .{ .style = backdropStyle(&th, v.in.viewport) };
            }
            if (comptime named(n, partName(id, "panel"))) return .{ .style = panelStyle(&th) };
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
    const inter = &f.ctx.inter;
    if (!st.open) return st.result;
    _ = f.open(.from(partName(name, "backdrop")), backdropStyle(th, f.in.viewport));
    _ = f.open(.from(partName(name, "panel")), panelStyle(th));
    _ = base.label(f, th, title);
    _ = base.label(f, th, message);
    _ = f.open(.none, rowStyle(th));
    inline for (def.buttons, 0..) |b, k| {
        const bid: Id = .from(partName(name, b));
        _ = f.open(bid, buttonStyle(th, inter.response(bid), st.focus == k));
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

test "checkDialog: the state field and the buttons" {
    try testing.expectEqual(null, comptime checkDialog(Default.State, confirm, "dialog"));
    try testing.expectEqualStrings("dialog: field 'dialog' must be a dialog.DialogState", comptime checkDialog(struct { dialog: bool }, confirm, "dialog").?);
    try testing.expectEqualStrings("dialog: button 'cancel' needs a string field of its name", comptime checkDialog(struct { dialog: DialogState }, confirm, "dialog").?);
    try testing.expectEqualStrings("dialog: no buttons", comptime checkDialog(Default.State, .{ .buttons = &.{} }, "dialog").?);
}

test {
    std.testing.refAllDecls(@This());
}
