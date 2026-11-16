//! Card and group box (tier 2): a container that frames the widgets inside it under a title.
//! A card is a filled panel; a group box is an outlined frame with a caption. Both are one
//! node with the title as its first child, then the caller's children. Written against the
//! public API of tiers 0 and 1 (src/widgets/base.zig has the recipe).
//!
//! Runtime: `card.open(f, th, .card, "Render")`, the children, then `f.close()`.
//! Comptime: `card.ct.card(th, .card, .title, .{ ...children })`, `title` a string field of
//! the state struct.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const Node = types.Node;
const Theme = base.Theme;
const a11y = @import("../a11y/tree.zig");

/// Which frame the container draws.
pub const Variant = enum(u1) { card, group_box };

// ---- spec ---------------------------------------------------------------------------------

/// Starts a card or group box titled `title` and returns its node. Everything built until the
/// matching `f.close()` is inside it, below the title.
pub fn open(f: *Frame, th: *const Theme, variant: Variant, title: []const u8) Node {
    const n = f.open(.none, style(th, variant));
    _ = base.label(f, th, title);
    return n;
}

/// The node of a card or group box: a column, padded, its children spaced by the theme's gap.
/// A card is filled with the panel colour; a group box is outlined in the control-hot colour
/// and left unfilled. Both round their corners by the theme's radius. The variant picks its
/// colours and border width by table index.
pub fn style(th: *const Theme, variant: Variant) Style {
    const k = @backingInt(variant);
    const fills = [2]types.Color{ th.panel, .transparent };
    const borders = [2]types.Color{ .transparent, th.control_hot };
    const widths = [2]f32{ 0, 1 };
    return .{ .dir = .y, .role = .group, .pad = @splat(th.pad), .gap = th.gap, .radius = th.radius, .fill = fills[k], .border_color = borders[k], .border = widths[k] };
}

// ---- accessibility ------------------------------------------------------------------------

/// Names the container at tree row `row` by its title, the row after it (`aria-labelledby`),
/// in the caller's semantic columns: a `group` does not take its name from its content. Its
/// role is `group` (the style's), its value 0, and it has no states of its own; `a11y.states`
/// passes a disabled state down from it to its children. Call after the frame is built, for
/// either front end: their rows are the same.
pub fn name(s: *a11y.Semantics, row: u32) void {
    s.c.labelled_by[row] = row + 1;
}

/// The containers as spec nodes.
pub const ct = struct {
    /// A card or group box titled by the string field `title`, holding `children` (a tuple of
    /// specs). It takes no input, so it has no id. Mistakes are compile errors: an empty
    /// `children`, or a `title` that is not a string field of the state struct (`ComptimeUi`).
    pub fn card(comptime th: Theme, comptime variant: Variant, comptime title: @EnumLiteral(), comptime children: anytype) Spec {
        if (children.len == 0) @compileError("card '" ++ @tagName(title) ++ "' holds nothing; give it at least one child");
        return spec_zig.col(style(&th, variant), .{base.ct.label(th, title)} ++ children);
    }
};

// ---- example page -------------------------------------------------------------------------

const context = @import("../runtime/context.zig");
const Input = @import("../core/input.zig").Input;

/// The example page: a card titled "Render" holding a button and a group box "Options" with a
/// checkbox, in both front ends, in theme `th`.
pub fn Page(comptime th: Theme) type {
    return struct {
        pub const App = struct {
            wire: bool = false,
            pub fn build(app: *App, f: *Frame) void {
                _ = open(f, &th, .card, "Render");
                _ = base.button(f, &th, .from("go"), "Go");
                _ = open(f, &th, .group_box, "Options");
                _ = base.checkbox(f, &th, .from("wire"), &app.wire, "Wireframe");
                f.close();
                f.close();
            }
        };
        pub const State = struct {
            title: []const u8 = "Render",
            go_text: []const u8 = "Go",
            options: []const u8 = "Options",
            wire: bool = false,
            wire_text: []const u8 = "Wireframe",
        };
        pub const spec = ct.card(th, .card, .title, .{
            base.ct.button(th, .go, .go_text),
            ct.card(th, .group_box, .options, .{base.ct.checkbox(th, .wire, .wire, .wire_text)}),
        });
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 });
    };
}

/// Input for `Page(.default)` at 320 x 200, one commented line per frame.
pub const replay = @embedFile("testdata/card.replay");

/// The frames of `replay` kept as golden images (tools/widgetgolden/ref/card-<name>.png).
pub const golden_frames = .{
    .{ "rest", 0 },
    .{ "checked", 7 },
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;
const Tree = @import("../core/tree.zig").Tree;
const hit = @import("../interact/hit.zig");
const focus = @import("../interact/focus.zig");
const check = @import("check.zig");

const Default = Page(.default);
var harness: Default.Run = .{};

test "card: both front ends build the same rows: the container, its title, then its children" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 400, 300 } };
    const out = try h.frame(&in);
    const t = out.runtime.tree;
    // root, card, title, button, its label, group box, caption, checkbox, its box and caption
    try testing.expectEqual(@as(u32, 10), t.len);
    const card_row: u32 = 1;
    const group_row: u32 = 5;
    try testing.expectEqual(card_row, t.c.parent[card_row + 1]);
    try testing.expectEqual(card_row, t.c.parent[group_row]);
    try testing.expectEqual(group_row, t.c.parent[group_row + 1]);
    // The title is the container's first child, padded in by the theme's pad.
    const r = t.rect(card_row);
    const title = t.rect(card_row + 1);
    try testing.expectEqual(r.x0 + Theme.default.pad, title.x0);
    try testing.expectEqual(r.y0 + Theme.default.pad, title.y0);
}

test "card: the variant picks fill and outline from the theme" {
    const th = Theme.default;
    const c = style(&th, .card);
    const g = style(&th, .group_box);
    try testing.expectEqual(th.panel, c.fill);
    try testing.expectEqual(@as(f32, 0), c.border);
    try testing.expectEqual(types.Color.transparent, g.fill);
    try testing.expectEqual(th.control_hot, g.border_color);
    try testing.expectEqual(@as(f32, 1), g.border);
    try testing.expectEqual(th.radius, c.radius);
    try testing.expectEqual(th.radius, g.radius);
    // Painted as styled in both front ends: the card's quad carries the panel colour.
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 400, 300 } };
    const out = try h.frame(&in);
    try testing.expectEqual(th.panel.bitsOf(), out.runtime.tree.c.look[1].fill);
    try testing.expectEqual(th.control_hot.bitsOf(), out.comptime_.tree.c.look[5].border_color);
}

test "card: other theme tokens restyle both front ends alike" {
    const Light = Page(.{ .panel = .rgb(240, 240, 240), .control_hot = .rgb(120, 120, 130), .radius = 0, .pad = 12, .gap = 10, .text = .rgb(20, 20, 20) });
    const S = struct {
        var h: Light.Run = .{};
    };
    S.h.init();
    const in: Input = .{ .viewport = .{ 400, 300 } };
    const out = try S.h.frame(&in);
    const t = out.runtime.tree;
    try testing.expectEqual(t.rect(1).x0 + 12, t.rect(2).x0);
}

test "card: takes no input; hit testing and the tab order pass through it to its children" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 400, 300 } };
    var out = try h.frame(&in);
    // Click in the card's padding, then on its title: nothing is pressed, nothing focused.
    const t0 = out.runtime.tree;
    in.pointer = .{ t0.rect(1).x0 + 2, t0.rect(1).y0 + 2 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    // Held over the card: neither front end has anything held.
    try testing.expectEqual(@as(u32, 0), h.ctx.inter.active);
    try testing.expectEqual(@as(?Default.Ui.Events.Widget, null), h.ui.pointer.pressed);
    in.buttons.left = false;
    out = try h.frame(&in);
    try testing.expectEqual(@as(u32, 0), h.ctx.inter.focus);
    const t = out.runtime.tree;
    try check.expectInert(t, &.{ 1, 2, 5, 6 });
    // The widgets inside still take input and focus: the button and the checkbox.
    try testing.expectEqual(t.find(.from("go")), hit.at(t, (t.rect(3).x0 + t.rect(3).x1) * 0.5, (t.rect(3).y0 + t.rect(3).y1) * 0.5, .any));
    const focusable: u8 = @bitCast(types.Sense{ .focus = true });
    const first = focus.seek(t, t.c.sense, focusable, 0, t.len, types.none, false);
    try testing.expectEqual(t.find(.from("go")), first);
    try testing.expectEqual(t.find(.from("wire")), focus.seek(t, t.c.sense, focusable, 0, t.len, first, false));
    // In the comptime front end the containers are not widgets at all.
    try testing.expectEqual(2, Default.Ui.Events.widget_count);
}

test "card: role group, named by its title, value 0, no states, in both front ends" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 400, 300 } };
    const out = try h.frame(&in);
    var sb: [2]check.SemBuf = undefined;
    const trees = [2]*const Tree{ out.runtime.tree, out.comptime_.tree };
    const texts = [2]*const @import("../core/texts.zig").Texts{ out.runtime.texts, &h.ui.tables.tx };
    const strings = [2][]const u8{ h.ctx.strings[h.ctx.cur].buf, h.ui.tables.strings.buf };
    for (trees, texts, strings, &sb) |t, tx, str, *b| {
        var sem = b.init();
        name(&sem, 1);
        name(&sem, 5);
        a11y.names(t, &sem);
        a11y.states(t, &sem);
        try testing.expectEqual(@backingInt(a11y.Role.group), t.c.role[1]);
        try testing.expectEqual(@backingInt(a11y.Role.group), t.c.role[5]);
        try testing.expectEqualStrings("Render", check.nameOf(&sem, tx, str, 1));
        try testing.expectEqualStrings("Options", check.nameOf(&sem, tx, str, 5));
        try testing.expectEqual(@as(f32, 0), t.c.value[1]);
        try testing.expectEqual(@as(u8, 0), sem.c.state[1]);
        try testing.expectEqual(@as(u8, 0), sem.c.state[5]);
    }
    // Disabled passes from the card to what it holds.
    var sem = sb[0].init();
    sem.c.state[1] = a11y.State.bitsOf(.{ .disabled = true });
    a11y.states(out.runtime.tree, &sem);
    try testing.expectEqual(sem.c.state[1], sem.c.state[out.runtime.tree.find(.from("go"))]);
}

test "card: the example replay gives the same frames in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var rp: Replay = .{ .src = replay };
    var clicks: [8]bool = undefined;
    var wire: [8]bool = undefined;
    var fills: [8]u32 = undefined;
    while (try rp.next(buf)) |in| {
        const k = h.frames;
        const out = try h.frame(in);
        const t = out.runtime.tree;
        clicks[k] = if (out.comptime_.event) |e| e == .go else false;
        wire[k] = h.ui.signals.state.wire;
        try testing.expectEqual(h.app.wire, wire[k]);
        fills[k] = t.c.look[t.find(.from("go"))].fill;
        // The card keeps its look whatever the pointer does.
        try testing.expectEqual(Theme.default.panel.bitsOf(), t.c.look[1].fill);
    }
    try testing.expectEqual(@as(u32, 8), h.frames);
    try testing.expectEqualSlices(bool, &.{ false, false, false, true, false, false, false, false }, &clicks);
    try testing.expectEqualSlices(bool, &.{ false, false, false, false, false, false, false, true }, &wire);
    const c = Theme.default.controlFills();
    try testing.expectEqualSlices(u32, &.{ c[0].bitsOf(), c[1].bitsOf(), c[3].bitsOf(), c[1].bitsOf(), c[0].bitsOf() }, fills[0..5]);
}

test "golden_frames: name frames the card replay has" {
    inline for (golden_frames) |g| try testing.expect(g[1] < 8);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
