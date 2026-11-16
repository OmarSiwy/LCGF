//! Accordion (tier 2): sections stacked in a column, each a header that shows or hides the
//! panel below it. Each section's expanded flag is application state (a `bool`). Written
//! against the public API of tiers 0 and 1 (src/widgets/base.zig has the recipe).
//!
//! Runtime: `accordion.open(f, th, id, &expanded, "Title")`, the panel's children, then
//! `accordion.close(f)`. Comptime: `accordion.ct.section(th, .id, .expanded, .title, .{...})`.
//!
//! A collapsed panel is still built, 0 px high and clipping: its rows are there, but nothing
//! in them is painted or hit. That keeps the rows of a section the same in every state, as
//! the comptime front end's fixed tables need (and as a height animation would).

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const Id = types.Id;
const Response = types.Response;
const Theme = base.Theme;

// ---- spec ---------------------------------------------------------------------------------

/// Starts a section with header `title` and the identity `id`, showing its panel while
/// `expanded.*` is set. Everything built until `close` goes in the panel. Returns the
/// header's response.
pub fn open(f: *Frame, th: *const Theme, id: Id, expanded: *bool, title: []const u8) Response {
    _ = f.open(.none, sectionStyle(th));
    const head = f.open(id, headerStyle(th));
    const r = f.interact(head, .button);
    expanded.* = expand(expanded.*, r.clicked, r.focused, f.in);
    f.setFill(head, base.buttonFill(th, r));
    f.setCursor(.pointer, r.hovered);
    _ = f.leaf(.none, indicatorStyle(th, expanded.*));
    _ = base.label(f, th, title);
    f.close();
    _ = f.open(.none, panelStyle(th, expanded.*));
    return r;
}

/// Ends the section `open` started.
pub fn close(f: *Frame) void {
    f.close();
    f.close();
}

/// A section spans its parent's width: the header above, the panel below.
pub fn sectionStyle(th: *const Theme) Style {
    _ = th;
    return .{ .dir = .y, .size = .{ .fill, .fit } };
}

/// The header: a row across the section holding the indicator and the title, padded and
/// rounded as a button. Its fill is a button's, by interaction state (`base.buttonFill`).
pub fn headerStyle(th: *const Theme) Style {
    return .{ .dir = .x, .size = .{ .fill, .fit }, .pad = @splat(th.pad), .gap = th.gap, .radius = th.radius, .cross = .center, .role = .button };
}

/// The mark before the title: the accent colour while the section is open, the control
/// colour while it is closed (`Theme.marks`, by table index).
pub fn indicatorStyle(th: *const Theme, expanded: bool) Style {
    return .{ .size = .{ .px(8), .px(8) }, .radius = 2, .fill = th.marks()[@intFromBool(expanded)] };
}

/// The panel: as tall as its children when expanded, 0 px and clipping when collapsed,
/// picked by table index. Its children are inset by the theme's pad and spaced by its gap.
pub fn panelStyle(th: *const Theme, expanded: bool) Style {
    const heights = [2]types.Size{ .px(0), .fit };
    return .{ .dir = .y, .size = .{ .fill, heights[@intFromBool(expanded)] }, .pad = .{ th.pad, th.gap, th.pad, th.gap }, .gap = th.gap, .clip = true };
}

// ---- behaviour ----------------------------------------------------------------------------

/// Scancodes of the keys that activate a focused header (USB HID usage ids, as
/// `focus.Keymap`'s defaults).
pub const enter: u8 = 0x28;
pub const space: u8 = 0x2c;

/// Presses of Enter or Space in this frame's key events (auto-repeat does not count).
pub fn activations(in: *const Input) u32 {
    var k: u32 = 0;
    for (in.events) |e| k += @intFromBool(e.kind == .press and (e.code == enter or e.code == space));
    return k;
}

/// The section's next expanded state: a click on its header toggles it, and so does each
/// Enter or Space while the header has focus (WAI-ARIA APG accordion pattern).
pub fn expand(expanded: bool, clicked: bool, focused: bool, in: *const Input) bool {
    const presses = activations(in) * @intFromBool(focused);
    return base.toggle(expanded, (@intFromBool(clicked) + presses) & 1 == 1);
}

/// The accordion's sections as spec nodes.
pub const ct = struct {
    /// A section whose header is the widget `id`, titled by the string field `title`, showing
    /// `children` (a tuple of specs) while the bool field `expanded` is set. Mistakes are
    /// compile errors: an empty `children`, an `expanded` that is not a bool field or a
    /// `title` that is not a string field of the state struct.
    pub fn section(comptime th: Theme, comptime id: @EnumLiteral(), comptime expanded: @EnumLiteral(), comptime title: @EnumLiteral(), comptime children: anytype) Spec {
        if (children.len == 0) @compileError("accordion section '" ++ @tagName(id) ++ "' has an empty panel");
        var head = spec_zig.row(headerStyle(&th), .{ Spec{ .kind = .col }, base.ct.label(th, title) });
        head.id = @tagName(id);
        var s = spec_zig.col(sectionStyle(&th), .{ head, spec_zig.col(.{}, children) });
        s.widget = Section(@tagName(id), @tagName(expanded));
        return s;
    }

    /// How the comptime front end builds and drives one section.
    fn Section(comptime id: [:0]const u8, comptime expanded: []const u8) type {
        return struct {
            /// The header was clicked (the frame's event), or has focus (the last press).
            pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
                _ = row;
                const E = @TypeOf(ui.*).Events;
                const me = @field(E.Widget, id);
                const clicked = if (event) |e| std.meta.activeTag(e) == me else false;
                const field = comptime @TypeOf(ui.*).field(expanded);
                ui.signals.set(field, expand(@field(ui.signals.state, expanded), clicked, ui.focus == me, in));
            }

            pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
                const th = @TypeOf(ui.*).theme;
                const t = &ui.tables.t;
                const open_: bool = @field(ui.signals.state, expanded);
                const sec = t.push(parent, .none, &n.style);
                var hs = n.children[0].style;
                hs.fill = base.buttonFill(&th, ui.response(next.* + 1, in));
                const head = t.push(sec, .hash(id), &hs);
                _ = t.push(head, .none, &indicatorStyle(&th, open_));
                next.* += 3;
                ui.push(n.children[0].children[1], head, next, in);
                t.seal(head);
                const panel = t.push(sec, .none, &panelStyle(&th, open_));
                next.* += 1;
                inline for (n.children[1].children) |c| ui.push(c, panel, next, in);
                t.seal(panel);
                t.seal(sec);
            }
        };
    }
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;

/// Two sections: "General" (open) holding a checkbox, "Advanced" (closed) holding a slider.
fn Page(comptime th: Theme) type {
    const column: Style = .{ .dir = .y, .size = .{ .px(240), .fit }, .pad = @splat(8), .gap = 4 };
    return struct {
        pub const App = struct {
            general: bool = true,
            advanced: bool = false,
            wire: bool = false,
            level: f32 = 0.5,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, column);
                _ = open(f, &th, .from("general"), &app.general, "General");
                _ = base.checkbox(f, &th, .from("wire"), &app.wire, "Wireframe");
                close(f);
                _ = open(f, &th, .from("advanced"), &app.advanced, "Advanced");
                _ = base.slider(f, &th, .from("level"), &app.level, 0, 1);
                close(f);
                f.close();
            }
        };
        pub const State = struct {
            general: bool = true,
            general_text: []const u8 = "General",
            advanced: bool = false,
            advanced_text: []const u8 = "Advanced",
            wire: bool = false,
            wire_text: []const u8 = "Wireframe",
            level: f32 = 0.5,
        };
        pub const spec = spec_zig.col(column, .{
            ct.section(th, .general, .general, .general_text, .{base.ct.checkbox(th, .wire, .wire, .wire_text)}),
            ct.section(th, .advanced, .advanced, .advanced_text, .{base.ct.slider(th, .level, .level)}),
        });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

const Default = Page(.default);
var harness: Default.Run = .{};

test "accordion: both front ends build every section's rows; a collapsed panel is 0 px and clips" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    // root, column, then per section: section, header, indicator, title, panel, content (the
    // checkbox has 2 children, the slider 1)
    try testing.expectEqual(@as(u32, 2 + 8 + 7), t.len);
    const general_panel = t.find(.from("general")) + 3;
    const advanced_panel = t.find(.from("advanced")) + 3;
    try testing.expect(t.rect(general_panel).h() > 0);
    try testing.expectEqual(@as(f32, 0), t.rect(advanced_panel).h());
    // The closed panel's slider is there but invisible.
    try testing.expectEqual(@as(u32, 0), t.c.visible[t.find(.from("level"))]);
    try testing.expectEqual(4, Default.Ui.Events.widget_count);
}

test "accordion: header filled as a button, indicator by state, panel inset; any theme alike" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 200 } };
    var out = try h.frame(&in);
    const th = Theme.default;
    var t = out.runtime.tree;
    const g = t.find(.from("general"));
    const a = t.find(.from("advanced"));
    try testing.expectEqual(th.control.bitsOf(), t.c.look[g].fill);
    try testing.expectEqual(th.accent.bitsOf(), t.c.look[g + 1].fill);
    try testing.expectEqual(th.control.bitsOf(), t.c.look[a + 1].fill);
    // The open panel's checkbox sits inset by pad and gap; the closed panel stays 0 px.
    try testing.expectEqual(t.rect(g + 3).x0 + th.pad, t.rect(g + 4).x0);
    try testing.expectEqual(t.rect(g + 3).y0 + th.gap, t.rect(g + 4).y0);
    try testing.expectEqual(@as(f32, 0), t.rect(a + 3).h());
    // Hovering a header lights it in both front ends.
    const r = t.rect(a);
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    out = try h.frame(&in);
    t = out.runtime.tree;
    try testing.expectEqual(th.control_hot.bitsOf(), t.c.look[a].fill);
    try testing.expectEqual(th.control_hot.bitsOf(), out.comptime_.tree.c.look[a].fill);

    const Light = Page(.{ .control = .rgb(200, 200, 205), .control_hot = .rgb(180, 180, 190), .accent = .rgb(0, 120, 60), .text = .rgb(20, 20, 20), .pad = 12, .gap = 10, .radius = 0 });
    const S = struct {
        var light: Light.Run = .{};
    };
    S.light.init();
    _ = try S.light.frame(&in);
    const lo = try S.light.frame(&in);
    try testing.expectEqual(types.Color.rgb(0, 120, 60).bitsOf(), lo.runtime.tree.c.look[g + 1].fill);
}

test "accordion: a click or Enter/Space on the focused header toggles it, in both front ends" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 200 } };
    var out = try h.frame(&in);
    const at = struct {
        fn center(o: anytype, name: []const u8) [2]f32 {
            const t = o.runtime.tree;
            const r = t.rect(t.find(.hash(name)));
            return .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
        }
    };
    // Click Advanced: it opens; its slider becomes visible.
    in.pointer = at.center(out, "advanced");
    in.buttons.left = true;
    _ = try h.frame(&in);
    in.buttons.left = false;
    out = try h.frame(&in);
    try testing.expect(h.app.advanced and h.ui.signals.state.advanced);
    try testing.expect(out.runtime.tree.c.visible[out.runtime.tree.find(.from("level"))] != 0);
    // Advanced has focus now: Enter closes it, Space opens it, a repeat does nothing.
    const keys = [_]struct { code: u8, kind: Input.Event.Kind, open: bool }{
        .{ .code = enter, .kind = .press, .open = false },
        .{ .code = space, .kind = .press, .open = true },
        .{ .code = space, .kind = .repeat, .open = true },
        .{ .code = 0x04, .kind = .press, .open = true }, // 'a'
    };
    for (keys) |k| {
        const ev = [1]Input.Event{.{ .kind = k.kind, .code = k.code }};
        in.events = &ev;
        _ = try h.frame(&in);
        try testing.expectEqual(k.open, h.app.advanced);
        try testing.expectEqual(k.open, h.ui.signals.state.advanced);
    }
    // General is not focused: Enter does not touch it.
    try testing.expect(h.app.general);
    // Two activations in one frame cancel out.
    const two = [2]Input.Event{ .{ .kind = .press, .code = enter }, .{ .kind = .press, .code = space } };
    in.events = &two;
    _ = try h.frame(&in);
    try testing.expect(h.app.advanced and h.ui.signals.state.advanced);
    in.events = &.{};
    // Click General: it closes, and the checkbox inside can no longer be hit.
    in.pointer = at.center(out, "general");
    in.buttons.left = true;
    _ = try h.frame(&in);
    in.buttons.left = false;
    out = try h.frame(&in);
    try testing.expect(!h.app.general and !h.ui.signals.state.general);
    const t = out.runtime.tree;
    const box = t.find(.from("wire"));
    try testing.expectEqual(@as(u32, 0), t.c.visible[box]);
    try testing.expect(@import("../interact/hit.zig").at(t, t.rect(box).x0 + 1, t.rect(box).y0 + 1, .any) != box);
}

test "expand: clicks and focused presses toggle; unfocused presses do not" {
    const ev = [3]Input.Event{ .{ .kind = .press, .code = enter }, .{ .kind = .release, .code = enter }, .{ .kind = .press, .code = 0x2c } };
    const in: Input = .{ .events = &ev };
    try testing.expectEqual(@as(u32, 2), activations(&in));
    try testing.expect(expand(false, true, false, &in));
    try testing.expect(!expand(false, false, true, &in));
    try testing.expect(expand(false, true, true, &in));
    try testing.expect(!expand(false, false, false, &in));
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
