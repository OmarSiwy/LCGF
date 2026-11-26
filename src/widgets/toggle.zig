//! Toggle button: a button that stays pressed until it is pressed again (bold, mute, pin).
//! Tier 2, written against the public API of tiers 0 and 1 (the recipe in base.zig).
//!
//! Accessibility: role toggle button (`a11y.Role.toggle_button`: ARIA's button with
//! `aria-pressed`, AccessKit's button with `Toggled`), named by its caption, value 1 while
//! pressed and 0 released, from which a11y/tree.zig `states` sets `pressed`. `types.Role` has
//! no toggle button, so both front ends write the byte over the button's role.
//!
//! State: the application's `bool`, true while pressed. The runtime front end takes a pointer
//! to it; the comptime front end binds a `bool` field, checked while compiling. The caption is
//! a bound label, as a button's.

const std = @import("std");
const base = @import("base.zig");
const keys = @import("keys.zig");
const label_zig = @import("label.zig");
const button_zig = @import("button.zig");
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
const a11y = @import("../a11y/tree.zig");

/// The toggle-button role byte both front ends write.
const role: u8 = @backingInt(a11y.Role.toggle_button);

// ---- spec -----------------------------------------------------------------------------------

/// The type of a toggle button's bound field: pressed or not.
pub const Bind = bool;

/// Why `State`'s field `name` cannot be a toggle button's state, or null when it can.
pub fn bindError(comptime State: type, comptime name: []const u8) ?[]const u8 {
    return base.fieldError(State, "toggle button", name, Bind);
}

// ---- look -----------------------------------------------------------------------------------

/// The face's colours: released, the control fills; pressed, the accent at rest and under the
/// pointer and the held colour while held. Indexed `[pressed][stateIndex]`.
pub fn toggleFills(th: *const Theme) [2]base.StateColors {
    return .{ th.controlFills(), .{ th.accent, th.accent, th.control_held, th.control_held } };
}

/// The face's colour, picked by table index from whether it is pressed and from hover and
/// held. The face itself is a button's (`button.buttonStyle`).
pub fn toggleFill(th: *const Theme, pressed: bool, r: Response) Color {
    return toggleFills(th)[@intFromBool(pressed)][base.stateIndex(r)];
}

// ---- runtime front end ----------------------------------------------------------------------

/// A toggle button named `id` over `value`, captioned by `str`. It flips when it fires as a
/// button does (`button.activated`: a click, or Enter or Space while focused; WAI-ARIA APG
/// button pattern, toggle button) and sets `clicked` then.
pub fn toggle(f: *Frame, th: *const Theme, id: Id, value: *bool, str: []const u8) Response {
    return toggleFace(f, th, id, value, str, button_zig.buttonStyle(th));
}

/// `toggle` laid out by `face` instead of the button's style, as `spec.styled` restyles
/// `ct.toggle`; the fill still follows the value, hover and held.
pub fn toggleFace(f: *Frame, th: *const Theme, id: Id, value: *bool, str: []const u8, face: Style) Response {
    const node = f.open(id, face);
    var r = f.interact(node, .button);
    r.clicked = button_zig.activated(r.clicked, r.focused, f.in);
    value.* = base.toggle(value.*, r.clicked);
    f.setFill(node, toggleFill(th, value.*, r));
    f.setCursor(.pointer, r.hovered);
    _ = label_zig.label(f, th, str);
    f.close();
    f.tree().c.value[node.ix()] = simd.b2f(value.*);
    f.tree().c.role[node.ix()] = role;
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A toggle button named `id` over the `bool` field `bind`, captioned by the string field
    /// `text`: `ct.toggle(th, .bold, .bold, .bold_text)`.
    pub fn toggle(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime text: anytype) Spec {
        var s = spec_zig.row(button_zig.buttonStyle(&th), .{label_zig.ct.label(th, text)});
        s.id = @tagName(id);
        s.bind = @tagName(bind);
        s.widget = Comptime(@tagName(id), @tagName(bind));
        return s;
    }
};

/// The comptime toggle button named `name` over field `bind` (`Spec.widget`): the same rows
/// as `toggle`, and the same input (`button.activated`, `base.toggle`) applied to the comptime
/// front end's state; Enter and Space on it while focused are also its event.
pub fn Comptime(comptime name: [:0]const u8, comptime bind: []const u8) type {
    return struct {
        pub const focusable = true;

        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            return base.fieldError(State, "toggle button", field, Bind);
        }

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            const value: bool = @field(ui.signals.state, bind);
            const row = next.*;
            next.* += 1;
            var s = n.style;
            s.fill = toggleFill(&@TypeOf(ui.*).theme, value, ui.response(row, in));
            s.value = simd.b2f(value);
            const i = ui.tables.t.push(parent, .hash(name), &s);
            ui.tables.t.c.role[i] = role;
            ui.push(n.children[0], i, next, in);
            ui.tables.t.seal(i);
        }

        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) @TypeOf(event) {
            const Ui = @TypeOf(ui.*);
            const r = base.ctResponse(ui, row, event, in);
            if (!button_zig.activated(r.clicked, r.focused, in)) return null;
            ui.signals.set(Ui.field(bind), base.toggle(@field(ui.signals.state, bind), true));
            if (r.clicked) return null;
            return @unionInit(Ui.Events.Event, name, {});
        }
    };
}

// ---- example page -------------------------------------------------------------------------

/// The toggle button's example page: B, I and U (pressed) on a toolbar, in both front ends.
/// Its replay (testdata/toggle.replay) clicks, uses Enter and Space and drags off; its golden
/// images (tools/golden/ref/widgets/toggle-*.png) show pressed and released faces.
pub const Page = struct {
    const th = Theme.default;
    const bar: Style = .{ .dir = .x, .size = .{ .fill, .fill }, .pad = @splat(12), .gap = 8, .cross = .start, .fill = th.panel };

    pub const App = struct {
        bold: bool = false,
        italic: bool = false,
        underline: bool = true,
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.from("bar"), bar);
            _ = toggle(f, &th, .from("bold"), &app.bold, "B");
            _ = toggle(f, &th, .from("italic"), &app.italic, "I");
            _ = toggle(f, &th, .from("underline"), &app.underline, "U");
            f.close();
        }
    };
    pub const State = struct {
        bold: bool = false,
        bold_text: []const u8 = "B",
        italic: bool = false,
        italic_text: []const u8 = "I",
        underline: bool = true,
        underline_text: []const u8 = "U",
    };
    pub const spec = spec_zig.row(bar, .{
        ct.toggle(th, .bold, .bold, .bold_text),
        ct.toggle(th, .italic, .italic, .italic_text),
        ct.toggle(th, .underline, .underline, .underline_text),
    });
    pub const Ui = base.ComptimeUi(State, spec, th);
    pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });
    pub const replay = @embedFile("testdata/toggle.replay");
    /// Frames kept as golden images, by name: tools/golden/ref/widgets/toggle-<name>.png.
    pub const golden_frames = .{ .{ "rest", 0 }, .{ "held", 1 }, .{ "pressed", 2 } };
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "bindError: a toggle button binds a bool" {
    const State = struct { bold: bool = false, size: f32 = 0 };
    try testing.expectEqual(null, comptime bindError(State, "bold"));
    try testing.expectEqualStrings("toggle button 'size' needs a bool field, not f32", comptime bindError(State, "size").?);
}

test "ct.toggle: a named widget with a void event, bound to its field, captioned" {
    const events = @import("../comptime/events.zig");
    const s = comptime ct.toggle(.default, .bold, .bold, .bold_text);
    try testing.expect(s.widget != null);
    try testing.expectEqualStrings("bold", s.id.?);
    try testing.expectEqualStrings("bold", s.bind.?);
    try testing.expectEqualStrings("bold_text", s.children[0].bind.?);
    const E = events.Events(s);
    try testing.expectEqual(void, @FieldType(E.Event, "bold"));
}

/// Two toggle buttons, released and pressed, in both front ends, in theme `th`: the tests'
/// page until the example page (C0550).
fn Two(comptime th: Theme) type {
    return struct {
        const row: Style = .{ .dir = .x, .pad = @splat(8), .gap = 8 };
        pub const App = struct {
            bold: bool = false,
            italic: bool = true,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.from("row"), row);
                _ = toggle(f, &th, .from("bold"), &app.bold, "B");
                _ = toggle(f, &th, .from("italic"), &app.italic, "I");
                f.close();
            }
        };
        pub const State = struct { bold: bool = false, bold_text: []const u8 = "B", italic: bool = true, italic_text: []const u8 = "I" };
        pub const Ui = base.ComptimeUi(State, spec_zig.row(row, .{ ct.toggle(th, .bold, .bold, .bold_text), ct.toggle(th, .italic, .italic, .italic_text) }), th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });
    };
}

var two: Two(.default).Run = .{};

test "toggleFills: released is the button's table, pressed the accent until held" {
    const th = Theme.default;
    const t = toggleFills(&th);
    try testing.expectEqual(th.controlFills(), t[0]);
    try testing.expectEqual(base.StateColors{ th.accent, th.accent, th.control_held, th.control_held }, t[1]);
    for (0..4) |k| {
        const r: Response = .{ .hovered = k & 1 != 0, .held = k & 2 != 0 };
        try testing.expectEqual(button_zig.buttonFill(&th, r), toggleFill(&th, false, r));
        try testing.expectEqual(t[1][k], toggleFill(&th, true, r));
    }
}

test "toggle look: a button's face, filled by pressed and by hover, in both front ends" {
    const h = &two;
    h.init();
    const th = Theme.default;
    var in: Input = .{ .viewport = .{ 200, 60 } };
    var out = try h.frame(&in);
    // Rows: root, row, then per toggle: face, caption.
    const t = out.runtime.tree;
    try testing.expectEqual(th.control.bitsOf(), t.c.look[2].fill);
    try testing.expectEqual(th.accent.bitsOf(), t.c.look[4].fill);
    try testing.expectEqual(th.radius, t.c.look[2].radius);
    try testing.expectApproxEqAbs(@as(f32, 2 * th.pad + 8.4), t.rect(2).w(), 0.5);
    const r = t.rect(2);
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    out = try h.frame(&in);
    try testing.expectEqual(th.control_hot.bitsOf(), out.runtime.tree.c.look[2].fill);
}

test "toggle input: click, Enter and Space up flip it; Space down does not, in both front ends" {
    const h = &two;
    h.init();
    const k = keys;
    var in: Input = .{ .viewport = .{ 200, 60 } };
    var out = try h.frame(&in);
    const t = out.runtime.tree;
    const b = t.rect(t.find(.from("bold")));
    const i = t.rect(t.find(.from("italic")));
    const enter = [_]Input.Event{.{ .kind = .press, .code = k.enter }};
    const sdown = [_]Input.Event{.{ .kind = .press, .code = k.space }};
    const sup = [_]Input.Event{.{ .kind = .release, .code = k.space }};
    const Step = struct { at: types.Rect, left: bool = false, events: []const Input.Event = &.{}, bold: bool, italic: bool };
    const steps = [_]Step{
        .{ .at = b, .left = true, .bold = false, .italic = true },
        .{ .at = b, .bold = true, .italic = true }, // click
        .{ .at = b, .events = &enter, .bold = false, .italic = true },
        .{ .at = b, .events = &sdown, .bold = false, .italic = true },
        .{ .at = b, .events = &sup, .bold = true, .italic = true },
        .{ .at = i, .left = true, .bold = true, .italic = true },
        .{ .at = i, .bold = true, .italic = false },
    };
    const th = Theme.default;
    for (steps) |st| {
        in.pointer = .{ (st.at.x0 + st.at.x1) * 0.5, (st.at.y0 + st.at.y1) * 0.5 };
        in.buttons.left = st.left;
        in.events = st.events;
        out = try h.frame(&in);
        try testing.expectEqual(st.bold, h.app.bold);
        try testing.expectEqual(st.italic, h.app.italic);
        try testing.expectEqual(st.bold, h.ui.signals.state.bold);
        try testing.expectEqual(st.italic, h.ui.signals.state.italic);
        try testing.expectEqual(simd.b2f(st.bold), out.runtime.tree.c.value[2]);
    }
    // Pressed by the click and released over it: the accent under the pointer.
    try testing.expectEqual(th.control_hot.bitsOf(), out.runtime.tree.c.look[4].fill);
    try testing.expectEqual(th.accent.bitsOf(), out.runtime.tree.c.look[2].fill);
}

var toggle_semantics: base.Semantic(16) = .{};

test "toggle a11y: role toggle button, named by its caption, pressed from its value, in both front ends" {
    const h = &two;
    h.init();
    const in: Input = .{ .viewport = .{ 200, 60 } };
    _ = try h.frame(&in);
    const x = &toggle_semantics;
    try x.run(h);
    for ([2]u32{ 2, 4 }, [2][]const u8{ "B", "I" }, [2]bool{ false, true }) |node, name, pressed| {
        const r = x.row(node).?;
        try testing.expectEqual(@backingInt(a11y.Role.toggle_button), x.out[0].c.role[r]);
        try testing.expectEqualStrings(name, x.name(0, r));
        try testing.expectEqualStrings(name, x.name(1, r));
        try testing.expectEqual(simd.b2f(pressed), x.out[0].c.value[r]);
        const st: a11y.State = .{ .pressed = pressed };
        try testing.expectEqual(st.bitsOf(), x.out[0].c.state[r]);
    }
}

var page: Page.Run = .{};

test "Page: the toggle replay flips by click, Enter and Space, in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &page;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = Page.replay };
    var bold: [10]bool = undefined;
    var italic: [10]bool = undefined;
    var underline: [10]bool = undefined;
    while (try replay.next(buf)) |in| {
        const k = h.frames;
        _ = try h.frame(in);
        const st = &h.ui.signals.state;
        try testing.expectEqual(h.app.bold, st.bold);
        try testing.expectEqual(h.app.italic, st.italic);
        try testing.expectEqual(h.app.underline, st.underline);
        bold[k] = h.app.bold;
        italic[k] = h.app.italic;
        underline[k] = h.app.underline;
    }
    try testing.expectEqual(@as(u32, 10), h.frames);
    try testing.expectEqualSlices(bool, &.{ false, false, true, false, true, true, true, true, true, true }, &bold);
    try testing.expectEqualSlices(bool, &.{ false, false, false, false, false, false, true, true, true, true }, &italic);
    const always: [10]bool = @splat(true);
    try testing.expectEqualSlices(bool, &always, &underline);
    // The rects the replay's comment gives.
    const t = &h.ctx.trees[h.ctx.cur];
    for ([3][]const u8{ "bold", "italic", "underline" }, [3][2]f32{ .{ 12, 36 }, .{ 44, 69 }, .{ 77, 101 } }) |name, x| {
        const r = t.rect(t.find(.hash(name)));
        try testing.expectEqual([4]f32{ x[0], 12, x[1], 46 }, [4]f32{ r.x0, r.y0, r.x1, r.y1 });
    }
    inline for (Page.golden_frames) |g| try testing.expect(g[1] < 10);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}

test "toggleFace: restyled as spec.styled restyles ct.toggle, in both front ends" {
    const S = struct {
        const th = Theme.default;
        const face: Style = blk: {
            var st = button_zig.buttonStyle(&th);
            st.size = .{ .px(120), .px(40) };
            st.border = 2;
            st.border_color = .rgb(200, 10, 10);
            break :blk st;
        };
        const App = struct {
            on: bool = false,
            clicks: u32 = 0,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, .{ .dir = .x });
                app.clicks += @intFromBool(toggleFace(f, &th, .from("on"), &app.on, "On", face).clicked);
                f.close();
            }
        };
        const Ui = base.ComptimeUi(struct { on: bool = false }, spec_zig.row(.{}, .{spec_zig.styled(ct.toggle(th, .on, .on, "On"), face)}), th);
        var h: base.Harness(App, Ui, .{ .nodes = 8, .texts = 2, .customs = 1, .strings = 64, .depth = 8 }) = .{};
    };
    S.h.init();
    var in: Input = .{ .viewport = .{ 200, 60 } };
    const out = try S.h.frame(&in);
    try testing.expectEqual(@as(f32, 120), out.runtime.tree.rect(2).w());
    // Hover, press and release over it: both draw the same frames, and it fires.
    in.pointer = .{ 60, 20 };
    for ([_]bool{ false, true, false }) |down| {
        in.buttons.left = down;
        _ = try S.h.frame(&in);
    }
    try testing.expectEqual(1, S.h.app.clicks);
}
