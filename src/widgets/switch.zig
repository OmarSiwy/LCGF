//! Switch: an on/off control drawn as a knob on a track, with a caption. Tier 2, written
//! against the public API of tiers 0 and 1 (the recipe in base.zig). It is a checkbox in
//! behaviour (a click or Space flips it) and a different thing to assistive technology: it
//! reports on and off, not checked.
//!
//! State: the application's `bool`. The runtime front end takes a pointer to it; the comptime
//! front end binds a `bool` field, checked while compiling. The caption is a bound label.
//!
//! Not animated: the knob jumps. `Frame.animate` (prototype/ui.zig) is the anim lane's, which
//! has not landed; the knob's side is one table index, so easing it later is one call.

const std = @import("std");
const base = @import("base.zig");
const label_zig = @import("label.zig");
const checkbox_zig = @import("checkbox.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Style = types.Style;
const Color = types.Color;
const Response = types.Response;
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const simd = @import("../core/simd.zig");

// ---- spec -----------------------------------------------------------------------------------

/// The type of a switch's bound field.
pub const Bind = bool;

/// Why `State`'s field `name` cannot be a switch's value, or null when it can.
pub fn bindError(comptime State: type, comptime name: []const u8) ?[]const u8 {
    return base.fieldError(State, "switch", name, Bind);
}

// ---- look -----------------------------------------------------------------------------------

/// The row: track, then caption, centred across, `gap` apart.
pub fn switchStyle(th: *const Theme) Style {
    return .{ .dir = .x, .gap = th.gap, .cross = .center };
}

/// The 32 x 18 pill. Off: the control colour, knob at the start; on: the accent, knob at the
/// end. Both picked by table index from the value.
pub fn trackStyle(th: *const Theme, on: bool) Style {
    const fills = [2]Color{ th.control, th.accent };
    const sides = [2]types.Align{ .start, .end };
    const k = @intFromBool(on);
    return .{ .dir = .x, .size = .{ .px(32), .px(18) }, .pad = @splat(2), .radius = 9, .fill = fills[k], .main = sides[k], .cross = .center };
}

/// The 14 px knob, in the text colour.
pub fn knobStyle(th: *const Theme) Style {
    return .{ .size = .{ .px(14), .px(14) }, .radius = 7, .fill = th.text };
}

// ---- runtime front end ----------------------------------------------------------------------

/// A switch named `id` over `value`, captioned by `str`. A click, or Space while it has
/// focus, flips it (WAI-ARIA APG switch pattern; `checkbox.toggled`) and sets `clicked`.
pub fn @"switch"(f: *Frame, th: *const Theme, id: Id, value: *bool, str: []const u8) Response {
    const row = f.open(id, switchStyle(th));
    var r = f.interact(row, .button);
    r.clicked = checkbox_zig.toggled(r.clicked, r.focused, f.in);
    value.* = base.toggle(value.*, r.clicked);
    _ = f.open(.none, trackStyle(th, value.*));
    _ = f.leaf(.none, knobStyle(th));
    f.close();
    _ = label_zig.label(f, th, str);
    f.close();
    f.tree().c.value[row.ix()] = simd.b2f(value.*);
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A switch named `id` over the `bool` field `bind`, captioned by the string field `text`:
    /// `ct.@"switch"(th, .vsync, .vsync, .vsync_text)`.
    pub fn @"switch"(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime text: @EnumLiteral()) Spec {
        // Track (with its knob), caption: the rows the front ends push, in spec order.
        const track: Spec = .{ .kind = .col, .children = &.{Spec{ .kind = .col }} };
        var s = spec_zig.row(switchStyle(&th), .{ track, label_zig.ct.label(th, text) });
        s.kind = .@"switch";
        s.id = @tagName(id);
        s.bind = @tagName(bind);
        return s;
    }
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "bindError: a switch binds a bool" {
    const State = struct { on: bool = false, n: u32 = 0 };
    try testing.expectEqual(null, comptime bindError(State, "on"));
    try testing.expectEqualStrings("switch 'n' needs a bool field, not u32", comptime bindError(State, "n").?);
}

test "ct.switch: a named, focusable widget with a void event: track, knob and caption rows" {
    const events = @import("../comptime/events.zig");
    const s = comptime ct.@"switch"(.default, .vsync, .vsync, .vsync_text);
    try testing.expectEqual(spec_zig.Kind.@"switch", s.kind);
    try testing.expectEqualStrings("vsync", s.id.?);
    try testing.expectEqualStrings("vsync", s.bind.?);
    try testing.expectEqual(@as(usize, 2), s.children.len);
    try testing.expectEqual(@as(usize, 1), s.children[0].children.len);
    try testing.expectEqualStrings("vsync_text", s.children[1].bind.?);
    const E = events.Events(s);
    try testing.expectEqual(void, @FieldType(E.Event, "vsync"));
    try testing.expectEqualSlices(E.Widget, &.{.vsync}, E.focus_order);
}

/// Two switches, off and on, in both front ends, in theme `th`: the tests' page until the
/// example page (C0560).
fn Two(comptime th: Theme) type {
    return struct {
        const col: Style = .{ .dir = .y, .pad = @splat(8), .gap = 8 };
        pub const App = struct {
            vsync: bool = false,
            hdr: bool = true,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.from("col"), col);
                _ = @"switch"(f, &th, .from("vsync"), &app.vsync, "VSync");
                _ = @"switch"(f, &th, .from("hdr"), &app.hdr, "HDR");
                f.close();
            }
        };
        pub const State = struct { vsync: bool = false, vsync_text: []const u8 = "VSync", hdr: bool = true, hdr_text: []const u8 = "HDR" };
        pub const Ui = base.ComptimeUi(State, spec_zig.col(col, .{ ct.@"switch"(th, .vsync, .vsync, .vsync_text), ct.@"switch"(th, .hdr, .hdr, .hdr_text) }), th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });
    };
}

var two: Two(.default).Run = .{};

test "switch look: the knob at the start when off, at the end when on; the track's fill by value, in both front ends" {
    const h = &two;
    h.init();
    const th = Theme.default;
    const in: Input = .{ .viewport = .{ 200, 100 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    // Rows: root, column, then per switch: row, track, knob, caption.
    for ([2]u32{ 2, 6 }, [2]bool{ false, true }) |row, on| {
        const track = t.rect(row + 1);
        try testing.expectEqual([2]f32{ 32, 18 }, [2]f32{ track.w(), track.h() });
        const knob = t.rect(row + 2);
        try testing.expectEqual([2]f32{ 14, 14 }, [2]f32{ knob.w(), knob.h() });
        try testing.expectEqual(if (on) track.x1 - 16 else track.x0 + 2, knob.x0);
        try testing.expectEqual(track.y0 + 2, knob.y0);
        try testing.expectEqual(track.x1 + th.gap, t.rect(row + 3).x0);
        try testing.expectEqual((if (on) th.accent else th.control).bitsOf(), t.c.look[row + 1].fill);
        try testing.expectEqual(th.text.bitsOf(), t.c.look[row + 2].fill);
    }
}

test "switch look: theme tokens reach both front ends" {
    const S = struct {
        var h: Two(.{ .accent = .rgb(3, 4, 5), .text = .rgb(6, 7, 8), .gap = 1 }).Run = .{};
    };
    S.h.init();
    const in: Input = .{ .viewport = .{ 200, 100 } };
    const out = try S.h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(Color.rgb(3, 4, 5).bitsOf(), t.c.look[7].fill);
    try testing.expectEqual(Color.rgb(6, 7, 8).bitsOf(), t.c.look[4].fill);
    try testing.expectEqual(t.rect(3).x1 + 1, t.rect(5).x0);
}

test "switch input: click and Space flip it, Enter and Space down do not, in both front ends" {
    const h = &two;
    h.init();
    const k = base.keys;
    var in: Input = .{ .viewport = .{ 200, 100 } };
    var out = try h.frame(&in);
    const t = out.runtime.tree;
    const vs = t.rect(t.find(.from("vsync")));
    const hd = t.rect(t.find(.from("hdr")));
    const up = [_]Input.Event{.{ .kind = .release, .code = k.space }};
    const down = [_]Input.Event{.{ .kind = .press, .code = k.space }};
    const enter = [_]Input.Event{.{ .kind = .press, .code = k.enter }};
    const Step = struct { at: types.Rect, left: bool = false, events: []const Input.Event = &.{}, vsync: bool, hdr: bool };
    const steps = [_]Step{
        .{ .at = vs, .left = true, .vsync = false, .hdr = true },
        .{ .at = vs, .vsync = true, .hdr = true }, // click
        .{ .at = vs, .events = &down, .vsync = true, .hdr = true },
        .{ .at = vs, .events = &up, .vsync = false, .hdr = true }, // Space
        .{ .at = vs, .events = &enter, .vsync = false, .hdr = true },
        .{ .at = hd, .left = true, .vsync = false, .hdr = true },
        .{ .at = hd, .vsync = false, .hdr = false }, // click the other
        .{ .at = hd, .events = &up, .vsync = false, .hdr = true },
    };
    for (steps) |st| {
        in.pointer = .{ (st.at.x0 + st.at.x1) * 0.5, (st.at.y0 + st.at.y1) * 0.5 };
        in.buttons.left = st.left;
        in.events = st.events;
        out = try h.frame(&in);
        try testing.expectEqual(st.vsync, h.app.vsync);
        try testing.expectEqual(st.hdr, h.app.hdr);
        try testing.expectEqual(st.vsync, h.ui.signals.state.vsync);
        try testing.expectEqual(st.hdr, h.ui.signals.state.hdr);
        try testing.expectEqual(simd.b2f(st.vsync), out.runtime.tree.c.value[2]);
    }
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
