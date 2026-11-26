//! Checkbox: a box and a caption; a click toggles it. Tier 2, written against the public API
//! of tiers 0 and 1 (the recipe in base.zig).
//!
//! State: the application's value, a `bool` (two states) or a `Check` (three: the mixed
//! state shows that some of what the box stands for is on). The runtime front end takes a
//! pointer to it; the comptime front end binds a `bool` or `Check` field, checked while
//! compiling. The caption is a bound label, as a button's.

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
const Color = types.Color;
const Input = @import("../core/input.zig").Input;
const simd = @import("../core/simd.zig");

// ---- spec -----------------------------------------------------------------------------------

/// A tri-state checkbox's value. The application sets `mixed`; input only ever makes it `on`
/// or `off`.
pub const Check = enum(u2) {
    off,
    on,
    mixed,

    /// `v` as a `Check`: a `bool` is off or on, a `Check` is itself.
    pub fn of(v: anytype) Check {
        return if (@TypeOf(v) == bool) @fromBackingInt(@intCast(@intFromBool(v))) else v;
    }

    /// What the tree's `value` column holds, which accessibility reads: off 0, on 1, mixed
    /// 0.5 (ARIA `aria-checked="mixed"`).
    pub fn value(c: Check) f32 {
        const table = [3]f32{ 0, 1, 0.5 };
        return table[@backingInt(c)];
    }
};

/// Why `State`'s field `name` cannot be a checkbox's value, or null when it can: it must be a
/// `bool` or a `Check`.
pub fn bindError(comptime State: type, comptime name: []const u8) ?[]const u8 {
    return bindCheck(State, name);
}

fn bindCheck(comptime State: type, comptime name: []const u8) ?[]const u8 {
    const as_bool = base.fieldError(State, "checkbox", name, bool) orelse return null;
    if (base.fieldError(State, "checkbox", name, Check) == null) return null;
    return comptime as_bool ++ " (or Check)";
}

/// `v` toggled by `clicked`, in its own type: a `bool` flips, a `Check` goes to `on` from
/// `off` or `mixed` and to `off` from `on`.
pub fn flip(v: anytype, clicked: bool) @TypeOf(v) {
    const now = Check.of(v);
    // Indexed by `clicked`: stay, or the other side of `on`.
    const to = [2]Check{ now, Check.of(now != .on) };
    const c = to[@intFromBool(clicked)];
    return if (@TypeOf(v) == bool) c == .on else c;
}

// ---- behaviour ------------------------------------------------------------------------------

/// Whether the checkbox toggles this frame: clicked, or focused and Space came up (WAI-ARIA
/// APG checkbox pattern: Space toggles, Enter does not; on release, as native checkboxes do).
/// What it toggles to is `flip`'s: a mixed box goes to on.
pub fn toggled(clicked: bool, focused: bool, in: *const Input) bool {
    return simd.orB(clicked, simd.andB(focused, keys.keyCount(in, keys.space, .release) != 0));
}

// ---- look -----------------------------------------------------------------------------------

/// The row: box, then caption, centred across, `gap` apart; role checkbox.
pub fn checkboxStyle(th: *const Theme) Style {
    return .{ .dir = .x, .gap = th.gap, .cross = .center, .role = .checkbox };
}

/// The box's fill by value: off the control colour, on and mixed the accent.
pub fn boxFills(th: *const Theme) [3]Color {
    return .{ th.control, th.accent, th.accent };
}

/// The 16 px box, outlined, filled by `boxFills`; it centres the dash.
pub fn checkboxBox(th: *const Theme, value: Check) Style {
    return .{ .size = .{ .px(16), .px(16) }, .radius = 3, .fill = boxFills(th)[@backingInt(value)], .border = 1, .border_color = th.control_hot, .main = .center, .cross = .center };
}

/// The mixed state's dash across the box: always there, transparent (so it paints nothing)
/// unless the value is mixed, so the look is picked by table index and the rows never change.
pub fn checkboxDash(th: *const Theme, value: Check) Style {
    const fills = [3]Color{ .transparent, .transparent, th.text };
    return .{ .size = .{ .px(8), .px(2) }, .radius = 1, .fill = fills[@backingInt(value)] };
}

// ---- runtime front end ----------------------------------------------------------------------

/// A checkbox named `id` over `value` (a `*bool` or a `*Check`), captioned by `str`. A click,
/// or Space while it has focus, toggles it (`toggled`, `flip`) and sets `clicked`.
pub fn checkbox(f: *Frame, th: *const Theme, id: Id, value: anytype, str: []const u8) Response {
    return checkboxFace(f, th, id, value, str, checkboxStyle(th));
}

/// `checkbox` with its row laid out by `face` instead of `checkboxStyle(th)`, as
/// `spec.styled` restyles `ct.checkbox`.
pub fn checkboxFace(f: *Frame, th: *const Theme, id: Id, value: anytype, str: []const u8, face: Style) Response {
    const row = f.open(id, face);
    var r = f.interact(row, .button);
    r.clicked = toggled(r.clicked, r.focused, f.in);
    value.* = flip(value.*, r.clicked);
    const c = Check.of(value.*);
    _ = f.open(.none, checkboxBox(th, c));
    _ = f.leaf(.none, checkboxDash(th, c));
    f.close();
    _ = label_zig.label(f, th, str);
    f.close();
    f.tree().c.value[row.ix()] = Check.of(value.*).value();
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A checkbox named `id` over the `bool` or `Check` field `bind`, captioned by the string
    /// field `text`: `ct.checkbox(th, .wire, .wireframe, .wire_text)`.
    pub fn checkbox(comptime th: Theme, comptime id: @EnumLiteral(), comptime bind: @EnumLiteral(), comptime text: anytype) Spec {
        // Box (with its dash), caption: the rows the front ends push, so rows keep spec order.
        const box: Spec = .{ .kind = .col, .children = &.{Spec{ .kind = .col }} };
        var s = spec_zig.row(checkboxStyle(&th), .{ box, label_zig.ct.label(th, text) });
        s.id = @tagName(id);
        s.bind = @tagName(bind);
        s.widget = Comptime(@tagName(id), @tagName(bind));
        return s;
    }
};

/// The comptime checkbox named `name` over field `bind` (`Spec.widget`): the same rows as
/// `checkbox`, and the same input (`toggled`, `flip`) applied to the comptime front end's
/// state; Space on it while focused is also its event, as `checkbox` sets `clicked`.
pub fn Comptime(comptime name: [:0]const u8, comptime bind: []const u8) type {
    return struct {
        pub const focusable = true;

        pub fn bindError(comptime State: type, comptime field: []const u8) ?[]const u8 {
            return bindCheck(State, field);
        }

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            const th = &@TypeOf(ui.*).theme;
            const t = &ui.tables.t;
            const value = Check.of(@field(ui.signals.state, bind));
            var s = n.style;
            s.value = value.value();
            next.* += 3; // the checkbox, its box and the dash
            const i = t.push(parent, .hash(name), &s);
            const box = t.push(i, .none, &checkboxBox(th, value));
            _ = t.push(box, .none, &checkboxDash(th, value));
            t.seal(box);
            ui.push(n.children[1], i, next, in);
            t.seal(i);
        }

        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) @TypeOf(event) {
            const Ui = @TypeOf(ui.*);
            const r = base.ctResponse(ui, row, event, in);
            if (!toggled(r.clicked, r.focused, in)) return null;
            ui.signals.set(Ui.field(bind), flip(@field(ui.signals.state, bind), true));
            if (r.clicked) return null;
            return @unionInit(Ui.Events.Event, name, {});
        }
    };
}

// ---- example page -------------------------------------------------------------------------

/// The checkbox's example page: a tri-state "All" that starts mixed and two plain boxes on a
/// panel, in both front ends. Its replay (testdata/checkbox.replay) clicks and uses Space; its
/// golden images (tools/golden/ref/widgets/checkbox-*.png) show mixed, on and off.
pub const Page = struct {
    const th = Theme.default;
    const panel: Style = .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(12), .gap = 8, .fill = th.panel };

    pub const App = struct {
        all: Check = .mixed,
        wire: bool = false,
        shadows: bool = true,
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.from("panel"), panel);
            _ = checkbox(f, &th, .from("all"), &app.all, "All");
            _ = checkbox(f, &th, .from("wire"), &app.wire, "Wireframe");
            _ = checkbox(f, &th, .from("shadows"), &app.shadows, "Shadows");
            f.close();
        }
    };
    pub const State = struct {
        all: Check = .mixed,
        all_text: []const u8 = "All",
        wire: bool = false,
        wire_text: []const u8 = "Wireframe",
        shadows: bool = true,
        shadows_text: []const u8 = "Shadows",
    };
    pub const spec = spec_zig.col(panel, .{
        ct.checkbox(th, .all, .all, .all_text),
        ct.checkbox(th, .wire, .wire, .wire_text),
        ct.checkbox(th, .shadows, .shadows, .shadows_text),
    });
    pub const Ui = base.ComptimeUi(State, spec, th);
    pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });
    pub const replay = @embedFile("testdata/checkbox.replay");
    /// Frames kept as golden images, by name: tools/golden/ref/widgets/checkbox-<name>.png.
    pub const golden_frames = .{ .{ "rest", 0 }, .{ "on", 2 }, .{ "keys", 5 } };
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "bindError: a checkbox binds a bool or a Check" {
    const State = struct { on: bool = false, tri: Check = .mixed, level: f32 = 0 };
    try testing.expectEqual(null, comptime bindError(State, "on"));
    try testing.expectEqual(null, comptime bindError(State, "tri"));
    try testing.expectEqualStrings("checkbox 'level' needs a bool field, not f32 (or Check)", comptime bindError(State, "level").?);
    try testing.expectEqualStrings("checkbox 'nope': the state has no such field (or Check)", comptime bindError(State, "nope").?);
}

test "Check: of, value, and flip in either type" {
    try testing.expectEqual(Check.on, Check.of(true));
    try testing.expectEqual(Check.off, Check.of(false));
    try testing.expectEqual(Check.mixed, Check.of(Check.mixed));
    try testing.expectEqual([3]f32{ 0, 1, 0.5 }, [3]f32{ Check.off.value(), Check.on.value(), Check.mixed.value() });
    try testing.expectEqual(true, flip(false, true));
    try testing.expectEqual(false, flip(false, false));
    try testing.expectEqual(Check.on, flip(Check.mixed, true));
    try testing.expectEqual(Check.mixed, flip(Check.mixed, false));
    try testing.expectEqual(Check.off, flip(Check.on, true));
    try testing.expectEqual(Check.on, flip(Check.off, true));
}

test "ct.checkbox: a named widget bound to its field, a box and a caption" {
    const events = @import("../comptime/events.zig");
    const s = comptime ct.checkbox(.default, .tri, .tri, .tri_text);
    try testing.expect(s.widget != null);
    try testing.expectEqualStrings("tri", s.bind.?);
    try testing.expectEqual(@as(usize, 2), s.children.len);
    const E = events.Events(s);
    try testing.expectEqual(void, @FieldType(E.Event, "tri"));
}

/// Two checkboxes, a bool and a tri-state one, in both front ends, in theme `th`: the tests'
/// page until the example page (C0520).
fn Two(comptime th: Theme) type {
    return struct {
        const col: Style = .{ .dir = .y, .pad = @splat(8), .gap = 8 };
        pub const App = struct {
            on: bool = false,
            tri: Check = .mixed,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.from("col"), col);
                _ = checkbox(f, &th, .from("on"), &app.on, "On");
                _ = checkbox(f, &th, .from("tri"), &app.tri, "All");
                f.close();
            }
        };
        pub const State = struct { on: bool = false, on_text: []const u8 = "On", tri: Check = .mixed, tri_text: []const u8 = "All" };
        pub const Ui = base.ComptimeUi(State, spec_zig.col(col, .{ ct.checkbox(th, .on, .on, .on_text), ct.checkbox(th, .tri, .tri, .tri_text) }), th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });
    };
}

var two: Two(.default).Run = .{};

test "checkbox look: box, dash and caption laid out in a row; fills by value, in both front ends" {
    const h = &two;
    h.init();
    const th = Theme.default;
    const in: Input = .{ .viewport = .{ 200, 100 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    // Rows: root, column, then per checkbox: row, box, dash, caption.
    const on: u32 = 2;
    const tri: u32 = 6;
    for ([2]u32{ on, tri }) |row| {
        const box = t.rect(row + 1);
        try testing.expectEqual(@as(f32, 16), box.w());
        try testing.expectEqual(@as(f32, 16), box.h());
        const dash = t.rect(row + 2);
        try testing.expectEqual(types.Rect{ .x0 = box.x0 + 4, .y0 = box.y0 + 7, .x1 = box.x0 + 12, .y1 = box.y0 + 9 }, dash);
        try testing.expectEqual(box.x1 + th.gap, t.rect(row + 3).x0);
    }
    try testing.expectEqual(th.control.bitsOf(), t.c.look[on + 1].fill);
    try testing.expectEqual(Color.transparent.bitsOf(), t.c.look[on + 2].fill);
    try testing.expectEqual(th.accent.bitsOf(), t.c.look[tri + 1].fill);
    try testing.expectEqual(th.text.bitsOf(), t.c.look[tri + 2].fill);
    // Quads: the two boxes and the one visible dash; the off dash paints nothing.
    try testing.expectEqual(@as(u32, 3), out.runtime.draw.quad_len);
}

test "checkbox look: the theme's control, accent and text tokens reach both front ends" {
    const S = struct {
        var h: Two(.{ .control = .rgb(1, 2, 3), .accent = .rgb(4, 5, 6), .text = .rgb(7, 8, 9), .gap = 12 }).Run = .{};
    };
    S.h.init();
    const in: Input = .{ .viewport = .{ 200, 100 } };
    const out = try S.h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(Color.rgb(1, 2, 3).bitsOf(), t.c.look[3].fill);
    try testing.expectEqual(Color.rgb(4, 5, 6).bitsOf(), t.c.look[7].fill);
    try testing.expectEqual(Color.rgb(7, 8, 9).bitsOf(), t.c.look[8].fill);
    try testing.expectEqual(t.rect(3).x1 + 12, t.rect(5).x0);
}

test "toggled: a click, or Space up while focused; not Enter, not Space down" {
    const up = [_]Input.Event{.{ .kind = .release, .code = keys.space }};
    const down = [_]Input.Event{.{ .kind = .press, .code = keys.space }};
    const enter = [_]Input.Event{.{ .kind = .press, .code = keys.enter }};
    const none: Input = .{};
    try testing.expect(toggled(true, false, &none));
    try testing.expect(toggled(false, true, &.{ .events = &up }));
    try testing.expect(!toggled(false, false, &.{ .events = &up }));
    try testing.expect(!toggled(false, true, &.{ .events = &down }));
    try testing.expect(!toggled(false, true, &.{ .events = &enter }));
}

test "checkbox input: click and Space toggle; mixed goes to on, then off and on; in both front ends" {
    const h = &two;
    h.init();
    var in: Input = .{ .viewport = .{ 200, 100 } };
    var out = try h.frame(&in);
    const t = out.runtime.tree;
    const box_on = t.rect(t.find(.from("on")));
    const box_tri = t.rect(t.find(.from("tri")));
    const space_up = [_]Input.Event{.{ .kind = .release, .code = keys.space }};
    const space_down = [_]Input.Event{.{ .kind = .press, .code = keys.space }};
    const Step = struct { at: types.Rect, left: bool = false, events: []const Input.Event = &.{}, on: bool, tri: Check };
    const steps = [_]Step{
        .{ .at = box_tri, .on = false, .tri = .mixed },
        .{ .at = box_tri, .left = true, .on = false, .tri = .mixed },
        .{ .at = box_tri, .on = false, .tri = .on }, // click: mixed -> on
        .{ .at = box_tri, .events = &space_down, .on = false, .tri = .on },
        .{ .at = box_tri, .events = &space_up, .on = false, .tri = .off }, // Space: on -> off
        .{ .at = box_tri, .events = &space_up, .on = false, .tri = .on },
        .{ .at = box_on, .left = true, .on = false, .tri = .on }, // focus moves to "on"
        .{ .at = box_on, .on = true, .tri = .on },
        .{ .at = box_on, .events = &space_up, .on = false, .tri = .on },
    };
    for (steps) |st| {
        in.pointer = .{ (st.at.x0 + st.at.x1) * 0.5, (st.at.y0 + st.at.y1) * 0.5 };
        in.buttons.left = st.left;
        in.events = st.events;
        out = try h.frame(&in);
        try testing.expectEqual(st.on, h.app.on);
        try testing.expectEqual(st.tri, h.app.tri);
        try testing.expectEqual(st.on, h.ui.signals.state.on);
        try testing.expectEqual(st.tri, h.ui.signals.state.tri);
        try testing.expectEqual(Check.of(st.on).value(), out.runtime.tree.c.value[2]);
        try testing.expectEqual(st.tri.value(), out.runtime.tree.c.value[6]);
    }
}

var checkbox_semantics: base.Semantic(16) = .{};

test "checkbox a11y: role checkbox, named by its caption, value and checked or mixed state, in both front ends" {
    const a11y = @import("../a11y/tree.zig");
    const h = &two;
    h.init();
    const in: Input = .{ .viewport = .{ 200, 100 } };
    const x = &checkbox_semantics;
    const checked = a11y.State.bitsOf(.{ .checked = true });
    // Off, mixed (the defaults); then on, off, by setting the values in both front ends.
    const cases = [_]struct { on: bool, tri: Check }{ .{ .on = false, .tri = .mixed }, .{ .on = true, .tri = .on }, .{ .on = true, .tri = .off } };
    for (cases) |c| {
        h.app.on = c.on;
        h.app.tri = c.tri;
        h.ui.signals.set(.on, c.on);
        h.ui.signals.set(.tri, c.tri);
        _ = try h.frame(&in);
        try x.run(h);
        for ([2]u32{ 2, 6 }, [2][]const u8{ "On", "All" }, [2]Check{ Check.of(c.on), c.tri }) |node, name, v| {
            const r = x.row(node).?;
            try testing.expectEqual(@backingInt(a11y.Role.checkbox), x.out[0].c.role[r]);
            try testing.expectEqualStrings(name, x.name(0, r));
            try testing.expectEqualStrings(name, x.name(1, r));
            try testing.expectEqual(v.value(), x.out[0].c.value[r]);
            // Mixed is its own state bit, not checked.
            const want = [3]u8{ 0, checked, a11y.State.bitsOf(.{ .mixed = true }) };
            try testing.expectEqual(want[@backingInt(v)], x.out[0].c.state[r]);
        }
    }
    // The box and its dash are presentational: each checkbox exports itself and its caption.
    try testing.expectEqual(null, x.row(3));
    try testing.expectEqual(null, x.row(4));
    try testing.expectEqual(@as(u32, 5), x.out[0].len);
}

var page: Page.Run = .{};

test "Page: the checkbox replay toggles by click and Space, mixed first to on, in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &page;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = Page.replay };
    var all: [12]Check = undefined;
    var wire: [12]bool = undefined;
    var shadows: [12]bool = undefined;
    while (try replay.next(buf)) |in| {
        const k = h.frames;
        _ = try h.frame(in);
        const st = &h.ui.signals.state;
        try testing.expectEqual(h.app.all, st.all);
        try testing.expectEqual(h.app.wire, st.wire);
        try testing.expectEqual(h.app.shadows, st.shadows);
        all[k] = h.app.all;
        wire[k] = h.app.wire;
        shadows[k] = h.app.shadows;
    }
    try testing.expectEqual(@as(u32, 12), h.frames);
    try testing.expectEqualSlices(Check, &.{ .mixed, .mixed, .on, .off, .off, .off, .off, .off, .off, .off, .off, .off }, &all);
    try testing.expectEqualSlices(bool, &.{ false, false, false, false, false, true, true, true, false, false, false, false }, &wire);
    const always: [12]bool = @splat(true);
    try testing.expectEqualSlices(bool, &always, &shadows);
    // The rects the replay's comment gives.
    const t = &h.ctx.trees[h.ctx.cur];
    // Rows 17.5 px tall, 8 apart, snapped to whole pixels.
    const rows = [3][4]f32{ .{ 12, 30, 13, 29 }, .{ 38, 55, 38, 54 }, .{ 63, 81, 64, 80 } };
    for ([3][]const u8{ "all", "wire", "shadows" }, rows) |name, y| {
        const row = t.find(.hash(name));
        const r = t.rect(row);
        try testing.expectEqual([2]f32{ y[0], y[1] }, [2]f32{ r.y0, r.y1 });
        try testing.expectEqual(types.Rect{ .x0 = 12, .y0 = y[2], .x1 = 28, .y1 = y[3] }, t.rect(row + 1));
    }
    inline for (Page.golden_frames) |g| try testing.expect(g[1] < 12);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}

test "checkboxFace: restyled as spec.styled restyles ct.checkbox, in both front ends" {
    const S = struct {
        const th = Theme.default;
        const face: Style = blk: {
            var st = checkboxStyle(&th);
            st.size = .{ .px(120), .px(40) };
            st.border = 2;
            st.border_color = .rgb(200, 10, 10);
            break :blk st;
        };
        const App = struct {
            done: bool = false,
            clicks: u32 = 0,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, .{ .dir = .x });
                app.clicks += @intFromBool(checkboxFace(f, &th, .from("done"), &app.done, "Done", face).clicked);
                f.close();
            }
        };
        const Ui = base.ComptimeUi(struct { done: bool = false }, spec_zig.row(.{}, .{spec_zig.styled(ct.checkbox(th, .done, .done, "Done"), face)}), th);
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
