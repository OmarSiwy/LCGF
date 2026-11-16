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
    const g = Geometry.of(f.lastRect(id), f.lastRect(id.with(1)));
    offset.* = clamp(offset.*, g);
    _ = f.open(.none, areaStyle(th));
    _ = f.open(id, viewportStyle(th, offset.*));
    _ = f.open(id.with(1), contentStyle(th));
}

/// Ends the scroll area `open` started.
pub fn close(f: *Frame, th: *const Theme, id: Id, offset: f32) void {
    f.close();
    f.close();
    const g = Geometry.of(f.lastRect(id), f.lastRect(id.with(1)));
    _ = f.open(.none, trackStyle(th));
    _ = f.leaf(id.with(2), thumbStyle(th, g, offset));
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
    return .{ .dir = .y, .size = .{ .fill, .fill }, .clip = true, .scroll = .{ 0, offset } };
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

            /// Measures last frame's viewport and content and clamps the offset to them.
            pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
                _ = event;
                _ = in;
                const g = geometry(ui, row);
                ui.keep(@This()).* = .{ g.view, g.content, 0, 0 };
                const field = comptime @TypeOf(ui.*).field(offset);
                ui.signals.set(field, clamp(@field(ui.signals.state, offset), g));
            }

            fn geometry(ui: anytype, comptime row: u32) Geometry {
                if (!ui.built) return .{};
                const t = &ui.tables.t;
                return .of(t.rect(row + 2), t.rect(row + 3));
            }

            pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
                const th = @TypeOf(ui.*).theme;
                const t = &ui.tables.t;
                const value: f32 = @field(ui.signals.state, offset);
                const area = t.push(parent, .none, &n.style);
                const vp = t.push(area, .hash(id), &viewportStyle(&th, value));
                const content = t.push(vp, .none, &n.children[0].children[0].style);
                next.* += 3;
                inline for (n.children[0].children[0].children) |c| ui.push(c, content, next, in);
                t.seal(content);
                t.seal(vp);
                const kept = ui.keep(@This());
                const g: Geometry = .{ .view = kept[0], .content = kept[1] };
                const bar = t.push(area, .none, &n.children[1].style);
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

/// A 200 x 100 scroll area over a column of six labels and a checkbox.
fn Page(comptime th: Theme) type {
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

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(ct);
}
