//! Scroll geometry and policy, independently callable over application-owned state. Values
//! are logical pixels. Positive deltas move toward the content end; Input wheel/pixel signs
//! are inverted by the widget adapter. No hidden scroll registry or animation clock.

const std = @import("std");
const types = @import("../core/types.zig");
const Tree = @import("../core/tree.zig").Tree;
const Rect = types.Rect;
pub const Error = error{ InvalidGeometry, NoSpace, InvalidNode };
pub const Bar = enum { auto, always, hidden };
pub const Gutter = enum { overlay, automatic, stable, both_edges };
pub const Side = enum { start, end };
pub const Options = struct {
    axes: [2]bool = .{ true, true },
    bars: [2]Bar = .{ .auto, .auto },
    gutter: Gutter = .automatic,
    vertical_side: Side = .end,
    horizontal_side: Side = .end,
    thickness: f32 = 12,
    minimum_thumb: f32 = 20,
    arrows: bool = false,
    /// Overlay bars may be hidden between hover/drag events without changing viewport size.
    show_overlay: bool = true,
};
pub const Metrics = struct {
    outer: Rect,
    viewport: Rect,
    maximum: [2]f32,
    offset: [2]f32,
    tracks: [2]Rect,
    thumbs: [2]Rect,
    shown: [2]bool,
    start_buttons: [2]Rect,
    end_buttons: [2]Rect,
    corner: Rect,
};

fn rect(origin: [2]f32, size: [2]f32) Rect {
    return .{ .x0 = origin[0], .y0 = origin[1], .x1 = origin[0] + size[0], .y1 = origin[1] + size[1] };
}

/// Two coupled auto bars reach a fixed point in at most three iterations: a vertical gutter
/// can make horizontal content overflow, which can in turn require the vertical gutter.
pub fn measure(outer: Rect, content: [2]f32, offset: [2]f32, options: Options) Error!Metrics {
    for (outer.array()) |v| if (!std.math.isFinite(v)) return error.InvalidGeometry;
    for (content ++ offset ++ [_]f32{ options.thickness, options.minimum_thumb }) |v| if (!std.math.isFinite(v)) return error.InvalidGeometry;
    if (outer.w() < 0 or outer.h() < 0 or content[0] < 0 or content[1] < 0 or options.thickness < 0 or options.minimum_thumb < 0) return error.InvalidGeometry;
    const size = [2]f32{ outer.w(), outer.h() };
    var shown: [2]bool = @splat(false);
    inline for (0..2) |a| shown[a] = options.axes[a] and options.bars[a] == .always;
    var insets: [4]f32 = @splat(0);
    var view = size;
    for (0..3) |_| {
        insets = @splat(0);
        inline for (0..2) |axis| {
            const reserved = options.gutter != .overlay and options.axes[axis] and options.bars[axis] != .hidden and
                (shown[axis] or options.gutter == .stable or options.gutter == .both_edges);
            const edge = 1 - axis;
            const side = if (axis == 1) options.vertical_side else options.horizontal_side;
            const thickness = @min(options.thickness, size[edge] / (if (options.gutter == .both_edges) @as(f32, 2) else 1));
            if (reserved) {
                insets[edge + (if (side == .start) @as(usize, 0) else 2)] = thickness;
                if (options.gutter == .both_edges) insets[edge + (if (side == .start) @as(usize, 2) else 0)] = thickness;
            }
        }
        inline for (0..2) |a| {
            view[a] = @max(0, size[a] - insets[a] - insets[a + 2]);
            shown[a] = options.axes[a] and options.bars[a] != .hidden and (options.bars[a] == .always or content[a] > view[a]);
        }
    }
    const viewport = rect(.{ outer.x0 + insets[0], outer.y0 + insets[1] }, view);
    var result: Metrics = .{ .outer = outer, .viewport = viewport, .maximum = undefined, .offset = undefined, .shown = shown, .tracks = @splat(.{}), .thumbs = @splat(.{}), .corner = .{}, .start_buttons = @splat(.{}), .end_buttons = @splat(.{}) };
    inline for (0..2) |axis| {
        result.maximum[axis] = if (options.axes[axis]) @max(0, content[axis] - view[axis]) else 0;
        result.offset[axis] = std.math.clamp(offset[axis], 0, result.maximum[axis]);
        result.shown[axis] = shown[axis] and (options.gutter != .overlay or options.show_overlay);
        if (result.shown[axis]) {
            const side = if (axis == 1) options.vertical_side else options.horizontal_side;
            const edge = 1 - axis;
            const thickness = @min(options.thickness, size[edge]);
            var origin = [2]f32{ viewport.x0, viewport.y0 };
            var track_size = view;
            track_size[edge] = thickness;
            origin[edge] = (if (edge == 0) outer.x0 else outer.y0) + (if (side == .start) @as(f32, 0) else size[edge] - thickness);
            if (options.arrows) {
                const arrow_length = @min(thickness, track_size[axis] * 0.5);
                var arrow_size = track_size;
                arrow_size[axis] = arrow_length;
                result.start_buttons[axis] = rect(origin, arrow_size);
                var end_origin = origin;
                end_origin[axis] += track_size[axis] - arrow_length;
                result.end_buttons[axis] = rect(end_origin, arrow_size);
                origin[axis] += arrow_length;
                track_size[axis] -= 2 * arrow_length;
            }
            result.tracks[axis] = rect(origin, track_size);
            const length = @min(track_size[axis], @max(options.minimum_thumb, track_size[axis] * view[axis] / @max(content[axis], 1e-20)));
            const fraction = result.offset[axis] / @max(result.maximum[axis], 1e-20);
            origin[axis] += fraction * (track_size[axis] - length);
            track_size[axis] = length;
            result.thumbs[axis] = rect(origin, track_size);
        }
    }
    if (shown[0] and shown[1] and options.gutter != .overlay) {
        result.corner = .{ .x0 = result.tracks[1].x0, .x1 = result.tracks[1].x1, .y0 = result.tracks[0].y0, .y1 = result.tracks[0].y1 };
    }
    return result;
}

pub const Overscroll = enum { chain, contain, elastic };
pub const Consumed = struct { offset: f32, remaining: f32, overshoot: f32 };

/// Remaining delta is passed explicitly to the next ancestor. Containment consumes it;
/// elastic policy also reports a resisted overshoot for an existing Kinetic spring row.
pub fn consume(offset: f32, delta: f32, maximum: f32, policy: Overscroll, resistance: f32) Error!Consumed {
    for ([_]f32{ offset, delta, maximum, resistance }) |v| if (!std.math.isFinite(v)) return error.InvalidGeometry;
    if (maximum < 0 or resistance < 0 or resistance > 1) return error.InvalidGeometry;
    const old = std.math.clamp(offset, 0, maximum);
    const next = std.math.clamp(old + delta, 0, maximum);
    const excess = delta - (next - old);
    return .{ .offset = next, .remaining = if (policy == .chain) excess else 0, .overshoot = if (policy == .elastic) excess * resistance else 0 };
}

pub const Alignment = enum { nearest, start, center, end };
pub const Point = struct { position: f32, stop_always: bool = false };
pub const Snap = enum { none, proximity, mandatory };

/// Snap candidates are final scroll offsets, already adjusted for alignment/padding. An
/// always-stop point crossed in the travel direction wins before the nearest destination.
pub fn snap(current: f32, proposed: f32, maximum: f32, points: []const Point, mode: Snap, proximity: f32) Error!f32 {
    for ([_]f32{ current, proposed, maximum, proximity }) |v| if (!std.math.isFinite(v)) return error.InvalidGeometry;
    if (maximum < 0 or proximity < 0) return error.InvalidGeometry;
    const want = std.math.clamp(proposed, 0, maximum);
    if (mode == .none or points.len == 0) return want;
    var nearest = want;
    var distance = std.math.inf(f32);
    var forced = want;
    var forced_distance = std.math.inf(f32);
    for (points) |candidate| {
        if (!std.math.isFinite(candidate.position)) return error.InvalidGeometry;
        const p = std.math.clamp(candidate.position, 0, maximum);
        const d = @abs(p - want);
        if (d < distance) {
            distance = d;
            nearest = p;
        }
        const crossed = if (want >= current) p > current and p <= want else p < current and p >= want;
        const travel = @abs(p - current);
        if (candidate.stop_always and crossed and travel < forced_distance) {
            forced = p;
            forced_distance = travel;
        }
    }
    if (std.math.isFinite(forced_distance)) return forced;
    return if (mode == .mandatory or distance <= proximity) nearest else want;
}

fn revealAxis(offset: f32, lo: f32, hi: f32, target_lo: f32, target_hi: f32, maximum: f32, alignment: Alignment) f32 {
    const delta = switch (alignment) {
        .start => target_lo - lo,
        .center => (target_lo + target_hi - lo - hi) * 0.5,
        .end => target_hi - hi,
        .nearest => if (target_hi - target_lo > hi - lo) target_lo - lo else if (target_lo < lo) target_lo - lo else if (target_hi > hi) target_hi - hi else 0,
    };
    return std.math.clamp(offset + delta, 0, @max(0, maximum));
}

/// Viewport and target are in the same current layout space. Padding shrinks the usable
/// viewport; margin grows the target. The result is caller state for the next layout pass.
pub fn reveal(offset: [2]f32, viewport: Rect, target: Rect, maximum: [2]f32, padding: [4]f32, margin: [4]f32, alignment: [2]Alignment) [2]f32 {
    return .{
        revealAxis(offset[0], viewport.x0 + padding[0], viewport.x1 - padding[2], target.x0 - margin[0], target.x1 + margin[2], maximum[0], alignment[0]),
        revealAxis(offset[1], viewport.y0 + padding[1], viewport.y1 - padding[3], target.y0 - margin[1], target.y1 + margin[3], maximum[1], alignment[1]),
    };
}

pub const Reveal = struct { node: u32, maximum: [2]f32, padding: [4]f32 = @splat(0) };

/// Containers are listed innermost first. Apply each inner scroll displacement to the target
/// seen by the next ancestor, so outer containers do not over-scroll for a movement already
/// handled inside. No tree mutation; caller writes offsets and runs placement/finalize.
pub fn revealNested(t: *const Tree, target: u32, containers: []const Reveal, margin: [4]f32, out: [][2]f32) Error!void {
    if (out.len < containers.len) return error.NoSpace;
    if (target >= t.len) return error.InvalidNode;
    var box = t.rect(target);
    for (containers, 0..) |container, k| {
        if (container.node >= target or target >= t.c.end[container.node]) return error.InvalidNode;
        const old = [2]f32{ t.c.scroll[0][container.node], t.c.scroll[1][container.node] };
        out[k] = reveal(old, t.rect(container.node), box, container.maximum, container.padding, margin, .{ .nearest, .nearest });
        const dx = out[k][0] - old[0];
        const dy = out[k][1] - old[1];
        box.x0 -= dx;
        box.x1 -= dx;
        box.y0 -= dy;
        box.y1 -= dy;
    }
}

/// Preserve an explicitly selected content anchor through insertion/removal above it.
pub fn anchor(offset: f32, previous_position: f32, current_position: f32, maximum: f32) f32 {
    return std.math.clamp(offset + current_position - previous_position, 0, @max(0, maximum));
}

/// Move a subtree without changing its measured size. Fixed/sticky consumers call this
/// after ordinary place and before finalize, exactly like the existing anchor pass.
pub fn translate(t: *Tree, node: u32, delta: [2]f32) Error!void {
    if (node >= t.len or t.c.end[node] <= node or t.c.end[node] > t.len) return error.InvalidNode;
    inline for (0..2) |axis| {
        for (t.c.pos[axis][node..t.c.end[node]]) |*value| value.* += delta[axis];
    }
}

pub fn fixed(t: *Tree, node: u32, viewport_origin: [2]f32, inset: [2]f32) Error!void {
    if (node >= t.len) return error.InvalidNode;
    try translate(t, node, .{ viewport_origin[0] + inset[0] - t.c.pos[0][node], viewport_origin[1] + inset[1] - t.c.pos[1][node] });
}

/// Both start and end constraints, clamped inside the containing block. Overspecified
/// constraints on an oversized item favor the start edge, matching reveal's stable policy.
pub fn sticky(t: *Tree, node: u32, scroller: u32, start: [2]?f32, end: [2]?f32) Error!void {
    if (node >= t.len or scroller >= node or node >= t.c.end[scroller]) return error.InvalidNode;
    const parent = t.c.parent[node];
    var delta: [2]f32 = @splat(0);
    inline for (0..2) |axis| {
        if (start[axis] == null and end[axis] == null) continue;
        const pos = t.c.pos[axis];
        const size = t.c.size[axis];
        var wanted = pos[node];
        const low = pos[scroller] + t.c.pad_lo[axis][scroller] + (start[axis] orelse -std.math.inf(f32));
        const high = pos[scroller] + size[scroller] - t.c.pad_hi[axis][scroller] - size[node] - (end[axis] orelse -std.math.inf(f32));
        wanted = @max(low, @min(wanted, high));
        const parent_low = pos[parent] + t.c.pad_lo[axis][parent];
        const parent_high = @max(parent_low, pos[parent] + size[parent] - t.c.pad_hi[axis][parent] - size[node]);
        delta[axis] = std.math.clamp(wanted, parent_low, parent_high) - pos[node];
    }
    try translate(t, node, delta);
}

test "both-axis gutters converge, mirror and position thumbs with real offsets" {
    const box: Rect = .{ .x0 = 10, .y0 = 20, .x1 = 110, .y1 = 120 };
    const m = try measure(box, .{ 95, 200 }, .{ 7, 80 }, .{ .thickness = 10, .minimum_thumb = 12, .vertical_side = .start });
    try std.testing.expectEqual([2]bool{ true, true }, m.shown);
    try std.testing.expectEqual(@as(f32, 20), m.viewport.x0);
    try std.testing.expectEqual(@as(f32, 90), m.viewport.w());
    try std.testing.expectEqual(@as(f32, 5), m.offset[0]);
    try std.testing.expect(m.thumbs[1].y0 > m.tracks[1].y0);
    const stable = try measure(box, .{ 20, 20 }, .{ 0, 0 }, .{ .gutter = .both_edges, .thickness = 10 });
    try std.testing.expectEqual(@as(f32, 80), stable.viewport.w());
    try std.testing.expectEqual(@as(f32, 80), stable.viewport.h());
    try std.testing.expectEqual([2]bool{ false, false }, stable.shown);
}

test "chaining, snap stops, reveal padding and content anchoring combine predictably" {
    const child = try consume(90, 50, 100, .chain, 0.5);
    const parent = try consume(20, child.remaining, 200, .chain, 0.5);
    try std.testing.expectEqual(@as(f32, 100), child.offset);
    try std.testing.expectEqual(@as(f32, 60), parent.offset);
    try std.testing.expectEqual(@as(f32, 0), (try consume(100, 10, 100, .contain, 0.5)).remaining);
    try std.testing.expectEqual(@as(f32, 5), (try consume(100, 10, 100, .elastic, 0.5)).overshoot);
    try std.testing.expectEqual(@as(f32, 40), try snap(10, 90, 100, &.{ .{ .position = 40, .stop_always = true }, .{ .position = 90 } }, .mandatory, 10));
    const next = reveal(.{ 0, 10 }, .{ .x1 = 100, .y1 = 100 }, .{ .x0 = 20, .x1 = 30, .y0 = 120, .y1 = 140 }, .{ 200, 200 }, @splat(10), @splat(5), .{ .nearest, .nearest });
    try std.testing.expectEqual([2]f32{ 0, 65 }, next);
    try std.testing.expectEqual(@as(f32, 85), anchor(next[1], 100, 120, 200));
}
