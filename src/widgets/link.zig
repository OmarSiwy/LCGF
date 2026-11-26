//! Link: inline text in the accent colour that reports activation, as a page link does. Tier
//! 2, written against the public API of tiers 0 and 1 (the recipe in base.zig).
//!
//! Accessibility: role link, named by its text (ARIA name from content), no value and no
//! states; the bridge reads both from the tree's `role` and `value` columns.
//!
//! State: none of its own. The text is the application's string (`str` in the runtime front
//! end, a literal or a `[]const u8` field in the comptime one, as a label's), and activation
//! is reported, not stored: `Response.clicked` in the runtime front end, the link's `Event`
//! (no payload) in the comptime one. Where it leads is the application's business.

const std = @import("std");
const base = @import("base.zig");
const keys = @import("keys.zig");
const label_zig = @import("label.zig");
const breadcrumb = @import("breadcrumb.zig");
const types = @import("../core/types.zig");
const spec_zig = @import("../comptime/spec.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Spec = spec_zig.Spec;
const Theme = base.Theme;
const Id = types.Id;
const Response = types.Response;
const Style = types.Style;
const Input = @import("../core/input.zig").Input;
const simd = @import("../core/simd.zig");

// ---- look -----------------------------------------------------------------------------------

/// The target: a breadcrumb link's padded, rounded row, role link.
pub fn linkStyle(th: *const Theme) Style {
    var s = breadcrumb.linkStyle(th);
    s.role = .link;
    return s;
}

/// The target's fill by state: none at rest, control-hot under the pointer, held pressed.
pub const linkFill = breadcrumb.linkFill;

/// The text: the theme's size in the accent colour.
pub const linkText = breadcrumb.linkText;

// ---- behaviour ------------------------------------------------------------------------------

/// Whether the link fires this frame: clicked, or focused and Enter went down (the WAI-ARIA
/// APG link pattern: links take Enter, not Space).
pub fn activated(clicked: bool, focused: bool, in: *const Input) bool {
    return simd.orB(clicked, simd.andB(focused, keys.keyCount(in, keys.enter, .press) != 0));
}

// ---- runtime front end ----------------------------------------------------------------------

/// A link named `id` showing `str`; `clicked` is set the frame it fires (`activated`).
pub fn link(f: *Frame, th: *const Theme, id: Id, str: []const u8) Response {
    const node = f.open(id, linkStyle(th));
    var r = f.interact(node, .button);
    r.clicked = activated(r.clicked, r.focused, f.in);
    f.setFill(node, linkFill(th, r));
    f.setCursor(.pointer, r.hovered);
    _ = f.textStyled(str, linkText(th), label_zig.labelStyle(th));
    f.close();
    return r;
}

// ---- comptime front end ---------------------------------------------------------------------

pub const ct = struct {
    /// A link named `id` showing `text`, a literal or a string field (as `ct.label`); its
    /// activation is its event: `ct.link(th, .docs, "Read the docs")`.
    pub fn link(comptime th: Theme, comptime id: @EnumLiteral(), comptime text: anytype) Spec {
        var s = spec_zig.row(linkStyle(&th), .{spec_zig.textStyled(label_zig.ct.label(th, text), linkText(&th))});
        s.id = @tagName(id);
        s.widget = Comptime(@tagName(id));
        return s;
    }
};

/// The comptime link named `name` (`Spec.widget`): the same rows as `link`, and Enter on it
/// while focused turned into its event, as `link` sets `clicked`.
pub fn Comptime(comptime name: [:0]const u8) type {
    return struct {
        pub const focusable = true;

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            const row = next.*;
            next.* += 1;
            var s = n.style;
            s.fill = linkFill(&@TypeOf(ui.*).theme, ui.response(row, in));
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

/// The link's example page: two links on a panel, in both front ends, counting activations.
/// Its replay (testdata/link.replay) clicks, drags off, and uses Enter and Space; its golden
/// images (tools/golden/ref/widgets/link-*.png) are the link at rest, hovered and held.
pub const Page = struct {
    const th = Theme.default;
    const panel: Style = .{ .dir = .x, .size = .{ .fill, .fill }, .pad = @splat(12), .gap = 8, .cross = .start, .fill = th.panel };

    pub const App = struct {
        docs: u32 = 0,
        home: u32 = 0,
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.from("panel"), panel);
            app.docs += @intFromBool(link(f, &th, .from("docs"), "Docs").clicked);
            app.home += @intFromBool(link(f, &th, .from("home"), "Home").clicked);
            f.close();
        }
    };
    pub const State = struct { home_text: []const u8 = "Home" };
    pub const spec = spec_zig.row(panel, .{ ct.link(th, .docs, "Docs"), ct.link(th, .home, .home_text) });
    pub const Ui = base.ComptimeUi(State, spec, th);
    pub const Run = base.Harness(App, Ui, .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256, .depth = 8 });
    pub const replay = @embedFile("testdata/link.replay");
    /// Frames kept as golden images, by name: tools/golden/ref/widgets/link-<name>.png.
    pub const golden_frames = .{ .{ "rest", 0 }, .{ "hover", 1 }, .{ "held", 2 } };
};

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "ct.link: a named focusable widget with a void event, its text a label in the accent" {
    const s = comptime ct.link(.default, .go, "Go");
    try testing.expectEqual(spec_zig.Kind.row, s.kind);
    try testing.expectEqualStrings("go", s.id.?);
    try testing.expectEqual(types.Role.link, s.style.role);
    try testing.expectEqualStrings("Go", s.children[0].text.?);
    try testing.expectEqual(Theme.default.accent, s.children[0].text_style.?.color);
    const E = @import("../comptime/events.zig").Events(s);
    try testing.expectEqual(void, @FieldType(E.Event, "go"));
    try testing.expectEqualSlices(E.Widget, &.{.go}, E.focus_order);
}

test "activated: a click, or Enter down while focused; never Space" {
    const none: Input = .{};
    try testing.expect(activated(true, false, &none));
    try testing.expect(!activated(false, true, &none));
    const enter: Input = .{ .events = &.{.{ .kind = .press, .code = keys.enter }} };
    try testing.expect(activated(false, true, &enter));
    try testing.expect(!activated(false, false, &enter));
    const space: Input = .{ .events = &.{ .{ .kind = .press, .code = keys.space }, .{ .kind = .release, .code = keys.space } } };
    try testing.expect(!activated(false, true, &space));
}

var page: Page.Run = .{};

test "Page: the link replay fires on click and Enter, not Space, in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &page;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = Page.replay };
    const Fired = enum { none, docs, home };
    var fired: [12]Fired = undefined;
    var fills: [12]u32 = undefined;
    while (try replay.next(buf)) |in| {
        const k = h.frames;
        const before = .{ h.app.docs, h.app.home };
        const out = try h.frame(in);
        const rt: Fired = if (h.app.docs != before[0]) .docs else if (h.app.home != before[1]) .home else .none;
        const cp: Fired = if (out.comptime_.event) |e| switch (e) {
            .docs => .docs,
            .home => .home,
        } else .none;
        try testing.expectEqual(rt, cp);
        fired[k] = rt;
        fills[k] = out.runtime.tree.c.look[2].fill;
    }
    try testing.expectEqual(@as(u32, 12), h.frames);
    try testing.expectEqualSlices(Fired, &.{ .none, .none, .none, .docs, .docs, .none, .none, .none, .none, .none, .home, .none }, &fired);
    const th = Theme.default;
    try testing.expectEqualSlices(u32, &.{ types.Color.transparent.bitsOf(), th.control_hot.bitsOf(), th.control_held.bitsOf(), th.control_hot.bitsOf() }, fills[0..4]);
    // The rects the replay's comment gives.
    const t = &h.ctx.trees[h.ctx.cur];
    try testing.expectEqual(types.Rect{ .x0 = 12, .y0 = 12, .x1 = 58, .y1 = 34 }, t.rect(t.find(.from("docs"))));
    try testing.expectEqual(types.Rect{ .x0 = 66, .y0 = 12, .x1 = 111, .y1 = 34 }, t.rect(t.find(.from("home"))));
    inline for (Page.golden_frames) |g| try testing.expect(g[1] < 12);
}

var semantics: base.Semantic(16) = .{};

test "link a11y: role link, named by its text, value 0, no states, in both front ends" {
    const a11y = @import("../a11y/tree.zig");
    const h = &page;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 80 } };
    _ = try h.frame(&in);
    in.pointer = .{ 30, 25 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    const x = &semantics;
    try x.run(h);
    const r = x.row(2).?;
    try testing.expectEqual(@backingInt(a11y.Role.link), x.out[0].c.role[r]);
    try testing.expectEqual(@backingInt(Id.from("docs")), x.out[0].c.id[r]);
    try testing.expectEqualStrings("Docs", x.name(0, r));
    try testing.expectEqualStrings("Docs", x.name(1, r));
    try testing.expectEqual(@as(f32, 0), x.out[0].c.value[r]);
    try testing.expectEqual(@as(u8, 0), x.out[0].c.state[r]);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(ct);
}
