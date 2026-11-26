//! Button: a caption on a face that reports a click. Tier 2, written against the public API
//! of tiers 0 and 1 (the recipe in base.zig).
//!
//! Accessibility: role button, named by its caption (ARIA name from content), no value and
//! no states; the bridge reads both from the tree's `role` and `value` columns.
//!
//! State: none of its own. The caption is the application's string (`str` in the runtime
//! front end, a `[]const u8` field bound by the caption's label in the comptime one, checked
//! as a label's binding), and a click is reported, not stored: `Response.clicked` in the
//! runtime front end, the button's `Event` (no payload) in the comptime one.

const std = @import("std");
const base = @import("base.zig");
const keys = @import("keys.zig");
const label_zig = @import("label.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Response = types.Response;
const Style = types.Style;
const TextStyle = types.TextStyle;
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
    const keyed = keys.keyCount(in, keys.enter, .press) + keys.keyCount(in, keys.space, .release) != 0;
    return simd.orB(clicked, simd.andB(focused, keyed));
}

// ---- runtime front end ----------------------------------------------------------------------

/// A button named `id` showing `str`; `clicked` is set the frame it fires (`activated`): the
/// left button goes up over it after going down on it, or, while it has focus, Enter or Space.
pub fn button(f: *Frame, th: *const Theme, id: Id, str: []const u8) Response {
    return buttonStyled(f, th, id, str, label_zig.labelText(th));
}

/// `button` with its caption drawn in `ts` instead of the theme's label text.
pub fn buttonStyled(f: *Frame, th: *const Theme, id: Id, str: []const u8, ts: TextStyle) Response {
    return buttonFace(f, th, id, str, ts, buttonStyle(th));
}

/// `buttonStyled` with its face laid out by `face` instead of `buttonStyle(th)`, as
/// `spec.styled` restyles `ct.button` (CSS on a `<button>`); the fill still follows hover and
/// held.
pub fn buttonFace(f: *Frame, th: *const Theme, id: Id, str: []const u8, ts: TextStyle, face: Style) Response {
    const node = f.open(id, face);
    var r = f.interact(node, .button);
    r.clicked = activated(r.clicked, r.focused, f.in);
    f.setFill(node, buttonFill(th, r));
    f.setCursor(.pointer, r.hovered);
    _ = f.textStyled(str, ts, label_zig.labelStyle(th));
    f.close();
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A button named `id` showing the string field `text`; its click is its event:
    /// `ct.button(th, .reset, .reset_text)`. A `Widget` with a `void` event, built and
    /// stepped by `Comptime` (`Spec.widget`).
    pub fn button(comptime th: Theme, comptime id: @EnumLiteral(), comptime text: anytype) Spec {
        return face(th, id, label_zig.ct.label(th, text));
    }

    /// `button` with its caption drawn in `text_style` instead of the page theme's (CSS
    /// `color` and `font-size` on a `<button>`): `ct.buttonStyled(th, .go, "Go", .{ .px = 18 })`.
    pub fn buttonStyled(comptime th: Theme, comptime id: @EnumLiteral(), comptime text: anytype, comptime text_style: TextStyle) Spec {
        return face(th, id, spec_zig.textStyled(label_zig.ct.label(th, text), text_style));
    }

    fn face(comptime th: Theme, comptime id: @EnumLiteral(), comptime caption: Spec) Spec {
        var s = spec_zig.row(buttonStyle(&th), .{caption});
        s.id = @tagName(id);
        s.widget = Comptime(@tagName(id));
        return s;
    }
};

/// The comptime button named `name` (`Spec.widget`): it builds the same rows as `button`, with
/// the comptime front end's hover and held, and turns Enter and Space on it while focused into
/// its event, as `button` sets `clicked`.
pub fn Comptime(comptime name: [:0]const u8) type {
    return struct {
        pub const focusable = true;

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            const row = next.*;
            next.* += 1;
            var s = n.style;
            s.fill = buttonFill(&@TypeOf(ui.*).theme, ui.response(row, in));
            const i = ui.tables.t.push(parent, .hash(name), &s);
            ui.push(n.children[0], i, next, in);
            ui.tables.t.seal(i);
        }

        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) @TypeOf(event) {
            const r = base.ctResponse(ui, row, event, in);
            if (!r.clicked and activated(false, r.focused, in)) return @unionInit(@TypeOf(ui.*).Events.Event, name, {});
            return null;
        }
    };
}

// ---- example page -------------------------------------------------------------------------

/// The button's example page: two buttons on a panel, in both front ends, counting their
/// clicks. Its replay (testdata/button.replay) clicks, drags off and uses Enter and Space; its
/// golden images (tools/golden/ref/widgets/button-*.png) are the face at rest, hovered, held.
pub const Page = struct {
    const th = Theme.default;
    const panel: Style = .{ .dir = .x, .size = .{ .fill, .fill }, .pad = @splat(12), .gap = 8, .cross = .start, .fill = th.panel };

    pub const App = struct {
        resets: u32 = 0,
        applies: u32 = 0,
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.from("panel"), panel);
            app.resets += @intFromBool(button(f, &th, .from("reset"), "Reset").clicked);
            app.applies += @intFromBool(button(f, &th, .from("apply"), "Apply").clicked);
            f.close();
        }
    };
    pub const State = struct { reset_text: []const u8 = "Reset", apply_text: []const u8 = "Apply" };
    pub const spec = spec_zig.row(panel, .{ ct.button(th, .reset, .reset_text), ct.button(th, .apply, .apply_text) });
    pub const Ui = base.ComptimeUi(State, spec, th);
    pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });
    pub const replay = @embedFile("testdata/button.replay");
    /// Frames kept as golden images, by name: tools/golden/ref/widgets/button-<name>.png.
    pub const golden_frames = .{ .{ "rest", 0 }, .{ "hover", 1 }, .{ "held", 2 } };
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;
const events = @import("../comptime/events.zig");

test "ct.button: a named widget with a void event, its caption a bound label" {
    const s = comptime ct.button(.default, .go, .go_text);
    try testing.expectEqual(spec_zig.Kind.row, s.kind);
    try testing.expect(s.widget != null);
    try testing.expectEqualStrings("go", s.id.?);
    try testing.expectEqual(null, s.bind);
    try testing.expectEqual(types.Axis.x, s.style.dir);
    try testing.expectEqual(spec_zig.Kind.label, s.children[0].kind);
    try testing.expectEqualStrings("go_text", s.children[0].bind.?);
    const E = events.Events(spec_zig.row(.{}, .{ s, comptime ct.button(.default, .stop, .stop_text) }));
    try testing.expectEqual(void, @FieldType(E.Event, "go"));
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
        pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });
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

test "ct.buttonStyled: the caption's text style in both front ends" {
    const S = struct {
        const th = Theme.default;
        const ts: TextStyle = .{ .px = 20, .color = .rgb(250, 10, 10) };
        const App = struct {
            pub fn build(_: *App, f: *Frame) void {
                _ = f.open(.none, .{ .dir = .x });
                _ = buttonStyled(f, &th, .from("go"), "Go", ts);
                f.close();
            }
        };
        const Ui = base.ComptimeUi(struct {}, spec_zig.row(.{}, .{ct.buttonStyled(th, .go, "Go", ts)}), th);
        var h: base.Harness(App, Ui, .{ .nodes = 8, .texts = 2, .customs = 1, .strings = 64, .depth = 4 }) = .{};
    };
    S.h.init();
    const out = try S.h.frame(&.{ .viewport = .{ 200, 60 } });
    const tx = out.runtime.texts;
    try testing.expectEqual(@as(f32, 20), tx.c.px[0]);
    try testing.expectEqual(S.ts.color.bitsOf(), tx.c.color[0]);
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
    const enter = ev.in(&.{.{ .kind = .press, .code = keys.enter }});
    try testing.expect(activated(false, true, &enter));
    try testing.expect(!activated(false, false, &enter));
    const space_down = ev.in(&.{.{ .kind = .press, .code = keys.space }});
    try testing.expect(!activated(false, true, &space_down));
    const space_up = ev.in(&.{.{ .kind = .release, .code = keys.space }});
    try testing.expect(activated(false, true, &space_up));
    const ctrl_enter = ev.in(&.{.{ .kind = .press, .code = keys.enter, .mods = .{ .ctrl = true } }});
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
    const enter: Input.Event = .{ .kind = .press, .code = keys.enter };
    const space_down: Input.Event = .{ .kind = .press, .code = keys.space };
    const space_up: Input.Event = .{ .kind = .release, .code = keys.space };
    const steps = [_]Step{
        .{ .fires = false }, // hover
        .{ .left = true, .fires = false }, // press: focus
        .{ .fires = true }, // release over it: click
        .{ .events = &.{enter}, .fires = true },
        .{ .events = &.{space_down}, .fires = false },
        .{ .events = &.{space_up}, .fires = true },
        .{ .events = &.{.{ .kind = .press, .code = keys.enter, .mods = .{ .shift = true } }}, .fires = false },
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
    // Tab gives it focus back without the pointer; Enter fires again.
    in.events = &.{.{ .kind = .press, .code = 0x2b }};
    _ = try h.frame(&in);
    in.events = &.{enter};
    out = try h.frame(&in);
    try testing.expect(h.app.clicked);
    try testing.expect(out.comptime_.event != null);
}

var button_semantics: base.Semantic(16) = .{};

test "button a11y: role button, named by its caption, value 0, no states, in both front ends" {
    const a11y = @import("../a11y/tree.zig");
    const h = &one;
    h.init();
    var in: Input = .{ .viewport = .{ 200, 60 } };
    _ = try h.frame(&in);
    // Held and focused: still no state bits and no value.
    in.pointer = .{ 20, 20 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    const x = &button_semantics;
    try x.run(h);
    const r = x.row(2).?;
    try testing.expectEqual(@backingInt(a11y.Role.button), x.out[0].c.role[r]);
    try testing.expectEqual(@backingInt(Id.from("go")), x.out[0].c.id[r]);
    try testing.expectEqualStrings("Go", x.name(0, r));
    try testing.expectEqualStrings("Go", x.name(1, r));
    try testing.expectEqual(@as(f32, 0), x.out[0].c.value[r]);
    try testing.expectEqual(@as(u8, 0), x.out[0].c.state[r]);
    // Its caption is exported as its child, static text.
    try testing.expectEqual(r, x.out[0].c.parent[x.row(3).?]);
}

var page: Page.Run = .{};

test "Page: the button replay fires on click, Enter and Space up, in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &page;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = Page.replay };
    const Fired = enum { none, reset, apply };
    var fired: [12]Fired = undefined;
    var fills: [12]u32 = undefined;
    while (try replay.next(buf)) |in| {
        const k = h.frames;
        const before = .{ h.app.resets, h.app.applies };
        const out = try h.frame(in);
        const rt: Fired = if (h.app.resets != before[0]) .reset else if (h.app.applies != before[1]) .apply else .none;
        const cp: Fired = if (out.comptime_.event) |e| switch (e) {
            .reset => .reset,
            .apply => .apply,
        } else .none;
        try testing.expectEqual(rt, cp);
        fired[k] = rt;
        fills[k] = out.runtime.tree.c.look[2].fill;
    }
    try testing.expectEqual(@as(u32, 12), h.frames);
    try testing.expectEqualSlices(Fired, &.{ .none, .none, .none, .reset, .reset, .none, .reset, .none, .none, .none, .apply, .none }, &fired);
    try testing.expectEqual(@as(u32, 3), h.app.resets);
    try testing.expectEqual(@as(u32, 1), h.app.applies);
    const c = Theme.default.controlFills();
    try testing.expectEqualSlices(u32, &.{ c[0].bitsOf(), c[1].bitsOf(), c[3].bitsOf(), c[1].bitsOf() }, fills[0..4]);
    // The rects the replay's comment gives.
    const t = &h.ctx.trees[h.ctx.cur];
    try testing.expectEqual(types.Rect{ .x0 = 12, .y0 = 12, .x1 = 70, .y1 = 46 }, t.rect(t.find(.from("reset"))));
    try testing.expectEqual(types.Rect{ .x0 = 78, .y0 = 12, .x1 = 136, .y1 = 46 }, t.rect(t.find(.from("apply"))));
    inline for (Page.golden_frames) |g| try testing.expect(g[1] < 12);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}

test "buttonFace: restyled as spec.styled restyles ct.button, in both front ends" {
    const S = struct {
        const th = Theme.default;
        const face: Style = blk: {
            var st = buttonStyle(&th);
            st.size = .{ .px(120), .px(40) };
            st.border = 2;
            st.border_color = .rgb(200, 10, 10);
            break :blk st;
        };
        const App = struct {
            clicks: u32 = 0,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, .{ .dir = .x });
                app.clicks += @intFromBool(buttonFace(f, &th, .from("go"), "Go", label_zig.labelText(&th), face).clicked);
                f.close();
            }
        };
        const Ui = base.ComptimeUi(struct {}, spec_zig.row(.{}, .{spec_zig.styled(ct.button(th, .go, "Go"), face)}), th);
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
