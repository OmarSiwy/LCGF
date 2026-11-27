//! Styled two-axis viewport for known content extents (technical canvases and virtual lists).
//! `bounds` is an explicit box in the open parent's content coordinates. Use open, build the
//! content, close; normal Frame.end/endText performs layout and paint. Content extent and
//! offset remain application data. The lower-level scroll_policy functions also work with
//! measured content and any custom layout sequence.

const std = @import("std");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const policy = @import("../layout/scroll_policy.zig");
const keys = @import("keys.zig");
const a11y = @import("../a11y/tree.zig");
const Id = types.Id;
const Rect = types.Rect;
const Style = types.Style;

pub const State = struct { offset: [2]f32 = @splat(0) };
pub const Appearance = struct {
    viewport: Style = .{},
    tracks: [2]Style = @splat(.{ .fill = .rgb(35, 40, 50), .radius = 4 }),
    thumbs: [2]Style = @splat(.{ .fill = .rgb(135, 148, 170), .radius = 4 }),
    hovered_thumbs: [2]Style = @splat(.{ .fill = .rgb(170, 190, 220), .radius = 4 }),
    held_thumbs: [2]Style = @splat(.{ .fill = .rgb(100, 170, 255), .radius = 4 }),
    arrows: [2]Style = @splat(.{ .fill = .rgb(70, 80, 100), .radius = 2 }),
    arrow_text: types.TextStyle = .{ .px = 10, .color = .white },
    corner: Style = .{ .fill = .rgb(35, 40, 50) },
};
pub const Behavior = struct {
    geometry: policy.Options = .{},
    overscroll: [2]policy.Overscroll = .{ .chain, .chain },
    line: f32 = 40,
    /// Supplied snap points are final offsets, so logical alignment/padding is unambiguous.
    snaps: [2][]const policy.Point = .{ &.{}, &.{} },
    snap_mode: [2]policy.Snap = .{ .none, .none },
    snap_distance: f32 = 24,
};
pub const Handle = struct {
    id: Id,
    metrics: policy.Metrics,
    appearance: Appearance,
    remainder: [2]f32,
    overshoot: [2]f32,
    outer: types.Node,
    viewport: types.Node,
};

fn placed(style: Style, box: Rect, origin: [2]f32) Style {
    var out = style;
    out.float = true;
    out.offset = .{ box.x0 - origin[0], box.y0 - origin[1] };
    out.size = .{ .px(box.w()), .px(box.h()) };
    return out;
}

/// Opens the content box. Both axes consume real wheel/pixel deltas, thumb drags and focused
/// keyboard navigation. Unconsumed delta is returned for explicit ancestor chaining.
pub fn open(f: *Frame, id: Id, state: *State, bounds: Rect, extent: [2]f32, appearance: Appearance, behavior: Behavior) policy.Error!Handle {
    return openFace(f, id, state, bounds, extent, appearance, behavior, outer_style);
}

/// The outer box's look: a group, no fill.
pub const outer_style: Style = .{ .role = .group };

/// `open` with the outer box laid out by `face` instead of `outer_style`; it is still placed
/// at `bounds`.
pub fn openFace(f: *Frame, id: Id, state: *State, bounds: Rect, extent: [2]f32, appearance: Appearance, behavior: Behavior, face: Style) policy.Error!Handle {
    const inter = &f.ctx.inter;
    var r: Responses = .{ .view = inter.response(id.with(1)) };
    inline for (0..2) |a| {
        r.thumbs[a] = inter.response(id.with(4 + a));
        r.tracks[a] = inter.response(id.with(6 + a));
        inline for (0..2) |e| r.arrows[a][e] = inter.response(id.with(8 + a * 2 + e));
    }
    const moved = try advance(state, bounds, extent, behavior, hitsFrom(f.prevTree(), id, r, f.in.pointer, inter.delta), f.in);
    const geometry = try policy.measure(bounds, extent, state.offset, behavior.geometry);
    state.offset = geometry.offset;
    const outer = f.open(id, placed(face, bounds, .{ 0, 0 }));
    var viewport_style = placed(appearance.viewport, geometry.viewport, .{ bounds.x0, bounds.y0 });
    viewport_style.clip = true;
    viewport_style.scroll = state.offset;
    const viewport = f.open(id.with(1), viewport_style);
    f.tree().c.role[viewport.ix()] = @backingInt(a11y.Role.scroll_view);
    _ = f.interact(viewport, .{ .hover = true, .click = true, .focus = true });
    _ = f.open(id.with(2), .{ .size = .{ .px(extent[0]), .px(extent[1]) } });
    return .{ .id = id, .metrics = geometry, .appearance = appearance, .remainder = moved.remainder, .overshoot = moved.overshoot, .outer = outer, .viewport = viewport };
}

/// The responses of a scroll area's parts this frame.
pub const Responses = struct {
    view: types.Response = .{},
    thumbs: [2]types.Response = @splat(.{}),
    tracks: [2]types.Response = @splat(.{}),
    /// Per axis, the arrow at the start, then the one at the end.
    arrows: [2][2]types.Response = @splat(@splat(.{})),
};

/// What the pointer and the parts did to a scroll area this frame.
pub const Hits = struct {
    /// The pointer is over the viewport (last frame's), so the wheel scrolls it.
    over: bool = false,
    focus: bool = false,
    /// Per axis: the held thumb's movement along the axis in its own coordinates.
    drag: [2]f32 = @splat(0),
    back: [2]bool = @splat(false),
    forward: [2]bool = @splat(false),
    /// Per axis: a click on the track before the thumb (-1) or after it (1), or none (0).
    page: [2]f32 = @splat(0),
};

/// The hits of scroll area `id` from its parts' responses `r`, against last frame's tree
/// `prev` (the parts are `id.with(k)` in both front ends), the pointer and its movement
/// since last frame.
pub fn hitsFrom(prev: anytype, id: Id, r: Responses, pointer: [2]f32, delta: [2]f32) Hits {
    const geo = @import("../draw/geometry.zig");
    const view = prev.find(id.with(1));
    var h: Hits = .{ .over = view != types.none and geo.hitNode(prev, view, pointer), .focus = r.view.focused };
    inline for (0..2) |axis| {
        h.back[axis] = r.arrows[axis][0].clicked;
        h.forward[axis] = r.arrows[axis][1].clicked;
        const thumb = prev.find(id.with(@intCast(4 + axis)));
        if (thumb != types.none and (r.thumbs[axis].held or r.tracks[axis].clicked)) {
            if (geo.inverse(geo.worldAt(prev, thumb))) |m| {
                if (r.thumbs[axis].held) {
                    const local = [2]f32{ m[0] * delta[0] + m[2] * delta[1], m[1] * delta[0] + m[3] * delta[1] };
                    h.drag[axis] = local[axis];
                }
                if (r.tracks[axis].clicked) {
                    const p = geo.point(m, pointer);
                    const tr = prev.rect(thumb);
                    const mid = if (axis == 0) (tr.x0 + tr.x1) * 0.5 else (tr.y0 + tr.y1) * 0.5;
                    h.page[axis] = if (p[axis] < mid) -1 else 1;
                }
            }
        }
    }
    return h;
}

/// What a scroll area's step left to its ancestors.
pub const Moved = struct { remainder: [2]f32 = @splat(0), overshoot: [2]f32 = @splat(0) };

/// One frame of a scroll area at `bounds` over content of `extent`: the wheel and pixel
/// scroll while over it, thumb drags, track and arrow clicks, and while focused the arrows,
/// Page Up and Down, Home and End move `state.offset`, then overscroll and snapping apply.
/// Both front ends call it.
pub fn advance(state: *State, bounds: Rect, extent: [2]f32, behavior: Behavior, hits: Hits, in: *const Input) policy.Error!Moved {
    const geometry = try policy.measure(bounds, extent, state.offset, behavior.geometry);
    var out: Moved = .{};
    inline for (0..2) |axis| {
        const old = state.offset[axis];
        var delta: f32 = if (hits.over) -(in.wheel[axis] * behavior.line + in.scroll[axis]) else 0;
        const track_length = if (axis == 0) geometry.tracks[axis].w() else geometry.tracks[axis].h();
        const thumb_length = if (axis == 0) geometry.thumbs[axis].w() else geometry.thumbs[axis].h();
        delta += hits.drag[axis] * geometry.maximum[axis] / @max(1, track_length - thumb_length);
        if (hits.back[axis]) delta -= behavior.line;
        if (hits.forward[axis]) delta += behavior.line;
        delta += hits.page[axis] * (if (axis == 0) geometry.viewport.w() else geometry.viewport.h());
        var proposed = old + delta;
        for (in.events) |event| {
            if (!hits.focus or (event.kind != .press and event.kind != .repeat)) continue;
            const before = if (axis == 0) keys.map.left else keys.map.up;
            const after = if (axis == 0) keys.map.right else keys.map.down;
            if (event.code == before) proposed -= behavior.line;
            if (event.code == after) proposed += behavior.line;
            if (axis == 1) {
                if (event.code == keys.page_up) proposed -= geometry.viewport.h();
                if (event.code == keys.page_down) proposed += geometry.viewport.h();
                if (event.code == keys.map.home) proposed = 0;
                if (event.code == keys.map.end) proposed = geometry.maximum[axis];
            }
        }
        const consumed = try policy.consume(old, proposed - old, geometry.maximum[axis], behavior.overscroll[axis], 0.5);
        state.offset[axis] = try policy.snap(old, consumed.offset, geometry.maximum[axis], behavior.snaps[axis], behavior.snap_mode[axis], behavior.snap_distance);
        out.remainder[axis] = consumed.remaining;
        out.overshoot[axis] = consumed.overshoot;
    }
    return out;
}

/// `style` collapsed (not laid out, drawn, hit or exported) unless `shown`: a part the
/// metrics leave out still has its row, so both front ends keep one row per part.
fn part(style: Style, shown: bool) Style {
    var out = style;
    if (!shown) out.participation = .collapsed;
    return out;
}

/// The arrows' captions, per axis: start, end.
const marks = [2][2][]const u8{ .{ "<", ">" }, .{ "^", "v" } };

/// Emit scrollbar parts after content so overlay bars remain above it. Every part is an
/// ordinary styled node, collapsed while the metrics leave it out; thumb identity and input
/// behavior survive appearance changes.
pub fn close(f: *Frame, handle: Handle) void {
    f.close(); // content
    f.close(); // viewport
    const m = handle.metrics;
    const origin = [2]f32{ m.outer.x0, m.outer.y0 };
    inline for (0..2) |axis| {
        const shown = m.shown[axis];
        const track = f.leaf(handle.id.with(@intCast(6 + axis)), part(placed(handle.appearance.tracks[axis], m.tracks[axis], origin), shown));
        f.tree().c.role[track.ix()] = @backingInt(a11y.Role.scroll_bar);
        _ = f.interact(track, .{ .hover = true, .click = true });
        f.tree().c.value[track.ix()] = m.offset[axis] / @max(1e-20, m.maximum[axis]);
        const id = handle.id.with(@intCast(4 + axis));
        const thumb = f.leaf(id, part(placed(thumbStyle(handle.appearance, axis, f.ctx.inter.response(id)), m.thumbs[axis], origin), shown));
        const input = f.interact(thumb, .{ .hover = true, .click = true, .drag = true });
        f.setCursor(.grab, input.hovered or input.held);
        const arrow_boxes = [_]Rect{ m.start_buttons[axis], m.end_buttons[axis] };
        inline for (0..2) |end| {
            const box = arrow_boxes[end];
            const arrow = f.open(handle.id.with(@intCast(8 + axis * 2 + end)), part(placed(handle.appearance.arrows[axis], box, origin), shown and box.w() > 0 and box.h() > 0));
            f.tree().c.role[arrow.ix()] = @backingInt(a11y.Role.button);
            _ = f.interact(arrow, .button);
            _ = f.text(marks[axis][end], handle.appearance.arrow_text);
            f.close();
        }
    }
    _ = f.leaf(.none, part(placed(handle.appearance.corner, m.corner, origin), m.corner.w() > 0 and m.corner.h() > 0));
    f.close();
}

/// A thumb's look by its response: held, hovered, at rest.
pub fn thumbStyle(appearance: Appearance, comptime axis: usize, r: types.Response) Style {
    return if (r.held) appearance.held_thumbs[axis] else if (r.hovered) appearance.hovered_thumbs[axis] else appearance.thumbs[axis];
}

// ---- comptime front end in base.ComptimeUi ----------------------------------------------------

const spec_zig = @import("../comptime/spec.zig");
const Spec = spec_zig.Spec;
const Input = @import("../core/input.zig").Input;
const base = @import("base.zig");
const testing = std.testing;

pub const ct = struct {
    /// Scroll area `name` at `bounds` over content of `extent`, bound to the `State` field
    /// `field`, holding `children` (any spec nodes) in its content box; `spec.styled` restyles
    /// its outer box as `openFace` does. Its runtime twin is `open`, the children, `close`.
    pub fn scrollArea(comptime name: @EnumLiteral(), comptime field: @EnumLiteral(), comptime bounds: Rect, comptime extent: [2]f32, comptime appearance: Appearance, comptime behavior: Behavior, comptime children: anytype) Spec {
        const id = @tagName(name);
        comptime _ = policy.measure(bounds, extent, .{ 0, 0 }, behavior.geometry) catch @compileError("scroll area '" ++ id ++ "': invalid bounds or extent");
        const label: Spec = .{ .kind = .label, .text = "" };
        var view = spec_zig.col(.{}, .{spec_zig.col(.{}, children)});
        view.id = id ++ "_view";
        view.widget = base.FocusStop;
        var kids: []const Spec = &.{view};
        for (0..2) |a| {
            const axis = "xy"[a .. a + 1];
            kids = kids ++ &[_]Spec{
                .{ .kind = .col, .id = id ++ "_track_" ++ axis },
                .{ .kind = .col, .id = id ++ "_thumb_" ++ axis },
                .{ .kind = .col, .id = id ++ "_back_" ++ axis, .widget = base.FocusStop, .children = &.{label} },
                .{ .kind = .col, .id = id ++ "_forward_" ++ axis, .widget = base.FocusStop, .children = &.{label} },
            };
        }
        kids = kids ++ &[_]Spec{.{ .kind = .col }};
        var s = spec_zig.col(outer_style, kids);
        s.id = id;
        s.bind = @tagName(field);
        s.widget = Area(id, @tagName(field), bounds, extent, appearance, behavior);
        return s;
    }
};

/// The custom widget (`Spec.widget`) of `ct.scrollArea`: its `step` gathers the parts'
/// responses and runs `advance`, as `open` does; its `push` builds the rows `open` and
/// `close` build, with the same ids.
fn Area(comptime name: [:0]const u8, comptime field: []const u8, comptime bounds: Rect, comptime extent: [2]f32, comptime appearance: Appearance, comptime behavior: Behavior) type {
    return struct {
        pub const holds_content = true;

        pub fn bindError(comptime S: type, comptime bound: []const u8) ?[]const u8 {
            return base.fieldError(S, "scroll area '" ++ name ++ "'", bound, State);
        }

        fn rowOf(comptime U: type, comptime part_name: []const u8) u32 {
            return @backingInt(@field(U.Events.Widget, name ++ part_name));
        }

        pub fn step(ui: anytype, comptime row: u32, event: anytype, in: *const Input) void {
            _ = row;
            const U = @TypeOf(ui.*);
            // The pointer's movement since last frame, as `Interaction.delta`.
            const kept = ui.keep(@This());
            const delta = [2]f32{ in.pointer[0] - kept[0], in.pointer[1] - kept[1] };
            kept[0] = in.pointer[0];
            kept[1] = in.pointer[1];
            var r: Responses = .{ .view = base.ctResponse(ui, comptime rowOf(U, "_view"), event, in) };
            inline for (0..2) |a| {
                const axis = "xy"[a .. a + 1];
                r.thumbs[a] = base.ctResponse(ui, comptime rowOf(U, "_thumb_" ++ axis), event, in);
                r.tracks[a] = base.ctResponse(ui, comptime rowOf(U, "_track_" ++ axis), event, in);
                r.arrows[a] = .{ base.ctResponse(ui, comptime rowOf(U, "_back_" ++ axis), event, in), base.ctResponse(ui, comptime rowOf(U, "_forward_" ++ axis), event, in) };
            }
            var st: State = @field(ui.signals.state, field);
            const hits = if (ui.built) hitsFrom(&ui.tables.t, Id.hash(name), r, in.pointer, delta) else Hits{};
            _ = advance(&st, bounds, extent, behavior, hits, in) catch |e| return ui.fail(e);
            const geometry = policy.measure(bounds, extent, st.offset, behavior.geometry) catch |e| return ui.fail(e);
            st.offset = geometry.offset;
            ui.signals.set(comptime U.field(field), st);
        }

        pub fn push(ui: anytype, comptime n: Spec, parent: u32, next: *u32, in: *const Input) void {
            const start = next.*;
            const tb = &ui.tables;
            const t = &tb.t;
            const st: State = @field(ui.signals.state, field);
            // The step left an offset the metrics accept.
            const m = policy.measure(bounds, extent, st.offset, behavior.geometry) catch unreachable;
            const id = Id.hash(name);
            const outer = t.push(parent, id, &placed(n.style, bounds, .{ 0, 0 }));
            var vs = placed(appearance.viewport, m.viewport, .{ bounds.x0, bounds.y0 });
            vs.clip = true;
            vs.scroll = st.offset;
            const view = t.push(outer, id.with(1), &vs);
            t.c.role[view] = @backingInt(a11y.Role.scroll_view);
            const content = t.push(view, id.with(2), &.{ .size = .{ .px(extent[0]), .px(extent[1]) } });
            next.* += 3;
            inline for (n.children[0].children[0].children) |c| ui.push(c, content, next, in);
            t.seal(content);
            t.seal(view);
            const origin = [2]f32{ m.outer.x0, m.outer.y0 };
            inline for (0..2) |axis| {
                const shown = m.shown[axis];
                const track = t.push(outer, id.with(@intCast(6 + axis)), &part(placed(appearance.tracks[axis], m.tracks[axis], origin), shown));
                t.c.role[track] = @backingInt(a11y.Role.scroll_bar);
                t.c.value[track] = m.offset[axis] / @max(1e-20, m.maximum[axis]);
                const thumb_row: u32 = start + comptime @as(u32, @intCast(1 + @import("../comptime/flatten.zig").count(n.children[0]) + axis * 6 + 1));
                _ = t.push(outer, id.with(@intCast(4 + axis)), &part(placed(thumbStyle(appearance, axis, ui.response(thumb_row, in)), m.thumbs[axis], origin), shown));
                const boxes = [_]Rect{ m.start_buttons[axis], m.end_buttons[axis] };
                inline for (0..2) |end| {
                    const box = boxes[end];
                    const arrow = t.push(outer, id.with(@intCast(8 + axis * 2 + end)), &part(placed(appearance.arrows[axis], box, origin), shown and box.w() > 0 and box.h() > 0));
                    t.c.role[arrow] = @backingInt(a11y.Role.button);
                    const label = t.push(arrow, .none, &.{ .role = .label });
                    t.c.text[label] = tb.tx.push(label, tb.strings.add(marks[axis][end]), &appearance.arrow_text);
                    t.seal(arrow);
                }
            }
            _ = t.push(outer, .none, &part(placed(appearance.corner, m.corner, origin), m.corner.w() > 0 and m.corner.h() > 0));
            t.seal(outer);
            next.* = start + comptime @import("../comptime/flatten.zig").count(n);
        }
    };
}

/// The scroll area restyled as a page does from data: `openFace` against `spec.styled` on
/// `ct.scrollArea`, over wheel, thumb drag, track click and keys.
const restyled = struct {
    const face: Style = .{ .role = .group, .fill = .rgb(20, 40, 60), .radius = 6 };
    const bounds: Rect = .{ .x0 = 10, .y0 = 10, .x1 = 110, .y1 = 110 };
    const extent = [2]f32{ 250, 300 };
    const App = struct {
        area: State = .{},
        pub fn build(app: *App, f: *Frame) void {
            _ = f.open(.none, .{});
            const handle = openFace(f, .from("canvas"), &app.area, bounds, extent, .{}, .{}, face) catch unreachable;
            _ = f.leaf(.none, .{ .size = .{ .px(250), .px(300) }, .fill = .white });
            close(f, handle);
            f.close();
        }
    };
    const PageState = struct { area: State = .{} };
    const spec = spec_zig.col(.{}, .{spec_zig.styled(ct.scrollArea(.canvas, .area, bounds, extent, .{}, .{}, .{spec_zig.col(.{ .size = .{ .px(250), .px(300) }, .fill = .white }, .{})}), face)});
    var h: base.Harness(App, base.ComptimeUi(PageState, spec, .default), .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 64, .depth = 8 }) = .{};
};

test "ct.scrollArea restyled: the same frames as openFace, wheel, drag, track and keys" {
    const h = &restyled.h;
    h.init();
    var in: Input = .{ .viewport = .{ 200, 200 }, .pointer = .{ 50, 50 } };
    _ = try h.frame(&in);
    in.wheel = .{ 0, -1 };
    _ = try h.frame(&in);
    in.wheel = .{ 0, 0 };
    try testing.expect(h.app.area.offset[1] > 0);
    // Drag the vertical thumb down.
    const t = h.ctx.trees[h.ctx.cur];
    const thumb = t.rect(t.find(Id.from("canvas").with(5)));
    in.pointer = .{ (thumb.x0 + thumb.x1) / 2, (thumb.y0 + thumb.y1) / 2 };
    for ([_]f32{ 0, 0, 10, 20, 20 }, [_]bool{ false, true, true, true, false }) |dy, down| {
        in.pointer[1] += dy;
        in.buttons.left = down;
        _ = try h.frame(&in);
    }
    // A click on the horizontal track after its thumb pages right; then focus and Home.
    const track = h.ctx.trees[h.ctx.cur].rect(h.ctx.trees[h.ctx.cur].find(Id.from("canvas").with(6)));
    in.pointer = .{ track.x1 - 3, (track.y0 + track.y1) / 2 };
    for ([_]bool{ true, false }) |down| {
        in.buttons.left = down;
        _ = try h.frame(&in);
    }
    try testing.expect(h.app.area.offset[0] > 0);
    in.pointer = .{ 50, 50 };
    for ([_]bool{ true, false }) |down| {
        in.buttons.left = down;
        _ = try h.frame(&in);
    }
    const ev = [_]Input.Event{.{ .kind = .press, .code = keys.map.home }};
    in.events = &ev;
    _ = try h.frame(&in);
    try testing.expectEqual(@as(f32, 0), h.app.area.offset[1]);
    try testing.expectEqual(h.app.area, h.ui.signals.state.area);
}

test "openFace: the theme's styles draw as open" {
    const S = struct {
        var state: [2]State = .{ .{}, .{} };
        fn build(f: *Frame, k: u1) void {
            const bounds: Rect = .{ .x0 = 10, .y0 = 10, .x1 = 110, .y1 = 110 };
            const handle = (if (k == 0) open(f, .from("canvas"), &state[k], bounds, .{ 250, 300 }, .{}, .{}) else openFace(f, .from("canvas"), &state[k], bounds, .{ 250, 300 }, .{}, .{}, outer_style)) catch unreachable;
            _ = f.leaf(.from("content"), .{ .size = .{ .px(250), .px(300) }, .fill = .white });
            close(f, handle);
        }
    };
    try @import("base.zig").expectSameFace(.{ .nodes = 32, .texts = 4, .customs = 1, .strings = 64, .depth = 8 }, S.build, .{ 105, 50 });
    try std.testing.expectEqual(S.state[0], S.state[1]);
}

test "two-axis styled viewport consumes input and emits semantic bars through ordinary Frame" {
    const context = @import("../runtime/context.zig");
    const mem = @import("../core/mem.zig");
    const limits: context.Limits = .{ .nodes = 32, .texts = 4, .customs = 1, .strings = 64, .depth = 8 };
    var raw: [context.Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
    var ctx = try context.Context.init(&raw, limits);
    var state: State = .{};
    var input: @import("../core/input.zig").Input = .{ .viewport = .{ 200, 200 }, .pointer = .{ 30, 30 } };
    var result: context.Output = undefined;
    for (0..2) |frame| {
        input.scroll = if (frame == 0) .{ 0, 0 } else .{ -15, -25 };
        var f = ctx.begin(&input);
        const handle = try open(&f, .from("canvas"), &state, .{ .x0 = 10, .y0 = 10, .x1 = 110, .y1 = 110 }, .{ 250, 300 }, .{}, .{});
        _ = f.leaf(.from("content"), .{ .size = .{ .px(250), .px(300) }, .fill = .white });
        close(&f, handle);
        result = f.end(.{});
    }
    try std.testing.expectEqual([2]f32{ 15, 25 }, state.offset);
    const content = result.tree.find(.from("content"));
    const view = result.tree.find(Id.from("canvas").with(1));
    try std.testing.expectEqual(result.tree.rect(view).x0 - 15, result.tree.rect(content).x0);
    try std.testing.expectEqual(result.tree.rect(view).y0 - 25, result.tree.rect(content).y0);
    try std.testing.expectEqual(@backingInt(a11y.Role.scroll_view), result.tree.c.role[view]);
    inline for (0..2) |axis| {
        const bar = result.tree.find(Id.from("canvas").with(@intCast(6 + axis)));
        try std.testing.expectEqual(@backingInt(a11y.Role.scroll_bar), result.tree.c.role[bar]);
        try std.testing.expect(result.tree.c.value[bar] > 0);
    }
    try std.testing.expect(result.draw.quad_len >= 5);
}
