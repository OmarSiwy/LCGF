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
    var geometry = try policy.measure(bounds, extent, state.offset, behavior.geometry);
    const previous = f.prevTree();
    const previous_view = previous.find(id.with(1));
    const over = previous_view != types.none and @import("../draw/geometry.zig").hitNode(previous, previous_view, f.in.pointer);
    const focus = f.ctx.inter.response(id.with(1)).focused;
    var remainder: [2]f32 = @splat(0);
    var overshoot: [2]f32 = @splat(0);
    inline for (0..2) |axis| {
        const old = state.offset[axis];
        var delta: f32 = if (over) -(f.in.wheel[axis] * behavior.line + f.in.scroll[axis]) else 0;
        const thumb = f.ctx.inter.response(id.with(@intCast(4 + axis)));
        const track_length = if (axis == 0) geometry.tracks[axis].w() else geometry.tracks[axis].h();
        const thumb_length = if (axis == 0) geometry.thumbs[axis].w() else geometry.thumbs[axis].h();
        if (thumb.held) {
            const thumb_node = previous.find(id.with(@intCast(4 + axis)));
            if (thumb_node != types.none) {
                const inverse = @import("../draw/geometry.zig").inverse(@import("../draw/geometry.zig").worldAt(previous, thumb_node));
                if (inverse) |m| {
                    const local_delta = [2]f32{ m[0] * f.ctx.inter.delta[0] + m[2] * f.ctx.inter.delta[1], m[1] * f.ctx.inter.delta[0] + m[3] * f.ctx.inter.delta[1] };
                    delta += local_delta[axis] * geometry.maximum[axis] / @max(1, track_length - thumb_length);
                }
            }
        }
        const back = f.ctx.inter.response(id.with(@intCast(8 + axis * 2))).clicked;
        const forward = f.ctx.inter.response(id.with(@intCast(9 + axis * 2))).clicked;
        if (back) delta -= behavior.line;
        if (forward) delta += behavior.line;
        if (f.ctx.inter.response(id.with(@intCast(6 + axis))).clicked) {
            const thumb_node = previous.find(id.with(@intCast(4 + axis)));
            if (thumb_node != types.none) {
                if (@import("../draw/geometry.zig").inverse(@import("../draw/geometry.zig").worldAt(previous, thumb_node))) |m| {
                    const point = @import("../draw/geometry.zig").point(m, f.in.pointer);
                    const thumb_rect = previous.rect(thumb_node);
                    const midpoint = if (axis == 0) (thumb_rect.x0 + thumb_rect.x1) * 0.5 else (thumb_rect.y0 + thumb_rect.y1) * 0.5;
                    delta += (if (point[axis] < midpoint) @as(f32, -1) else 1) * (if (axis == 0) geometry.viewport.w() else geometry.viewport.h());
                }
            }
        }
        var proposed = old + delta;
        for (f.in.events) |event| {
            if (!focus or (event.kind != .press and event.kind != .repeat)) continue;
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
        remainder[axis] = consumed.remaining;
        overshoot[axis] = consumed.overshoot;
    }
    geometry = try policy.measure(bounds, extent, state.offset, behavior.geometry);
    state.offset = geometry.offset;
    const outer = f.open(id, placed(.{ .role = .group }, bounds, .{ 0, 0 }));
    var viewport_style = placed(appearance.viewport, geometry.viewport, .{ bounds.x0, bounds.y0 });
    viewport_style.clip = true;
    viewport_style.scroll = state.offset;
    const viewport = f.open(id.with(1), viewport_style);
    f.tree().c.role[viewport.ix()] = @backingInt(a11y.Role.scroll_view);
    _ = f.interact(viewport, .{ .hover = true, .click = true, .focus = true });
    _ = f.open(id.with(2), .{ .size = .{ .px(extent[0]), .px(extent[1]) } });
    return .{ .id = id, .metrics = geometry, .appearance = appearance, .remainder = remainder, .overshoot = overshoot, .outer = outer, .viewport = viewport };
}

/// Emit scrollbar parts after content so overlay bars remain above it. Every part is an
/// ordinary styled node; thumb identity and input behavior survive appearance changes.
pub fn close(f: *Frame, handle: Handle) void {
    f.close(); // content
    f.close(); // viewport
    const m = handle.metrics;
    const origin = [2]f32{ m.outer.x0, m.outer.y0 };
    inline for (0..2) |axis| {
        if (m.shown[axis]) {
            const track = f.leaf(handle.id.with(@intCast(6 + axis)), placed(handle.appearance.tracks[axis], m.tracks[axis], origin));
            f.tree().c.role[track.ix()] = @backingInt(a11y.Role.scroll_bar);
            _ = f.interact(track, .{ .hover = true, .click = true });
            f.tree().c.value[track.ix()] = m.offset[axis] / @max(1e-20, m.maximum[axis]);
            const id = handle.id.with(@intCast(4 + axis));
            const response = f.ctx.inter.response(id);
            const style = if (response.held) handle.appearance.held_thumbs[axis] else if (response.hovered) handle.appearance.hovered_thumbs[axis] else handle.appearance.thumbs[axis];
            const thumb = f.leaf(id, placed(style, m.thumbs[axis], origin));
            const input = f.interact(thumb, .{ .hover = true, .click = true, .drag = true });
            f.setCursor(.grab, input.hovered or input.held);
            const arrow_boxes = [_]Rect{ m.start_buttons[axis], m.end_buttons[axis] };
            inline for (0..2) |end| {
                if (arrow_boxes[end].w() > 0 and arrow_boxes[end].h() > 0) {
                    const arrow = f.open(handle.id.with(@intCast(8 + axis * 2 + end)), placed(handle.appearance.arrows[axis], arrow_boxes[end], origin));
                    f.tree().c.role[arrow.ix()] = @backingInt(a11y.Role.button);
                    _ = f.interact(arrow, .button);
                    const marks = [2][2][]const u8{ .{ "<", ">" }, .{ "^", "v" } };
                    _ = f.text(marks[axis][end], handle.appearance.arrow_text);
                    f.close();
                }
            }
        }
    }
    if (m.corner.w() > 0 and m.corner.h() > 0) _ = f.leaf(.none, placed(handle.appearance.corner, m.corner, origin));
    f.close();
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
