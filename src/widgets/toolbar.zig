//! Toolbar (tier 2): a row of buttons that is one stop in the tab order. Which button holds
//! that stop is application state (`current`, a `u32`), as is the button activated this
//! frame (`activated`, a `u32`, `none` for none). Written against the public API of tiers 0
//! and 1 (src/widgets/base.zig has the recipe).
//!
//! Runtime: `toolbar.bar(f, th, &ids, &titles, &current)` returns the activated button.
//! Comptime: `toolbar.ct.toolbar(th, .current, .activated, .{ .{ .id, .title }, ... })`.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const Id = types.Id;
const Theme = base.Theme;
const none = types.none;
const simd = @import("../core/simd.zig");
const keys = @import("keys.zig");
const a11y = @import("../a11y/tree.zig");

// ---- spec ---------------------------------------------------------------------------------

/// A toolbar of one button per title: button `k` has the identity `ids[k]` and shows
/// `titles[k]`. Input moves `current.*` (the button that is the toolbar's tab stop) and
/// keyboard focus first (`rove`); it is clamped into range. Returns the index of the button
/// activated this frame, or `none`.
pub fn bar(f: *Frame, th: *const Theme, ids: []const Id, titles: []const []const u8, current: *u32) u32 {
    return barFace(f, th, ids, titles, current, barStyle(th), base.labelText(th));
}

/// `bar` laid out by `face` instead of `barStyle(th)`, its buttons' titles drawn in `text`; the
/// buttons' fill still follows their state.
pub fn barFace(f: *Frame, th: *const Theme, ids: []const Id, titles: []const []const u8, current: *u32, face: Style, text: types.TextStyle) u32 {
    std.debug.assert(ids.len == titles.len and ids.len > 0);
    var clicked: u32 = none;
    var focused: u32 = none;
    for (ids, 0..) |id, k| {
        const r = f.ctx.inter.response(id);
        clicked = simd.selU(r.clicked, @intCast(k), clicked);
        focused = simd.selU(r.focused, @intCast(k), focused);
    }
    const m = rove(current.*, @intCast(ids.len), clicked, focused, f.in);
    current.* = m.current;
    if (m.focus != none) f.ctx.inter.focus = @backingInt(ids[m.focus]);
    const row = f.open(.none, face);
    f.tree().c.role[row.ix()] = role;
    for (ids, titles, 0..) |id, title, k| {
        const item = f.open(id, itemStyle(th));
        const r = f.interact(item, sense(k == current.*));
        f.setFill(item, base.buttonFill(th, r));
        f.setCursor(.pointer, r.hovered);
        _ = f.text(title, text);
        f.close();
    }
    f.close();
    return m.activated;
}

/// The bar: its buttons side by side on the panel colour, padded and spaced by the theme,
/// as the reference page's toolbar.
pub fn barStyle(th: *const Theme) Style {
    return .{ .dir = .x, .pad = @splat(th.pad), .gap = th.gap, .cross = .center, .fill = th.panel, .radius = th.radius };
}

/// One button, as `base.buttonStyle`; filled as a button by interaction state
/// (`base.buttonFill`).
pub fn itemStyle(th: *const Theme) Style {
    return base.buttonStyle(th);
}

// ---- accessibility ------------------------------------------------------------------------

/// What assistive technology sees (WAI-ARIA APG toolbar pattern): the bar is a `toolbar`
/// holding `button`s named by their titles (from content). `types.Role` has no toolbar, so
/// both front ends write the byte. The bar has no value or states, and no name of its own:
/// a page labels it with `Semantics.labelled_by` where it has one.
pub const role: u8 = @backingInt(a11y.Role.toolbar);

// ---- behaviour ----------------------------------------------------------------------------

/// Only the current button senses focus, so the toolbar is one stop in the tab order (and
/// in `focus.seek`); the others still sense the pointer.
pub fn sense(is_current: bool) types.Sense {
    const senses = [2]types.Sense{ .{ .hover = true, .click = true }, .button };
    return senses[@intFromBool(is_current)];
}

/// Where the tab stop, focus and activation go: button indices, `none` for none.
pub const Move = struct { current: u32, focus: u32, activated: u32 };

/// The next state of a toolbar of `count` buttons (WAI-ARIA APG toolbar pattern, roving
/// tab stop). A click on button `clicked` activates it, focuses it and makes it the tab
/// stop. While button `focused` has focus, Right and Left move focus to the next and
/// previous button (wrapping), Home and End to the first and last, and the tab stop follows;
/// Enter and Space activate the focused button. `clicked` and `focused` are `none` when no
/// button was clicked or has focus; then keys do nothing.
pub fn rove(current: u32, count: u32, clicked: u32, focused: u32, in: *const Input) Move {
    const last = count - 1;
    const click = clicked != none;
    var cur = @min(simd.selU(click, clicked, current), last);
    var foc = simd.selU(click, clicked, focused);
    var act = clicked;
    if (foc == none) return .{ .current = cur, .focus = none, .activated = act };
    for (in.events) |e| {
        if (e.kind != .press and e.kind != .repeat) continue;
        const k = keys.map;
        const to = if (e.code == k.right) (foc + 1) % count else if (e.code == k.left) (foc + last) % count else if (e.code == k.home) 0 else if (e.code == k.end) last else none;
        foc = simd.selU(to != none, to, foc);
        cur = foc;
        act = simd.selU(e.kind == .press and (e.code == keys.enter or e.code == keys.space), foc, act);
    }
    return .{ .current = cur, .focus = foc, .activated = act };
}

/// The toolbar as a spec node.
pub const ct = struct {
    /// A toolbar whose tab stop is the u32 field `current` and which writes the button it
    /// activates each frame to the u32 field `activated` (`none` for none). `items` is a
    /// tuple of `.{ id, title }`: the button's widget name and the string field it shows.
    /// Mistakes are compile errors: no items, an item without two parts, or fields of the
    /// wrong type.
    pub fn toolbar(comptime th: Theme, comptime current: @EnumLiteral(), comptime activated: @EnumLiteral(), comptime items: anytype) Spec {
        if (items.len == 0) @compileError("toolbar over '" ++ @tagName(current) ++ "' has no buttons");
        var kids: [items.len]Spec = undefined;
        var names: [items.len][:0]const u8 = undefined;
        for (items, &kids, &names) |it, *k, *name| {
            if (it.len != 2) @compileError("a toolbar button is .{ id, title }");
            k.* = spec_zig.row(itemStyle(&th), .{base.ct.label(th, it[1])});
            k.id = @tagName(it[0]);
            name.* = @tagName(it[0]);
        }
        const final_names = names;
        var s = spec_zig.row(barStyle(&th), kids);
        s.widget = Toolbar(@tagName(current), @tagName(activated), &final_names);
        return s;
    }

    /// How the comptime front end builds and drives one toolbar.
    fn Toolbar(comptime current: []const u8, comptime activated: []const u8, comptime names: []const [:0]const u8) type {
        return struct {
            /// The tab stop, focus and activation from the frame's click event and
            /// `ui.focus` (`rove`).
            pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
                _ = row;
                const U = @TypeOf(ui.*);
                var clicked: u32 = none;
                var focused: u32 = none;
                inline for (names, 0..) |name, k| {
                    const me = @field(U.Events.Widget, name);
                    if (event) |e| clicked = simd.selU(std.meta.activeTag(e) == me, k, clicked);
                    focused = simd.selU(ui.focus == me, k, focused);
                }
                const m = rove(@field(ui.signals.state, current), names.len, clicked, focused, in);
                ui.signals.set(comptime U.field(current), m.current);
                ui.signals.set(comptime U.field(activated), m.activated);
                inline for (names, 0..) |name, k| {
                    if (m.focus == k) ui.focus = @field(U.Events.Widget, name);
                }
            }

            pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
                const t = &ui.tables.t;
                const row = t.push(parent, .none, &n.style);
                t.c.role[row] = role;
                next.* += 1;
                const th = @TypeOf(ui.*).theme;
                inline for (n.children, names) |item, name| {
                    var st = item.style;
                    st.fill = base.buttonFill(&th, ui.response(next.*, in));
                    const i = t.push(row, .hash(name), &st);
                    next.* += 1;
                    ui.push(item.children[0], i, next, in);
                    t.seal(i);
                }
                t.seal(row);
            }
        };
    }
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;

/// The example page: a toolbar of Bold, Italic and Underline above a checkbox, in both front
/// ends, in theme `th`.
pub fn Page(comptime th: Theme) type {
    const column: Style = .{ .dir = .y, .pad = @splat(8), .gap = 8 };
    return struct {
        pub const ids = [_]Id{ .from("bold"), .from("italic"), .from("under") };
        pub const App = struct {
            current: u32 = 0,
            activated: u32 = none,
            wire: bool = false,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, column);
                app.activated = bar(f, &th, &ids, &.{ "Bold", "Italic", "Underline" }, &app.current);
                _ = base.checkbox(f, &th, .from("wire"), &app.wire, "Wireframe");
                f.close();
            }
        };
        pub const State = struct {
            current: u32 = 0,
            activated: u32 = none,
            bold_text: []const u8 = "Bold",
            italic_text: []const u8 = "Italic",
            under_text: []const u8 = "Underline",
            wire: bool = false,
            wire_text: []const u8 = "Wireframe",
        };
        pub const spec = spec_zig.col(column, .{
            ct.toolbar(th, .current, .activated, .{ .{ .bold, .bold_text }, .{ .italic, .italic_text }, .{ .under, .under_text } }),
            base.ct.checkbox(th, .wire, .wire, .wire_text),
        });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

/// Input for `Page(.default)` at 320 x 200, one commented line per frame.
pub const replay = @embedFile("testdata/toolbar.replay");

/// The frames of `replay` kept as golden images (tools/golden/ref/widgets/toolbar-<name>.png).
pub const golden_frames = .{
    .{ "rest", 0 },
    .{ "hover", 1 },
    .{ "roved", 4 },
};

const Default = Page(.default);
var harness: Default.Run = .{};

/// Tree rows: root 0, column 1, bar 2, buttons 3/5/7 (labels after each), checkbox 9..11.
const rows = struct {
    const bar = 2;
    const item = [3]u32{ 3, 5, 7 };
};

test "barFace: the theme's styles draw as bar" {
    const S = struct {
        const ids = [_]Id{ .from("cut"), .from("copy") };
        const titles = [_][]const u8{ "Cut", "Copy" };
        var current: [2]u32 = .{ 0, 0 };
        fn build(f: *Frame, k: u1) void {
            const th: *const Theme = &.default;
            _ = if (k == 0) bar(f, th, &ids, &titles, &current[k]) else barFace(f, th, &ids, &titles, &current[k], barStyle(th), base.labelText(th));
        }
    };
    try base.expectSameFace(.{ .nodes = 16, .texts = 4, .customs = 1, .strings = 64, .depth = 8 }, S.build, .{ 70, 20 });
    try testing.expectEqual(S.current[0], S.current[1]);
}

test "toolbar: both front ends build one row of buttons" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(@as(u32, 12), t.len);
    for (rows.item, Default.ids) |r, id| try testing.expectEqual(r, t.find(id));
    try testing.expect(t.rect(rows.item[1]).x0 >= t.rect(rows.item[0]).x1);
    try testing.expectEqual(none, h.app.activated);
    try testing.expectEqual(none, h.ui.signals.state.activated);
}

test "toolbar: buttons on a panel bar, filled by state; any theme alike" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 200 } };
    var out = try h.frame(&in);
    const th = Theme.default;
    var t = out.runtime.tree;
    try testing.expectEqual(th.panel.bitsOf(), t.c.look[rows.bar].fill);
    try testing.expectEqual(t.rect(rows.bar).x0 + th.pad, t.rect(rows.item[0]).x0);
    try testing.expectEqual(t.rect(rows.item[0]).x1 + th.gap, t.rect(rows.item[1]).x0);
    const r = t.rect(rows.item[2]);
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    out = try h.frame(&in);
    t = out.runtime.tree;
    try testing.expectEqual(th.control_hot.bitsOf(), t.c.look[rows.item[2]].fill);
    try testing.expectEqual(th.control_hot.bitsOf(), out.comptime_.tree.c.look[rows.item[2]].fill);
    try testing.expectEqual(th.control.bitsOf(), t.c.look[rows.item[0]].fill);

    const Light = Page(.{ .panel = .rgb(240, 240, 240), .control = .rgb(200, 200, 205), .control_hot = .rgb(180, 180, 190), .text = .rgb(20, 20, 20), .pad = 12, .gap = 10, .radius = 0 });
    const S = struct {
        var light: Light.Run = .{};
    };
    S.light.init();
    _ = try S.light.frame(&in);
    const lo = try S.light.frame(&in);
    try testing.expectEqual(types.Color.rgb(180, 180, 190).bitsOf(), lo.runtime.tree.c.look[rows.item[2]].fill);
}

test "rove: click activates and moves the stop; arrows move focus and stop; Enter activates" {
    const k = keys.map;
    const ev = struct {
        fn of(comptime codes: []const u8) Input {
            const list = comptime blk: {
                var l: [codes.len]Input.Event = undefined;
                for (&l, codes) |*e, c| e.* = .{ .kind = .press, .code = c };
                break :blk l;
            };
            return .{ .events = &list };
        }
    };
    const none_in: Input = .{};
    try testing.expectEqual(Move{ .current = 2, .focus = 2, .activated = 2 }, rove(0, 3, 2, none, &none_in));
    try testing.expectEqual(Move{ .current = 0, .focus = none, .activated = none }, rove(0, 3, none, none, &ev.of(&.{k.right})));
    try testing.expectEqual(Move{ .current = 1, .focus = 1, .activated = none }, rove(0, 3, none, 0, &ev.of(&.{k.right})));
    try testing.expectEqual(Move{ .current = 2, .focus = 2, .activated = none }, rove(0, 3, none, 0, &ev.of(&.{k.left})));
    try testing.expectEqual(Move{ .current = 2, .focus = 2, .activated = 2 }, rove(0, 3, none, 0, &ev.of(&.{ k.end, keys.space })));
    try testing.expectEqual(Move{ .current = 0, .focus = 0, .activated = 0 }, rove(1, 3, none, 1, &ev.of(&.{ k.home, keys.enter })));
    try testing.expectEqual(types.Sense.button, sense(true));
    try testing.expect(!sense(false).focus);
}

test "toolbar: one tab stop; click and Enter activate; arrows rove; in both front ends" {
    const focus = @import("../interact/focus.zig");
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 200 } };
    var out = try h.frame(&in);
    // Tab stops: the current button and the checkbox, nothing else.
    const fmask: u8 = @bitCast(types.Sense{ .focus = true });
    var t = out.runtime.tree;
    const first = focus.seek(t, t.c.sense, fmask, 0, t.len, none, false);
    try testing.expectEqual(rows.item[0], first);
    try testing.expectEqual(t.find(.from("wire")), focus.seek(t, t.c.sense, fmask, 0, t.len, first, false));
    // Click Underline: activated once, focused, the new stop.
    const r = t.rect(rows.item[2]);
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    in.buttons.left = false;
    out = try h.frame(&in);
    try testing.expectEqual(@as(u32, 2), h.app.activated);
    try testing.expectEqual(@as(u32, 2), h.ui.signals.state.activated);
    try testing.expectEqual(@as(u32, 2), h.app.current);
    try testing.expectEqual(@as(u32, 2), h.ui.signals.state.current);
    out = try h.frame(&in);
    try testing.expectEqual(none, h.app.activated);
    try testing.expectEqual(none, h.ui.signals.state.activated);
    t = out.runtime.tree;
    try testing.expectEqual(rows.item[2], focus.seek(t, t.c.sense, fmask, 0, t.len, none, false));
    // Right wraps to Bold; Enter activates it.
    const steps = [_]struct { code: u8, cur: u32, act: u32 }{
        .{ .code = keys.map.right, .cur = 0, .act = none },
        .{ .code = keys.enter, .cur = 0, .act = 0 },
        .{ .code = keys.map.end, .cur = 2, .act = none },
        .{ .code = keys.map.left, .cur = 1, .act = none },
    };
    for (steps) |st| {
        const e = [1]Input.Event{.{ .kind = .press, .code = st.code }};
        in.events = &e;
        _ = try h.frame(&in);
        try testing.expectEqual(st.cur, h.app.current);
        try testing.expectEqual(st.cur, h.ui.signals.state.current);
        try testing.expectEqual(st.act, h.app.activated);
        try testing.expectEqual(st.act, h.ui.signals.state.activated);
        try testing.expectEqual(@backingInt(Default.ids[st.cur]), h.ctx.inter.focus);
    }
}

test "toolbar: role toolbar holding buttons named by their titles, in both front ends" {
    const check = @import("check.zig");
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    var sb: check.SemBuf = undefined;
    const trees = [2]*const @import("../core/tree.zig").Tree{ out.runtime.tree, out.comptime_.tree };
    const texts = [2]*const @import("../core/texts.zig").Texts{ out.runtime.texts, &h.ui.tables.tx };
    const strings = [2][]const u8{ h.ctx.strings[h.ctx.cur].buf, h.ui.tables.strings.buf };
    for (trees, texts, strings) |t, tx, str| {
        var sem = sb.init();
        a11y.names(t, &sem);
        a11y.states(t, &sem);
        try testing.expectEqual(a11y.Role.toolbar, @as(a11y.Role, @fromBackingInt(t.c.role[rows.bar])));
        try testing.expectEqual(@as(f32, 0), t.c.value[rows.bar]);
        try testing.expectEqual(none, sem.c.name[rows.bar]);
        for (rows.item, [3][]const u8{ "Bold", "Italic", "Underline" }) |r, title| {
            try testing.expectEqual(a11y.Role.button, @as(a11y.Role, @fromBackingInt(t.c.role[r])));
            try testing.expectEqualStrings(title, check.nameOf(&sem, tx, str, r));
            try testing.expectEqual(@as(u8, 0), sem.c.state[r]);
        }
    }
}

test "toolbar: the example replay gives the same frames in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var rp: Replay = .{ .src = replay };
    var current: [8]u32 = undefined;
    var activated: [8]u32 = undefined;
    while (try rp.next(buf)) |in| {
        const k = h.frames;
        _ = try h.frame(in);
        current[k] = h.app.current;
        activated[k] = h.app.activated;
        try testing.expectEqual(h.app.current, h.ui.signals.state.current);
        try testing.expectEqual(h.app.activated, h.ui.signals.state.activated);
    }
    try testing.expectEqual(@as(u32, 8), h.frames);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 1, 2, 2, 0, 2 }, &current);
    try testing.expectEqualSlices(u32, &.{ none, none, none, 1, none, 2, none, none }, &activated);
}

test "golden_frames: name frames the toolbar replay has" {
    inline for (golden_frames) |g| try testing.expect(g[1] < 8);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
