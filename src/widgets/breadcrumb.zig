//! Breadcrumb (tier 2): the trail of pages from the top down to the current one, each
//! earlier page a link back to it: `Home › Docs › Widgets`. The titles are application state
//! (strings), as is the link activated this frame (`activated`, a `u32`, `none` for none).
//! Written against the public API of tiers 0 and 1 (src/widgets/base.zig has the recipe).
//!
//! Runtime: `breadcrumb.trail(f, th, &ids, &titles)` returns the activated link; `ids` names
//! the links, one fewer than `titles` (the last title is the current page).
//! Comptime: `breadcrumb.ct.trail(th, .activated, .{ .{ .id, .title }, ... }, .current)`.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const TextStyle = types.TextStyle;
const Id = types.Id;
const Theme = base.Theme;
const none = types.none;
const simd = @import("../core/simd.zig");
const keys = @import("keys.zig");
const a11y = @import("../a11y/tree.zig");

// ---- spec ---------------------------------------------------------------------------------

/// A trail of links `titles[0..n-1]` (link `k` has the identity `ids[k]`), each followed by
/// a divider, then the current page `titles[n-1]`. Returns the index of the link activated
/// this frame, or `none`.
pub fn trail(f: *Frame, th: *const Theme, ids: []const Id, titles: []const []const u8) u32 {
    std.debug.assert(ids.len + 1 == titles.len);
    const nav = f.open(.none, navStyle(th));
    f.tree().c.role[nav.ix()] = role.nav;
    var clicked: u32 = none;
    var focused: u32 = none;
    for (ids, titles[0..ids.len], 0..) |id, title, k| {
        const link = f.open(id, linkStyle(th));
        const r = f.interact(link, .button);
        f.tree().c.role[link.ix()] = role.link;
        clicked = simd.selU(r.clicked, @intCast(k), clicked);
        focused = simd.selU(r.focused, @intCast(k), focused);
        f.setFill(link, linkFill(th, r));
        f.setCursor(.pointer, r.hovered);
        _ = f.textStyled(title, linkText(th), textStyle());
        f.close();
        _ = f.leaf(.none, dividerStyle(th));
    }
    _ = f.textStyled(titles[ids.len], currentText(th), textStyle());
    f.close();
    return follow(clicked, focused, f.in);
}

/// The trail: its links and dividers in a row, spaced by the theme's gap.
pub fn navStyle(th: *const Theme) Style {
    return .{ .dir = .x, .cross = .center, .gap = th.gap };
}

/// A link: its title, slightly padded and rounded so its hover fill reads as a target.
pub fn linkStyle(th: *const Theme) Style {
    return .{ .dir = .x, .cross = .center, .pad = .{ th.gap, 2, th.gap, 2 }, .radius = th.radius };
}

/// A link's fill by interaction state (`base.stateIndex`): none at rest, control-hot under
/// the pointer, control-held while pressed.
pub fn linkFill(th: *const Theme, r: types.Response) types.Color {
    const fills: base.StateColors = .{ .transparent, th.control_hot, th.control_held, th.control_held };
    return fills[base.stateIndex(r)];
}

/// A title's text node, as `Frame.text` makes it.
pub fn textStyle() Style {
    return .{ .role = .label };
}

/// A link's title: the accent colour, as links are.
pub fn linkText(th: *const Theme) TextStyle {
    return .{ .px = th.text_px, .color = th.accent };
}

/// The current page's title.
pub fn currentText(th: *const Theme) TextStyle {
    return base.labelText(th);
}

/// The mark between two titles: a small dot in the outline colour.
pub fn dividerStyle(th: *const Theme) Style {
    return .{ .size = .{ .px(4), .px(4) }, .radius = 2, .fill = th.control_hot };
}

// ---- accessibility ------------------------------------------------------------------------

/// What assistive technology sees (WAI-ARIA APG breadcrumb pattern): the trail is a
/// `navigation` landmark, each earlier page a `link` named by its title (from content), and
/// the current page static text. `types.Role` has neither navigation nor link, so both
/// front ends write the bytes. The pattern's `aria-current="page"` on the last item has no
/// bit in `a11y.State`, so it is not exported. The trail has no name of its own (a page
/// labels it, as "Breadcrumb", with `Semantics.labelled_by`), value 0 and no states.
pub const role = struct {
    pub const nav: u8 = @backingInt(a11y.Role.navigation);
    pub const link: u8 = @backingInt(a11y.Role.link);
};

// ---- behaviour ----------------------------------------------------------------------------

/// The link followed this frame (WAI-ARIA APG breadcrumb and link patterns): the one
/// clicked, else the focused one if Enter was pressed (links take Enter, not Space), else
/// `none`. `clicked` and `focused` are link indices or `none`. Each link is its own tab stop.
pub fn follow(clicked: u32, focused: u32, in: *const Input) u32 {
    var enter = false;
    for (in.events) |e| enter = enter or (e.kind == .press and e.code == keys.enter);
    return simd.selU(clicked != none, clicked, simd.selU(enter, focused, none));
}

/// The breadcrumb as a spec node.
pub const ct = struct {
    /// A trail of links `links` (a tuple of `.{ id, title }`: the link's widget name and the
    /// string field it shows) ending at the string field `current`; the link activated each
    /// frame goes to the u32 field `activated` (`none` for none). Mistakes are compile
    /// errors: a link without two parts, or fields of the wrong type.
    pub fn trail(comptime th: Theme, comptime activated: @EnumLiteral(), comptime links: anytype, comptime current: @EnumLiteral()) Spec {
        var kids: [2 * links.len + 1]Spec = undefined;
        var names: [links.len][:0]const u8 = undefined;
        var titles: [links.len + 1][]const u8 = undefined;
        for (links, 0..) |l, k| {
            if (l.len != 2) @compileError("a breadcrumb link is .{ id, title }");
            kids[2 * k] = spec_zig.row(linkStyle(&th), .{Spec{ .kind = .label, .bind = @tagName(l[1]), .style = textStyle() }});
            kids[2 * k].id = @tagName(l[0]);
            kids[2 * k + 1] = .{ .kind = .col, .style = dividerStyle(&th) };
            names[k] = @tagName(l[0]);
            titles[k] = @tagName(l[1]);
        }
        kids[2 * links.len] = .{ .kind = .label, .bind = @tagName(current), .style = textStyle() };
        titles[links.len] = @tagName(current);
        const final_names = names;
        const final_titles = titles;
        var s = spec_zig.row(navStyle(&th), kids);
        s.widget = Trail(@tagName(activated), &final_names, &final_titles);
        return s;
    }

    /// How the comptime front end builds and drives one trail.
    fn Trail(comptime activated: []const u8, comptime names: []const [:0]const u8, comptime titles: []const []const u8) type {
        return struct {
            /// The followed link from the frame's click event and `ui.focus` (`follow`).
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
                ui.signals.set(comptime U.field(activated), follow(clicked, focused, in));
            }

            pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
                const th = @TypeOf(ui.*).theme;
                const t = &ui.tables.t;
                const nav = t.push(parent, .none, &n.style);
                t.c.role[nav] = role.nav;
                next.* += 1;
                inline for (names, 0..) |name, k| {
                    var ls = n.children[2 * k].style;
                    ls.fill = linkFill(&th, ui.response(next.*, in));
                    const link = t.push(nav, .hash(name), &ls);
                    t.c.role[link] = role.link;
                    text(ui, link, titles[k], &linkText(&th));
                    t.seal(link);
                    _ = t.push(nav, .none, &n.children[2 * k + 1].style);
                    next.* += 3;
                }
                text(ui, nav, titles[names.len], &currentText(&th));
                next.* += 1;
                t.seal(nav);
            }

            /// A text node under `parent` showing the string field `field`, as `Frame.textStyled`.
            fn text(ui: anytype, parent: u32, comptime field: []const u8, ts: *const TextStyle) void {
                const t = &ui.tables.t;
                const i = t.push(parent, .none, &textStyle());
                const span = ui.tables.strings.add(@field(ui.signals.state, field));
                t.c.text[i] = ui.tables.tx.push(i, span, ts);
            }
        };
    }
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;

/// The example page: a trail Home › Docs › Widgets above a checkbox, in both front ends, in
/// theme `th`.
pub fn Page(comptime th: Theme) type {
    const column: Style = .{ .dir = .y, .pad = @splat(8), .gap = 8 };
    return struct {
        pub const ids = [_]Id{ .from("home"), .from("docs") };
        pub const App = struct {
            activated: u32 = none,
            wire: bool = false,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, column);
                app.activated = trail(f, &th, &ids, &.{ "Home", "Docs", "Widgets" });
                _ = base.checkbox(f, &th, .from("wire"), &app.wire, "Wireframe");
                f.close();
            }
        };
        pub const State = struct {
            activated: u32 = none,
            home_text: []const u8 = "Home",
            docs_text: []const u8 = "Docs",
            here: []const u8 = "Widgets",
            wire: bool = false,
            wire_text: []const u8 = "Wireframe",
        };
        pub const spec = spec_zig.col(column, .{
            ct.trail(th, .activated, .{ .{ .home, .home_text }, .{ .docs, .docs_text } }, .here),
            base.ct.checkbox(th, .wire, .wire, .wire_text),
        });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

/// Input for `Page(.default)` at 320 x 200, one commented line per frame.
pub const replay = @embedFile("testdata/breadcrumb.replay");

/// The frames of `replay` kept as golden images (tools/widgetgolden/ref/breadcrumb-<name>.png).
pub const golden_frames = .{
    .{ "rest", 0 },
    .{ "hover", 1 },
    .{ "held", 2 },
};

const Default = Page(.default);
var harness: Default.Run = .{};

/// Tree rows: root 0, column 1, nav 2, links 3 and 6 (title after each, then a divider at 5
/// and 8), current 9, checkbox 10..12.
const rows = struct {
    const nav = 2;
    const link = [2]u32{ 3, 6 };
    const divider = [2]u32{ 5, 8 };
    const current = 9;
};

test "breadcrumb: both front ends build links, dividers and the current page in a row" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(@as(u32, 13), t.len);
    for (rows.link, Default.ids) |r, id| try testing.expectEqual(r, t.find(id));
    try testing.expect(t.rect(rows.divider[0]).x0 >= t.rect(rows.link[0]).x1);
    try testing.expect(t.rect(rows.current).x0 >= t.rect(rows.divider[1]).x1);
    try testing.expectEqual(none, h.ui.signals.state.activated);
}

test "breadcrumb: links in the accent colour with a hover fill, dots between; any theme alike" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 200 } };
    var out = try h.frame(&in);
    const th = Theme.default;
    var t = out.runtime.tree;
    const tx = out.runtime.texts;
    try testing.expectEqual(th.accent.bitsOf(), tx.c.color[t.c.text[rows.link[0] + 1]]);
    try testing.expectEqual(th.text.bitsOf(), tx.c.color[t.c.text[rows.current]]);
    try testing.expectEqual(th.control_hot.bitsOf(), t.c.look[rows.divider[0]].fill);
    try testing.expectEqual(types.Color.transparent.bitsOf(), t.c.look[rows.link[0]].fill);
    try testing.expectEqual(t.rect(rows.link[0]).x1 + th.gap, t.rect(rows.divider[0]).x0);
    const r = t.rect(rows.link[1]);
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    out = try h.frame(&in);
    t = out.runtime.tree;
    try testing.expectEqual(th.control_hot.bitsOf(), t.c.look[rows.link[1]].fill);
    try testing.expectEqual(th.control_hot.bitsOf(), out.comptime_.tree.c.look[rows.link[1]].fill);

    const Light = Page(.{ .accent = .rgb(0, 90, 200), .text = .rgb(20, 20, 20), .control_hot = .rgb(180, 180, 190), .gap = 10 });
    const S = struct {
        var light: Light.Run = .{};
    };
    S.light.init();
    _ = try S.light.frame(&in);
    const lo = try S.light.frame(&in);
    try testing.expectEqual(types.Color.rgb(0, 90, 200).bitsOf(), lo.runtime.texts.c.color[lo.runtime.tree.c.text[rows.link[0] + 1]]);
}

test "follow: a click, or Enter on the focused link; Space and other keys do nothing" {
    const enter = [1]Input.Event{.{ .kind = .press, .code = keys.enter }};
    const space = [1]Input.Event{.{ .kind = .press, .code = keys.space }};
    const rep_ = [1]Input.Event{.{ .kind = .repeat, .code = keys.enter }};
    const none_in: Input = .{};
    try testing.expectEqual(@as(u32, 1), follow(1, none, &none_in));
    try testing.expectEqual(@as(u32, 0), follow(none, 0, &.{ .events = &enter }));
    try testing.expectEqual(none, follow(none, 0, &.{ .events = &space }));
    try testing.expectEqual(none, follow(none, 0, &.{ .events = &rep_ }));
    try testing.expectEqual(none, follow(none, none, &.{ .events = &enter }));
    try testing.expectEqual(none, follow(none, 1, &none_in));
}

test "breadcrumb: a click or Enter follows a link; every link is a tab stop; both front ends" {
    const focus = @import("../interact/focus.zig");
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 200 } };
    var out = try h.frame(&in);
    var t = out.runtime.tree;
    const fmask: u8 = @bitCast(types.Sense{ .focus = true });
    const first = focus.seek(t, t.c.sense, fmask, 0, t.len, none, false);
    try testing.expectEqual(rows.link[0], first);
    try testing.expectEqual(rows.link[1], focus.seek(t, t.c.sense, fmask, 0, t.len, first, false));
    // Click Docs: followed once.
    const r = t.rect(rows.link[1]);
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    try testing.expectEqual(none, h.app.activated);
    in.buttons.left = false;
    out = try h.frame(&in);
    try testing.expectEqual(@as(u32, 1), h.app.activated);
    try testing.expectEqual(@as(u32, 1), h.ui.signals.state.activated);
    _ = try h.frame(&in);
    try testing.expectEqual(none, h.app.activated);
    try testing.expectEqual(none, h.ui.signals.state.activated);
    // Docs keeps focus: Enter follows it again, Space does not.
    const space = [1]Input.Event{.{ .kind = .press, .code = keys.space }};
    in.events = &space;
    _ = try h.frame(&in);
    try testing.expectEqual(none, h.app.activated);
    try testing.expectEqual(none, h.ui.signals.state.activated);
    const enter = [1]Input.Event{.{ .kind = .press, .code = keys.enter }};
    in.events = &enter;
    out = try h.frame(&in);
    try testing.expectEqual(@as(u32, 1), h.app.activated);
    try testing.expectEqual(@as(u32, 1), h.ui.signals.state.activated);
    // The current page is not a link: clicking it follows nothing.
    in.events = &.{};
    t = out.runtime.tree;
    const c = t.rect(rows.current);
    in.pointer = .{ (c.x0 + c.x1) * 0.5, (c.y0 + c.y1) * 0.5 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    in.buttons.left = false;
    _ = try h.frame(&in);
    try testing.expectEqual(none, h.app.activated);
    try testing.expectEqual(none, h.ui.signals.state.activated);
}

test "breadcrumb: navigation holding links named by their titles, in both front ends" {
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
        try testing.expectEqual(a11y.Role.navigation, @as(a11y.Role, @fromBackingInt(t.c.role[rows.nav])));
        try testing.expectEqual(none, sem.c.name[rows.nav]);
        try testing.expectEqual(@as(f32, 0), t.c.value[rows.nav]);
        for (rows.link, [2][]const u8{ "Home", "Docs" }) |r, title| {
            try testing.expectEqual(a11y.Role.link, @as(a11y.Role, @fromBackingInt(t.c.role[r])));
            try testing.expectEqualStrings(title, check.nameOf(&sem, tx, str, r));
            try testing.expectEqual(@as(u8, 0), sem.c.state[r]);
        }
        try testing.expectEqual(a11y.Role.label, @as(a11y.Role, @fromBackingInt(t.c.role[rows.current])));
        try testing.expectEqualStrings("Widgets", check.nameOf(&sem, tx, str, rows.current));
        try testing.expectEqual(a11y.Role.none, @as(a11y.Role, @fromBackingInt(t.c.role[rows.divider[0]])));
    }
}

test "breadcrumb: the example replay gives the same frames in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var rp: Replay = .{ .src = replay };
    var activated: [8]u32 = undefined;
    var fills: [8]u32 = undefined;
    while (try rp.next(buf)) |in| {
        const k = h.frames;
        const out = try h.frame(in);
        activated[k] = h.app.activated;
        try testing.expectEqual(h.app.activated, h.ui.signals.state.activated);
        fills[k] = out.runtime.tree.c.look[rows.link[0]].fill;
    }
    try testing.expectEqual(@as(u32, 8), h.frames);
    try testing.expectEqualSlices(u32, &.{ none, none, none, 0, none, 0, none, none }, &activated);
    const th = Theme.default;
    try testing.expectEqualSlices(u32, &.{ types.Color.transparent.bitsOf(), th.control_hot.bitsOf(), th.control_held.bitsOf(), th.control_hot.bitsOf() }, fills[0..4]);
}

test "golden_frames: name frames the breadcrumb replay has" {
    inline for (golden_frames) |g| try testing.expect(g[1] < 8);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
