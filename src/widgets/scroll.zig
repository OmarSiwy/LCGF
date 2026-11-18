//! Scroll area (tier 2): a viewport that clips its content and shows the part at a vertical
//! offset. The offset is application state: an `f32`, in logical pixels from the top. Written
//! against the public API of tiers 0 and 1 (src/widgets/base.zig has the recipe).
//!
//! Runtime: `scroll.open(f, th, id, &offset)`, the content, `scroll.close(f, th, id, offset)`.
//! Comptime: `scroll.ct.scroll(th, .id, .offset, .{...content})`.
//!
//! How far it can scroll depends on how tall the content is, which is known once it is laid
//! out: both front ends measure last frame's viewport and content, as immediate-mode scroll
//! areas do. The runtime reads them with `Frame.lastRect` (the viewport is `id`, the content
//! `id.with(1)`); the comptime front end reads last frame's tree in `step`.

const std = @import("std");
const base = @import("base.zig");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Input = @import("../core/input.zig").Input;
const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Style = types.Style;
const Id = types.Id;
const Rect = types.Rect;
const Theme = base.Theme;
const simd = @import("../core/simd.zig");
const keys = @import("keys.zig");
const a11y = @import("../a11y/tree.zig");

// ---- spec ---------------------------------------------------------------------------------

/// What last frame's layout says about a scroll area: how tall its viewport and its content
/// were. Zero before the first frame.
pub const Geometry = struct {
    view: f32 = 0,
    content: f32 = 0,

    /// From last frame's viewport and content rects.
    pub fn of(viewport: Rect, content: Rect) Geometry {
        return .{ .view = viewport.h(), .content = content.h() };
    }

    /// The largest offset: the content's overflow, 0 when it fits.
    pub fn limit(g: Geometry) f32 {
        return @max(g.content - g.view, 0);
    }
};

/// `offset` kept inside 0..`g.limit()`.
pub fn clamp(offset: f32, g: Geometry) f32 {
    return @min(@max(offset, 0), g.limit());
}

/// Starts a scroll area named `id` showing its content from `offset.*` down, and opens the
/// content. `offset.*` is clamped to what last frame's layout allows.
pub fn open(f: *Frame, th: *const Theme, id: Id, offset: *f32) void {
    const view = f.lastRect(id);
    const g = Geometry.of(view, f.lastRect(id.with(1)));
    const it = &f.ctx.inter;
    const over = inside(view, f.in.pointer);
    offset.* = scrolled(offset.*, g, over, it.response(id.with(2)).held, it.delta[1], it.response(id).focused, f.in);
    _ = f.open(.none, areaStyle(th));
    const vp = f.open(id, viewportStyle(th, offset.*));
    f.tree().c.role[vp.ix()] = view_role;
    _ = f.interact(vp, .{ .hover = true, .click = true, .focus = true });
    _ = f.open(id.with(1), contentStyle(th));
}

/// Ends the scroll area `open` started.
pub fn close(f: *Frame, th: *const Theme, id: Id, offset: f32) void {
    f.close();
    f.close();
    const g = Geometry.of(f.lastRect(id), f.lastRect(id.with(1)));
    const bar = f.open(.none, trackStyle(th));
    f.tree().c.role[bar.ix()] = role;
    f.tree().c.value[bar.ix()] = position(offset, g);
    const thumb = f.leaf(id.with(2), thumbStyle(th, g, offset));
    _ = f.interact(thumb, .{ .hover = true, .click = true, .drag = true });
    f.close();
    f.close();
}

/// The area: fills its parent; the viewport, then (C0597) the scroll bar beside it. It
/// shrinks: a grower starts from its content's size, and the content is what overflows.
pub fn areaStyle(th: *const Theme) Style {
    _ = th;
    return .{ .dir = .x, .size = .{ .fill, .fill }, .shrink = true };
}

/// The viewport: fills the area, clips, and shifts its content up by `offset`.
pub fn viewportStyle(th: *const Theme, offset: f32) Style {
    _ = th;
    return .{ .dir = .y, .size = .{ .fill, .fill }, .clip = true, .scroll = .{ 0, offset }, .role = .group };
}

/// The content: as wide as the viewport, as tall as what it holds.
pub fn contentStyle(th: *const Theme) Style {
    _ = th;
    return .{ .dir = .y, .size = .{ .fill, .fit } };
}

/// How wide the scroll bar is, logical pixels.
pub const bar_px: f32 = 8;

/// The scroll bar's track: beside the viewport, as tall as it, rounded.
pub fn trackStyle(th: *const Theme) Style {
    return .{ .size = .{ .px(bar_px), .fill }, .fill = th.control, .radius = bar_px / 2 };
}

/// The thumb: the viewport's share of the content, at the offset's share, floating in the
/// track (whose height is the viewport's). When the content fits, it fills the track.
pub fn thumbStyle(th: *const Theme, g: Geometry, offset: f32) Style {
    const scale = g.view / @max(g.content, g.view, 1);
    return .{ .float = true, .offset = .{ 0, offset * scale }, .size = .{ .px(bar_px), .px(g.view * scale) }, .fill = th.control_hot, .radius = bar_px / 2 };
}

// ---- behaviour ----------------------------------------------------------------------------

/// How far one wheel notch or one arrow key scrolls, logical pixels.
pub const line_px: f32 = 40;

/// Whether `p` is inside `r` (half-open, as hit testing).
pub fn inside(r: Rect, p: [2]f32) bool {
    return p[0] >= r.x0 and p[0] < r.x1 and p[1] >= r.y0 and p[1] < r.y1;
}

/// The next offset, clamped to `g`. With the pointer `over` the viewport, the wheel scrolls
/// `line_px` a notch (up is back) and pixel scrolling by its pixels. While the thumb is held,
/// the pointer's movement `dy` moves it, which scrolls the content by `dy` times content over
/// view. While the viewport has focus, Down and Up scroll a line, Page Down and Page Up a
/// viewport, Home and End to the ends; repeats included.
pub fn scrolled(offset: f32, g: Geometry, over: bool, held: bool, dy: f32, focused: bool, in: *const Input) f32 {
    var v = offset;
    v -= simd.b2f(over) * (in.wheel[1] * line_px + in.scroll[1]);
    v += simd.b2f(held) * dy * g.content / @max(g.view, 1);
    const k = keys.map;
    for (in.events) |e| {
        const down = focused and (e.kind == .press or e.kind == .repeat);
        const lines = simd.b2f(e.code == k.down) - simd.b2f(e.code == k.up);
        const pages = simd.b2f(e.code == keys.page_down) - simd.b2f(e.code == keys.page_up);
        v += simd.b2f(down) * (lines * line_px + pages * g.view);
        v = simd.selF(down and e.code == k.home, 0, v);
        v = simd.selF(down and e.code == k.end, g.limit(), v);
    }
    return clamp(v, g);
}

// ---- accessibility ------------------------------------------------------------------------

/// What assistive technology sees. The viewport is a `scroll_view` holding the content, and
/// the bar a `scroll_bar` whose value is the scroll position, 0 at the top to 1 at the end
/// (`position`). `types.Role` has neither, so both front ends write those bytes; the harness
/// compares them and the value.
/// The area has no name of its own: label it with `Semantics.labelled_by` where a page
/// gives it one. No states.
pub const role: u8 = @backingInt(a11y.Role.scroll_bar);
/// The viewport's role byte.
pub const view_role: u8 = @backingInt(a11y.Role.scroll_view);

/// How far through the content `offset` is, 0 to 1; 0 when the content fits.
pub fn position(offset: f32, g: Geometry) f32 {
    return base.unit(clamp(offset, g) / @max(g.limit(), 1e-6));
}

/// The scroll area as a spec node.
pub const ct = struct {
    /// A scroll area whose viewport is the widget `id`, scrolled by the f32 field `offset`,
    /// holding `children` (a tuple of specs). Mistakes are compile errors: an empty
    /// `children`, or an `offset` that is not an f32 field of the state struct.
    pub fn scroll(comptime th: Theme, comptime id: @EnumLiteral(), comptime offset: @EnumLiteral(), comptime children: anytype) Spec {
        if (children.len == 0) @compileError("scroll area '" ++ @tagName(id) ++ "' holds nothing");
        var vp = spec_zig.col(viewportStyle(&th, 0), .{spec_zig.col(contentStyle(&th), children)});
        vp.id = @tagName(id);
        const thumb: Spec = .{ .kind = .col, .id = @tagName(id) ++ "_thumb" };
        const bar: Spec = .{ .kind = .col, .style = trackStyle(&th), .children = &.{thumb} };
        var s = spec_zig.row(areaStyle(&th), .{ vp, bar });
        s.widget = Scroll(@tagName(id), @tagName(offset));
        return s;
    }

    /// How the comptime front end builds and drives one scroll area. Spec row `row` is the
    /// area; in the tree (under the root) the viewport is `row + 2`, the content `row + 3`.
    fn Scroll(comptime id: [:0]const u8, comptime offset: []const u8) type {
        return struct {
            const thumb = id ++ "_thumb";

            /// Measures last frame's viewport and content, then scrolls by this frame's input
            /// (`scrolled`): the wheel over the viewport, the held thumb's movement since the
            /// pointer's last frame position (kept), and keys while the viewport has focus.
            pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
                _ = event;
                const E = @TypeOf(ui.*).Events;
                const g = geometry(ui, row);
                const kept = ui.keep(@This());
                const over = ui.built and inside(ui.lastRect(row + 1), in.pointer);
                const held = ui.pointer.pressed == @field(E.Widget, thumb);
                const dy = in.pointer[1] - kept[2];
                kept.* = .{ g.view, g.content, in.pointer[1], 0 };
                const field = comptime @TypeOf(ui.*).field(offset);
                const focused = ui.focus == @field(E.Widget, id);
                ui.signals.set(field, scrolled(@field(ui.signals.state, offset), g, over, held, dy, focused, in));
            }

            fn geometry(ui: anytype, comptime row: u32) Geometry {
                if (!ui.built) return .{};
                return .of(ui.lastRect(row + 1), ui.lastRect(row + 2));
            }

            pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
                const th = @TypeOf(ui.*).theme;
                const t = &ui.tables.t;
                const value: f32 = @field(ui.signals.state, offset);
                const area = t.push(parent, .none, &n.style);
                const vp = t.push(area, .hash(id), &viewportStyle(&th, value));
                t.c.role[vp] = view_role;
                const content = t.push(vp, .none, &n.children[0].children[0].style);
                next.* += 3;
                inline for (n.children[0].children[0].children) |c| ui.push(c, content, next, in);
                t.seal(content);
                t.seal(vp);
                const kept = ui.keep(@This());
                const g: Geometry = .{ .view = kept[0], .content = kept[1] };
                const bar = t.push(area, .none, &n.children[1].style);
                t.c.role[bar] = role;
                t.c.value[bar] = position(value, g);
                _ = t.push(bar, .hash(thumb), &thumbStyle(&th, g, value));
                next.* += 2;
                t.seal(bar);
                t.seal(area);
            }
        };
    }
};

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;

/// The example page: a 200 x 100 scroll area over a column of six labels and a checkbox, in
/// both front ends, in theme `th`.
pub fn Page(comptime th: Theme) type {
    const frame_style: Style = .{ .dir = .y, .size = .{ .px(200), .px(100) }, .fill = th.panel };
    const column: Style = .{ .dir = .y, .pad = @splat(8), .gap = 8 };
    return struct {
        pub const App = struct {
            offset: f32 = 0,
            wire: bool = false,
            pub fn build(app: *App, f: *Frame) void {
                _ = f.open(.none, frame_style);
                open(f, &th, .from("view"), &app.offset);
                _ = f.open(.none, column);
                for ([_][]const u8{ "One", "Two", "Three", "Four", "Five", "Six" }) |s| _ = base.label(f, &th, s);
                _ = base.checkbox(f, &th, .from("wire"), &app.wire, "Wireframe");
                f.close();
                close(f, &th, .from("view"), app.offset);
                f.close();
            }
        };
        pub const State = struct {
            offset: f32 = 0,
            one: []const u8 = "One",
            two: []const u8 = "Two",
            three: []const u8 = "Three",
            four: []const u8 = "Four",
            five: []const u8 = "Five",
            six: []const u8 = "Six",
            wire: bool = false,
            wire_text: []const u8 = "Wireframe",
        };
        pub const spec = spec_zig.col(frame_style, .{ct.scroll(th, .view, .offset, .{spec_zig.col(column, .{
            base.ct.label(th, .one),
            base.ct.label(th, .two),
            base.ct.label(th, .three),
            base.ct.label(th, .four),
            base.ct.label(th, .five),
            base.ct.label(th, .six),
            base.ct.checkbox(th, .wire, .wire, .wire_text),
        })})});
        pub const Ui = base.ComptimeUi(State, spec, th);
        pub const Run = base.Harness(App, Ui, .{ .nodes = 32, .texts = 12, .customs = 1, .strings = 256, .depth = 10 });
    };
}

/// Input for `Page(.default)` at 320 x 200, one commented line per frame.
pub const replay = @embedFile("testdata/scroll.replay");

/// The frames of `replay` kept as golden images (tools/widgetgolden/ref/scroll-<name>.png).
pub const golden_frames = .{
    .{ "rest", 0 },
    .{ "wheel", 2 },
    .{ "end", 9 },
};

const Default = Page(.default);
var harness: Default.Run = .{};

/// Tree rows: root 0, frame 1, area 2, viewport 3, content 4, column 5, labels 6..11,
/// checkbox 12..14, track 15, thumb 16.
const rows = struct {
    const area = 2;
    const viewport = 3;
    const content = 4;
    const track = 15;
    const thumb = 16;
};

test "scroll: both front ends clip the content and shift it by the clamped offset" {
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    var out = try h.frame(&in);
    var t = out.runtime.tree;
    try testing.expectEqual(@as(u32, 17), t.len);
    const view = t.rect(rows.viewport);
    const content = t.rect(rows.content);
    try testing.expectEqual(@as(f32, 100), view.h());
    try testing.expect(content.h() > view.h());
    // Scrolled by 30: the content moves up by 30; past the end it stops at the overflow.
    h.app.offset = 30;
    h.ui.signals.state.offset = 30;
    out = try h.frame(&in);
    t = out.runtime.tree;
    try testing.expectEqual(view.y0 - 30, t.rect(rows.content).y0);
    h.app.offset = 1000;
    h.ui.signals.state.offset = 1000;
    out = try h.frame(&in);
    try testing.expectEqual(content.h() - view.h(), h.app.offset);
    try testing.expectEqual(h.app.offset, h.ui.signals.state.offset);
    try testing.expectEqual(view.y1, out.runtime.tree.rect(rows.content).y1);
    // A label scrolled out of the viewport is not drawn.
    try testing.expectEqual(@as(u32, 0), out.runtime.tree.c.visible[6]);
}

test "scroll: a bar beside the viewport; the thumb is the visible share at the offset's share" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 200 } };
    _ = try h.frame(&in);
    var out = try h.frame(&in);
    var t = out.runtime.tree;
    const th = Theme.default;
    const view = t.rect(rows.viewport);
    const content = t.rect(rows.content);
    const track = t.rect(rows.track);
    try testing.expectEqual(view.x1, track.x0);
    try testing.expectEqual(bar_px, track.w());
    try testing.expectEqual(view.h(), track.h());
    try testing.expectEqual(th.control.bitsOf(), t.c.look[rows.track].fill);
    try testing.expectEqual(th.control_hot.bitsOf(), t.c.look[rows.thumb].fill);
    const scale = view.h() / content.h();
    try testing.expectApproxEqAbs(view.h() * scale, t.rect(rows.thumb).h(), 0.5);
    try testing.expectEqual(track.y0, t.rect(rows.thumb).y0);
    // Scrolled to the end, the thumb sits at the bottom of the track.
    h.app.offset = 1000;
    h.ui.signals.state.offset = 1000;
    out = try h.frame(&in);
    t = out.runtime.tree;
    try testing.expectApproxEqAbs(track.y1, t.rect(rows.thumb).y1, 0.5);
    // In another theme alike.
    const Light = Page(.{ .control = .rgb(200, 200, 205), .control_hot = .rgb(150, 150, 160), .panel = .rgb(240, 240, 240), .text = .rgb(20, 20, 20) });
    const S = struct {
        var light: Light.Run = .{};
    };
    S.light.init();
    _ = try S.light.frame(&in);
    in.pointer = .{ 1, 1 };
    const lo = try S.light.frame(&in);
    try testing.expectEqual(types.Color.rgb(150, 150, 160).bitsOf(), lo.runtime.tree.c.look[rows.thumb].fill);
}

test "scrolled: wheel over the viewport, thumb drag, keys while focused, clamped" {
    const g: Geometry = .{ .view = 100, .content = 300 };
    const none_in: Input = .{};
    const wheel: Input = .{ .wheel = .{ 0, -1 } };
    try testing.expectEqual(@as(f32, 40), scrolled(0, g, true, false, 0, false, &wheel));
    try testing.expectEqual(@as(f32, 0), scrolled(0, g, false, false, 0, false, &wheel));
    const pixels: Input = .{ .scroll = .{ 0, -12 } };
    try testing.expectEqual(@as(f32, 22), scrolled(10, g, true, false, 0, false, &pixels));
    try testing.expectEqual(@as(f32, 30), scrolled(0, g, false, true, 10, false, &none_in));
    try testing.expectEqual(@as(f32, 200), scrolled(0, g, false, true, 500, false, &none_in));
    const k = keys.map;
    const ev = [3]Input.Event{ .{ .kind = .press, .code = k.down }, .{ .kind = .repeat, .code = keys.page_down }, .{ .kind = .press, .code = k.up } };
    try testing.expectEqual(@as(f32, 100), scrolled(0, g, false, false, 0, true, &.{ .events = &ev }));
    try testing.expectEqual(@as(f32, 0), scrolled(0, g, false, false, 0, false, &.{ .events = &ev }));
    const he = [1]Input.Event{.{ .kind = .press, .code = k.end }};
    try testing.expectEqual(@as(f32, 200), scrolled(0, g, false, false, 0, true, &.{ .events = &he }));
    const ho = [1]Input.Event{.{ .kind = .press, .code = k.home }};
    try testing.expectEqual(@as(f32, 0), scrolled(150, g, false, false, 0, true, &.{ .events = &ho }));
}

test "scroll: wheel, thumb drag and paging keys in both front ends" {
    const h = &harness;
    h.init();
    var in: Input = .{ .viewport = .{ 320, 200 } };
    var out = try h.frame(&in);
    const view = out.runtime.tree.rect(rows.viewport);
    const content = out.runtime.tree.rect(rows.content);
    const limit = content.h() - view.h();
    // Wheel down one notch over the viewport.
    in.pointer = .{ view.x0 + 20, view.y0 + 10 };
    in.wheel = .{ 0, -1 };
    _ = try h.frame(&in);
    in.wheel = .{ 0, 0 };
    try testing.expectEqual(line_px, h.app.offset);
    try testing.expectEqual(h.app.offset, h.ui.signals.state.offset);
    // Wheel over the bar's track does nothing.
    in.pointer = .{ view.x1 + 2, view.y0 + 10 };
    in.wheel = .{ 0, -1 };
    out = try h.frame(&in);
    in.wheel = .{ 0, 0 };
    try testing.expectEqual(line_px, h.app.offset);
    // Drag the thumb down 10 px: the content moves 10 * content / view.
    const tb = out.runtime.tree.rect(rows.thumb);
    in.pointer = .{ (tb.x0 + tb.x1) * 0.5, (tb.y0 + tb.y1) * 0.5 };
    _ = try h.frame(&in);
    in.buttons.left = true;
    _ = try h.frame(&in);
    in.pointer[1] += 10;
    _ = try h.frame(&in);
    try testing.expectApproxEqAbs(line_px + 10 * content.h() / view.h(), h.app.offset, 1e-3);
    try testing.expectEqual(h.app.offset, h.ui.signals.state.offset);
    in.buttons.left = false;
    _ = try h.frame(&in);
    // Click the viewport (a label, not the checkbox), then End and Page Up.
    in.pointer = .{ view.x0 + 20, view.y0 + 5 };
    in.buttons.left = true;
    _ = try h.frame(&in);
    in.buttons.left = false;
    _ = try h.frame(&in);
    const end = [1]Input.Event{.{ .kind = .press, .code = keys.map.end }};
    in.events = &end;
    _ = try h.frame(&in);
    try testing.expectEqual(limit, h.app.offset);
    try testing.expectEqual(limit, h.ui.signals.state.offset);
    const up = [1]Input.Event{.{ .kind = .press, .code = keys.page_up }};
    in.events = &up;
    _ = try h.frame(&in);
    try testing.expectEqual(@max(limit - view.h(), 0), h.app.offset);
    try testing.expectEqual(h.app.offset, h.ui.signals.state.offset);
}

test "scroll: viewport scroll_view, bar scroll_bar valued by position, in both front ends" {
    const check = @import("check.zig");
    const h = &harness;
    h.init();
    const in: Input = .{ .viewport = .{ 320, 200 } };
    _ = try h.frame(&in);
    var out = try h.frame(&in);
    var sb: check.SemBuf = undefined;
    try testing.expectEqual(@as(f32, 0), out.runtime.tree.c.value[rows.track]);
    const limit = out.runtime.tree.rect(rows.content).h() - out.runtime.tree.rect(rows.viewport).h();
    h.app.offset = limit / 2;
    h.ui.signals.state.offset = limit / 2;
    out = try h.frame(&in);
    for ([2]*const @import("../core/tree.zig").Tree{ out.runtime.tree, out.comptime_.tree }) |t| {
        var sem = sb.init();
        a11y.names(t, &sem);
        a11y.states(t, &sem);
        try testing.expectEqual(a11y.Role.scroll_view, @as(a11y.Role, @fromBackingInt(t.c.role[rows.viewport])));
        try testing.expectEqual(a11y.Role.scroll_bar, @as(a11y.Role, @fromBackingInt(t.c.role[rows.track])));
        try testing.expectApproxEqAbs(@as(f32, 0.5), t.c.value[rows.track], 1e-5);
        try testing.expectEqual(types.none, sem.c.name[rows.viewport]);
        try testing.expectEqual(@as(u8, 0), sem.c.state[rows.track]);
        try testing.expectEqual(@as(u8, 0), t.c.role[rows.thumb]);
    }
    try testing.expectEqual(@as(f32, 0), position(5, .{ .view = 100, .content = 50 }));
}

test "scroll: the example replay gives the same frames in both front ends" {
    const Replay = @import("../core/input.zig").Replay;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]Input.Event = undefined;
    var contacts: [1]Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var rp: Replay = .{ .src = replay };
    var offsets: [12]f32 = undefined;
    while (try rp.next(buf)) |in| {
        const k = h.frames;
        _ = try h.frame(in);
        offsets[k] = h.app.offset;
        try testing.expectEqual(h.app.offset, h.ui.signals.state.offset);
    }
    try testing.expectEqual(@as(u32, 12), h.frames);
    const drag = 40 + 10 * 187.0 / 100.0;
    const want = [12]f32{ 0, 0, 40, 40, 40, drag, drag, drag, drag, 87, 0, 40 };
    for (want, offsets) |w, got| try testing.expectApproxEqAbs(w, got, 1e-3);
}

test "golden_frames: name frames the scroll replay has" {
    inline for (golden_frames) |g| try testing.expect(g[1] < 12);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
