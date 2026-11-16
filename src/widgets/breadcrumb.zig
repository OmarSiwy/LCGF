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

// ---- spec ---------------------------------------------------------------------------------

/// A trail of links `titles[0..n-1]` (link `k` has the identity `ids[k]`), each followed by
/// a divider, then the current page `titles[n-1]`. Returns the index of the link activated
/// this frame, or `none`.
pub fn trail(f: *Frame, th: *const Theme, ids: []const Id, titles: []const []const u8) u32 {
    std.debug.assert(ids.len + 1 == titles.len);
    _ = f.open(.none, navStyle(th));
    for (ids, titles[0..ids.len]) |id, title| {
        const link = f.open(id, linkStyle(th));
        const r = f.interact(link, .button);
        f.setFill(link, linkFill(th, r));
        f.setCursor(.pointer, r.hovered);
        _ = f.textStyled(title, linkText(th), textStyle());
        f.close();
        _ = f.leaf(.none, dividerStyle(th));
    }
    _ = f.textStyled(titles[ids.len], currentText(th), textStyle());
    f.close();
    return none;
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
            /// Nothing activated yet.
            pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
                _ = row;
                _ = event;
                _ = in;
                ui.signals.set(comptime @TypeOf(ui.*).field(activated), none);
            }

            pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
                const th = @TypeOf(ui.*).theme;
                const t = &ui.tables.t;
                const nav = t.push(parent, .none, &n.style);
                next.* += 1;
                inline for (names, 0..) |name, k| {
                    var ls = n.children[2 * k].style;
                    ls.fill = linkFill(&th, ui.response(next.*, in));
                    const link = t.push(nav, .hash(name), &ls);
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

/// A trail Home › Docs › Widgets above a checkbox.
fn Page(comptime th: Theme) type {
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

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
