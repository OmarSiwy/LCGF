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

// ---- look -----------------------------------------------------------------------------------

/// The face: a row padded by the theme's `pad`, caption centred, corners of `radius`.
pub fn buttonStyle(th: *const Theme) Style {
    return .{ .dir = .x, .pad = @splat(th.pad), .radius = th.radius, .main = .center, .cross = .center, .role = .button };
}

/// The face's colour: the theme's control fills, picked by table index from hover and held.
pub fn buttonFill(th: *const Theme, r: Response) Color {
    return th.controlFills()[base.stateIndex(r)];
}

// ---- runtime front end ----------------------------------------------------------------------

/// A button named `id` showing `str`; `clicked` is set the frame the left button goes up over
/// it after going down on it.
pub fn button(f: *Frame, th: *const Theme, id: Id, str: []const u8) Response {
    const node = f.open(id, buttonStyle(th));
    const r = f.interact(node, .button);
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

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
