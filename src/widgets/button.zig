//! Button: a caption on a face that reports a click. Tier 2, written against the public API
//! of tiers 0 and 1 (the recipe in base.zig).
//!
//! State: none of its own. The caption is the application's string (`str` in the runtime
//! front end, a `[]const u8` field bound by the caption's label in the comptime one, checked
//! as a label's binding), and a click is reported, not stored: `Response.clicked` in the
//! runtime front end, the button's `Event` (no payload) in the comptime one.

const std = @import("std");
const base = @import("base.zig");
const label_zig = @import("label.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Response = types.Response;
const Style = types.Style;
const Color = types.Color;
const Input = @import("../core/input.zig").Input;
const simd = @import("../core/simd.zig");

// ---- look -----------------------------------------------------------------------------------

/// The face: a row padded by the theme's `pad`, caption centred, corners of `radius`.
pub fn buttonStyle(th: *const Theme) Style {
    return .{ .dir = .x, .pad = @splat(th.pad), .radius = th.radius, .main = .center, .cross = .center, .role = .button };
}

/// The face's colour: the theme's control fills, picked by table index from hover and held.
pub fn buttonFill(th: *const Theme, r: Response) Color {
    return th.controlFills()[base.stateIndex(r)];
}

// ---- behaviour ------------------------------------------------------------------------------

/// Whether the button fires this frame: clicked, or focused and Enter went down or Space came
/// up (the WAI-ARIA APG button pattern; Space on release, as native buttons do, so holding it
/// does not repeat).
pub fn activated(clicked: bool, focused: bool, in: *const Input) bool {
    const keyed = base.keyCount(in, base.keys.enter, .press) + base.keyCount(in, base.keys.space, .release) != 0;
    return simd.orB(clicked, simd.andB(focused, keyed));
}

// ---- runtime front end ----------------------------------------------------------------------

/// A button named `id` showing `str`; `clicked` is set the frame it fires (`activated`): the
/// left button goes up over it after going down on it, or, while it has focus, Enter or Space.
pub fn button(f: *Frame, th: *const Theme, id: Id, str: []const u8) Response {
    const node = f.open(id, buttonStyle(th));
    var r = f.interact(node, .button);
    r.clicked = activated(r.clicked, r.focused, f.in);
    f.setFill(node, buttonFill(th, r));
    f.setCursor(.pointer, r.hovered);
    _ = label_zig.label(f, th, str);
    f.close();
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A button named `id` showing the string field `text`; its click is its event:
    /// `ct.button(th, .reset, .reset_text)`. Its kind is `.button`, so it is a `Widget` with
    /// a `void` event and a stop in the focus order.
    pub fn button(comptime th: Theme, comptime id: @EnumLiteral(), comptime text: @EnumLiteral()) Spec {
        var s = spec_zig.row(buttonStyle(&th), .{label_zig.ct.label(th, text)});
        s.kind = .button;
        s.id = @tagName(id);
        return s;
    }
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const events = @import("../comptime/events.zig");

test "ct.button: a named, focusable widget with a void event, its caption a bound label" {
    const s = comptime ct.button(.default, .go, .go_text);
    try testing.expectEqual(spec_zig.Kind.button, s.kind);
    try testing.expectEqualStrings("go", s.id.?);
    try testing.expectEqual(null, s.bind);
    try testing.expectEqual(types.Axis.x, s.style.dir);
    try testing.expectEqual(spec_zig.Kind.label, s.children[0].kind);
    try testing.expectEqualStrings("go_text", s.children[0].bind.?);
    const E = events.Events(spec_zig.row(.{}, .{ s, comptime ct.button(.default, .stop, .stop_text) }));
    try testing.expectEqual(void, @FieldType(E.Event, "go"));
    try testing.expectEqualSlices(E.Widget, &.{ .go, .stop }, E.focus_order);
}

test "button state: the caption binds as a label does" {
    const State = struct { go_text: []const u8 = "Go", count: u32 = 0 };
    try testing.expectEqual(null, comptime label_zig.bindError(State, "go_text"));
    try testing.expect(comptime label_zig.bindError(State, "count") != null);
}

/// One button on a row, in both front ends, in theme `th`: the tests' page until the example
/// page (C0515).
fn One(comptime th: Theme) type {
    return struct {
        const row: Style = .{ .dir = .x, .pad = @splat(8) };
        pub const App = struct {
            clicked: bool = false,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.from("row"), row);
                app.clicked = button(f, &th, .from("go"), "Go").clicked;
                f.close();
            }
        };
        pub const State = struct { go_text: []const u8 = "Go" };
        pub const Ui = base.ComptimeUi(State, spec_zig.row(row, .{ct.button(th, .go, .go_text)}), th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256, .depth = 4 });
    };
}

var one: One(.default).Run = .{};

test "button look: padded around its caption, the fill picked by state, in both front ends" {
    const h = &one;
    h.init();
    const th = Theme.default;
    var in: Input = .{ .viewport = .{ 200, 60 } };
    var out = try h.frame(&in);
    // Rows: root, row, button, caption.
    const t = out.runtime.tree;
    const face = t.rect(2);
    const cap = t.rect(3);
    // Caption "Go": 2 x 8.4 by 17.5 (Mono at 14 px), padded by 8, snapped to whole pixels.
    try testing.expectEqual(@as(f32, 8), face.x0);
    try testing.expectApproxEqAbs(@as(f32, 2 * 8 + 2 * 8.4), face.w(), 0.5);
    try testing.expectApproxEqAbs(@as(f32, 2 * 8 + 17.5), face.h(), 0.5);
    try testing.expectEqual(face.x0 + th.pad, cap.x0);
    try testing.expectEqual(th.radius, t.c.look[2].radius);
    const c = th.controlFills();
    try testing.expectEqual(c[0].bitsOf(), t.c.look[2].fill);
    in.pointer = .{ (face.x0 + face.x1) * 0.5, (face.y0 + face.y1) * 0.5 };
    out = try h.frame(&in);
    try testing.expectEqual(c[1].bitsOf(), out.runtime.tree.c.look[2].fill);
    in.buttons.left = true;
    out = try h.frame(&in);
    try testing.expectEqual(c[3].bitsOf(), out.runtime.tree.c.look[2].fill);
    // Held and dragged off: it still looks held.
    in.pointer = .{ 190, 50 };
    out = try h.frame(&in);
    try testing.expectEqual(c[2].bitsOf(), out.runtime.tree.c.look[2].fill);
}

test "button look: other theme tokens restyle both front ends alike" {
    const S = struct {
        var h: One(.{ .pad = 4, .radius = 0, .control = .rgb(200, 0, 0) }).Run = .{};
    };
    S.h.init();
    const in: Input = .{ .viewport = .{ 200, 60 } };
    const out = try S.h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectApproxEqAbs(@as(f32, 2 * 4 + 2 * 8.4), t.rect(2).w(), 0.5);
    try testing.expectEqual(@as(f32, 0), t.c.look[2].radius);
    try testing.expectEqual(Color.rgb(200, 0, 0).bitsOf(), t.c.look[2].fill);
}

test "activated: a click, or Enter down or Space up while focused; nothing with a modifier" {
    const ev = struct {
        fn in(list: []const Input.Event) Input {
            return .{ .events = list };
        }
    };
    const none: Input = .{};
    try testing.expect(activated(true, false, &none));
    try testing.expect(!activated(false, true, &none));
    const enter = ev.in(&.{.{ .kind = .press, .code = base.keys.enter }});
    try testing.expect(activated(false, true, &enter));
    try testing.expect(!activated(false, false, &enter));
    const space_down = ev.in(&.{.{ .kind = .press, .code = base.keys.space }});
    try testing.expect(!activated(false, true, &space_down));
    const space_up = ev.in(&.{.{ .kind = .release, .code = base.keys.space }});
    try testing.expect(activated(false, true, &space_up));
    const ctrl_enter = ev.in(&.{.{ .kind = .press, .code = base.keys.enter, .mods = .{ .ctrl = true } }});
    try testing.expect(!activated(false, true, &ctrl_enter));
}

test "button input: click, then Enter and Space while focused, fire in both front ends" {
    const h = &one;
    h.init();
    var in: Input = .{ .viewport = .{ 200, 60 } };
    var out = try h.frame(&in);
    const face = out.runtime.tree.rect(2);
    in.pointer = .{ (face.x0 + face.x1) * 0.5, (face.y0 + face.y1) * 0.5 };
    const Step = struct { left: bool = false, events: []const Input.Event = &.{}, fires: bool };
    const enter: Input.Event = .{ .kind = .press, .code = base.keys.enter };
    const space_down: Input.Event = .{ .kind = .press, .code = base.keys.space };
    const space_up: Input.Event = .{ .kind = .release, .code = base.keys.space };
    const steps = [_]Step{
        .{ .fires = false }, // hover
        .{ .left = true, .fires = false }, // press: focus
        .{ .fires = true }, // release over it: click
        .{ .events = &.{enter}, .fires = true },
        .{ .events = &.{space_down}, .fires = false },
        .{ .events = &.{space_up}, .fires = true },
        .{ .events = &.{.{ .kind = .press, .code = base.keys.enter, .mods = .{ .shift = true } }}, .fires = false },
    };
    for (steps) |st| {
        in.buttons.left = st.left;
        in.events = st.events;
        out = try h.frame(&in);
        try testing.expectEqual(st.fires, h.app.clicked);
        try testing.expectEqual(st.fires, out.comptime_.event != null);
    }
    // A press elsewhere takes focus away: Enter does nothing.
    in.pointer = .{ 190, 55 };
    in.buttons.left = true;
    in.events = &.{};
    _ = try h.frame(&in);
    in.buttons.left = false;
    _ = try h.frame(&in);
    in.events = &.{enter};
    out = try h.frame(&in);
    try testing.expect(!h.app.clicked);
    try testing.expectEqual(null, out.comptime_.event);
    try testing.expectEqual(null, h.ui.focus);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
