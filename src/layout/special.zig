//! Optional bounded layout algorithms over measured values. Callers measure first, choose
//! an algorithm, then emit ordinary floating Style rows with `style`. No callback, retained
//! widget graph or hidden allocation is needed. These helpers compose with the core passes.

const std = @import("std");
const types = @import("../core/types.zig");
const Rect = types.Rect;
pub const Error = error{ NoSpace, InvalidGeometry, InvalidSpan };

pub const Item = struct { size: [2]f32, span: u32 = 1, break_before: bool = false };
pub const Placement = struct { rect: Rect };
pub const Distribution = enum { start, center, end, space_between, space_around, space_evenly };

fn check(box: Rect, items: []const Item, out: []Placement) Error!void {
    if (out.len < items.len) return error.NoSpace;
    for (box.array()) |v| if (!std.math.isFinite(v)) return error.InvalidGeometry;
    if (box.x1 < box.x0 or box.y1 < box.y0) return error.InvalidGeometry;
    for (items) |item| for (item.size) |v| if (!std.math.isFinite(v) or v < 0) return error.InvalidGeometry;
}
fn make(x: f32, y: f32, w: f32, h: f32) Placement {
    return .{ .rect = .{ .x0 = x, .y0 = y, .x1 = x + w, .y1 = y + h } };
}

/// Lowers a placement to the existing tree/layout path. `origin` is the parent's content
/// origin in the placement coordinate system. Normal child layout sees the explicit size.
pub fn style(placement: Placement, base: types.Style, origin: [2]f32) types.Style {
    var result = base;
    result.float = true;
    result.offset = .{ placement.rect.x0 - origin[0], placement.rect.y0 - origin[1] };
    result.size = .{ .px(placement.rect.x1 - placement.rect.x0), .px(placement.rect.y1 - placement.rect.y0) };
    return result;
}

pub const Dock = enum { left, top, right, bottom, fill };
pub fn dock(box: Rect, items: []const Item, sides: []const Dock, gap: f32, out: []Placement) Error!Rect {
    try check(box, items, out);
    if (sides.len < items.len) return error.NoSpace;
    if (!std.math.isFinite(gap) or gap < 0) return error.InvalidGeometry;
    var remaining = box;
    for (items, sides[0..items.len], out[0..items.len]) |item, side, *p| {
        const w = @min(item.size[0], remaining.x1 - remaining.x0);
        const h = @min(item.size[1], remaining.y1 - remaining.y0);
        p.rect = remaining;
        switch (side) {
            .left => {
                p.rect.x1 = remaining.x0 + w;
                remaining.x0 = @min(p.rect.x1 + gap, remaining.x1);
            },
            .right => {
                p.rect.x0 = remaining.x1 - w;
                remaining.x1 = @max(p.rect.x0 - gap, remaining.x0);
            },
            .top => {
                p.rect.y1 = remaining.y0 + h;
                remaining.y0 = @min(p.rect.y1 + gap, remaining.y1);
            },
            .bottom => {
                p.rect.y0 = remaining.y1 - h;
                remaining.y1 = @max(p.rect.y0 - gap, remaining.y0);
            },
            .fill => {}, // Multiple fill rows intentionally form an overlapping stack.
        }
    }
    return remaining;
}

pub const Radial = struct { center: [2]f32, radius: [2]f32, start: f32 = -std.math.pi / 2.0, sweep: f32 = 2 * std.math.pi, include_end: bool = false, pivot: [2]f32 = .{ 0.5, 0.5 } };
pub fn radial(items: []const Item, options: Radial, out: []Placement) Error!void {
    try check(.{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 }, items, out);
    for (options.center ++ options.radius ++ options.pivot ++ [2]f32{ options.start, options.sweep }) |v| if (!std.math.isFinite(v)) return error.InvalidGeometry;
    const divisor: f32 = @floatFromInt(@max(items.len -| @intFromBool(options.include_end), 1));
    for (items, out[0..items.len], 0..) |item, *p, i| {
        const a = options.start + options.sweep * @as(f32, @floatFromInt(i)) / divisor;
        p.* = make(options.center[0] + @cos(a) * options.radius[0] - item.size[0] * options.pivot[0], options.center[1] + @sin(a) * options.radius[1] - item.size[1] * options.pivot[1], item.size[0], item.size[1]);
    }
}

/// Stable shortest-column masonry. A spanning item starts at the earliest lowest window
/// of adjacent columns; every occupied column advances to its bottom. Heights are inputs
/// measured at the actual spanned width, not guessed from the previous frame.
pub fn masonry(box: Rect, items: []const Item, columns: u32, gap: [2]f32, heights: []f32, out: []Placement) Error!f32 {
    try check(box, items, out);
    if (columns == 0) return error.InvalidGeometry;
    if (heights.len < columns) return error.NoSpace;
    for (gap) |v| if (!std.math.isFinite(v) or v < 0) return error.InvalidGeometry;
    const width = @max(0, (box.x1 - box.x0 - gap[0] * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns)));
    @memset(heights[0..columns], box.y0);
    var bottom = box.y0;
    for (items, out[0..items.len]) |item, *p| {
        if (item.span == 0 or item.span > columns) return error.InvalidSpan;
        var best: u32 = 0;
        var lowest = std.math.inf(f32);
        for (0..columns - item.span + 1) |at| {
            var top = box.y0;
            for (heights[at..][0..item.span]) |h| top = @max(top, h);
            if (top < lowest) {
                best = @intCast(at);
                lowest = top;
            }
        }
        p.* = make(box.x0 + @as(f32, @floatFromInt(best)) * (width + gap[0]), lowest, @as(f32, @floatFromInt(item.span)) * width + @as(f32, @floatFromInt(item.span - 1)) * gap[0], item.size[1]);
        @memset(heights[best..][0..item.span], p.rect.y1 + gap[1]);
        bottom = @max(bottom, p.rect.y1);
    }
    return bottom - box.y0;
}

pub const Flow = struct { axis: u1 = 0, gap: [2]f32 = .{ 0, 0 }, distribution: Distribution = .start, cross_factor: f32 = 0 };
pub fn flow(box: Rect, items: []const Item, options: Flow, out: []Placement) Error![2]f32 {
    try check(box, items, out);
    for (options.gap ++ [1]f32{options.cross_factor}) |v| if (!std.math.isFinite(v) or v < 0) return error.InvalidGeometry;
    const a: usize = options.axis;
    const b = 1 - a;
    const origin = [2]f32{ box.x0, box.y0 };
    const extent = [2]f32{ box.x1 - box.x0, box.y1 - box.y0 };
    var line: usize = 0;
    var cross: f32 = 0;
    var widest: f32 = 0;
    while (line < items.len) {
        var end = line;
        var used: f32 = 0;
        var height: f32 = 0;
        while (end < items.len) : (end += 1) {
            const next = used + (if (end > line) options.gap[a] else 0) + items[end].size[a];
            if (end > line and (items[end].break_before or next > extent[a])) break;
            used = next;
            height = @max(height, items[end].size[b]);
        }
        const space = distribute(@max(extent[a] - used, 0), end - line, options.distribution);
        var main = space.before;
        for (line..end) |i| {
            var pos = origin;
            pos[a] += main;
            pos[b] += cross + (height - items[i].size[b]) * options.cross_factor;
            out[i] = make(pos[0], pos[1], items[i].size[0], items[i].size[1]);
            main += items[i].size[a] + options.gap[a] + space.between;
        }
        widest = @max(widest, used);
        cross += height + options.gap[b];
        line = end;
    }
    var result: [2]f32 = @splat(0);
    result[a] = widest;
    result[b] = @max(cross - options.gap[b], 0);
    return result;
}

fn distribute(free: f32, count: usize, mode: Distribution) struct { before: f32 = 0, between: f32 = 0 } {
    const n: f32 = @floatFromInt(count);
    return switch (mode) {
        .start => .{},
        .center => .{ .before = free * 0.5 },
        .end => .{ .before = free },
        .space_between => .{ .between = if (count > 1) free / (n - 1) else 0 },
        .space_around => .{ .before = free / (2 * @max(n, 1)), .between = free / @max(n, 1) },
        .space_evenly => .{ .before = free / (n + 1), .between = free / (n + 1) },
    };
}

pub const FlexItem = struct {
    size: [2]f32,
    /// Main-axis basis; null is the measured size. Distinct from min/max and grow weight.
    basis: ?f32 = null,
    min: [2]f32 = @splat(0),
    max: [2]f32 = @splat(std.math.floatMax(f32)),
    grow: f32 = 0,
    shrink: f32 = 1,
    margin: [4]f32 = @splat(0),
    auto_margin: [4]bool = @splat(false),
    cross: ?f32 = null,
    stretch: bool = false,
    baseline: ?f32 = null,
};
pub const Flex = struct { axis: u1 = 0, gap: f32 = 0, distribution: Distribution = .start, cross: f32 = 0, baseline: bool = false };

/// One flex line with explicit basis, bounded water filling, auto margins and baseline
/// alignment. The maximum pass count equals item count: each nonfinal pass freezes at least
/// one item at a constraint. `sizes` is caller scratch. Wrap via flow/line partitions first.
pub fn flex(box: Rect, items: []const FlexItem, options: Flex, sizes: []f32, out: []Placement) Error!void {
    if (out.len < items.len or sizes.len < items.len) return error.NoSpace;
    try check(box, &.{}, out);
    if (!std.math.isFinite(options.gap) or options.gap < 0) return error.InvalidGeometry;
    const a: usize = options.axis;
    const b = 1 - a;
    const extent = [2]f32{ box.x1 - box.x0, box.y1 - box.y0 };
    const origin = [2]f32{ box.x0, box.y0 };
    var used = options.gap * @as(f32, @floatFromInt(items.len -| 1));
    var auto: usize = 0;
    var base_line: f32 = 0;
    for (items, 0..) |item, i| {
        for (item.size ++ item.min ++ item.max ++ item.margin ++ [3]f32{ item.basis orelse item.size[a], item.grow, item.shrink }) |v| if (!std.math.isFinite(v)) return error.InvalidGeometry;
        if (item.min[0] < 0 or item.min[1] < 0 or item.max[0] < item.min[0] or item.max[1] < item.min[1] or item.grow < 0 or item.shrink < 0) return error.InvalidGeometry;
        sizes[i] = std.math.clamp(item.basis orelse item.size[a], item.min[a], item.max[a]);
        used += sizes[i] + (if (item.auto_margin[a]) 0 else item.margin[a]) + (if (item.auto_margin[a + 2]) 0 else item.margin[a + 2]);
        auto += @as(usize, @intFromBool(item.auto_margin[a])) + @intFromBool(item.auto_margin[a + 2]);
        base_line = @max(base_line, (item.baseline orelse item.size[b]) + item.margin[b]);
    }
    var free = extent[a] - used;
    for (0..items.len) |_| {
        var weight: f32 = 0;
        for (items, sizes[0..items.len]) |item, value| {
            if (free > 0 and value < item.max[a]) weight += item.grow;
            if (free < 0 and value > item.min[a]) weight += item.shrink * @max(item.basis orelse item.size[a], 0);
        }
        if (weight == 0 or @abs(free) <= 0.0001) break;
        var spent: f32 = 0;
        for (items, sizes[0..items.len]) |item, *value| {
            const factor = if (free > 0 and value.* < item.max[a]) item.grow else if (free < 0 and value.* > item.min[a]) item.shrink * @max(item.basis orelse item.size[a], 0) else 0;
            const next = std.math.clamp(value.* + free * factor / weight, item.min[a], item.max[a]);
            spent += next - value.*;
            value.* = next;
        }
        free -= spent;
    }
    const auto_space = if (auto > 0) @max(free, 0) / @as(f32, @floatFromInt(auto)) else 0;
    const spaces = distribute(if (auto > 0) 0 else @max(free, 0), items.len, options.distribution);
    var cursor = spaces.before;
    for (items, sizes[0..items.len], out[0..items.len]) |item, main_size, *p| {
        cursor += if (item.auto_margin[a]) auto_space else item.margin[a];
        var size = item.size;
        size[a] = main_size;
        if (item.stretch) size[b] = @max(extent[b] - item.margin[b] - item.margin[b + 2], 0);
        size[b] = std.math.clamp(size[b], item.min[b], item.max[b]);
        var pos = origin;
        pos[a] += cursor;
        const cross_space = @max(extent[b] - size[b] - item.margin[b] - item.margin[b + 2], 0);
        pos[b] += if (item.auto_margin[b] and item.auto_margin[b + 2]) cross_space * 0.5 else if (item.auto_margin[b]) cross_space else if (options.baseline and item.cross == null) base_line - (item.baseline orelse size[b]) else item.margin[b] + cross_space * (item.cross orelse options.cross);
        p.* = make(pos[0], pos[1], size[0], size[1]);
        cursor += main_size + (if (item.auto_margin[a + 2]) auto_space else item.margin[a + 2]) + options.gap + spaces.between;
    }
}

test "special layouts lower into ordinary node layout and preserve dependent placement" {
    const mem = @import("../core/mem.zig");
    const tree = @import("../core/tree.zig");
    const texts = @import("../core/texts.zig");
    const layout = @import("layout.zig");
    const box: Rect = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 };
    const items = [_]Item{ .{ .size = .{ 100, 10 } }, .{ .size = .{ 20, 80 } }, .{ .size = .{ 1, 1 } } };
    var p: [8]Placement = undefined;
    const remaining = try dock(box, &items, &.{ .top, .left, .fill }, 2, &p);
    try std.testing.expectEqual(Rect{ .x0 = 22, .y0 = 12, .x1 = 100, .y1 = 100 }, remaining);
    var storage: [32768]u8 align(64) = undefined;
    var carver: mem.Carver = .{ .buf = &storage };
    var t = tree.Tree.init(&carver, 8);
    var tx = texts.Texts.init(&carver, 8);
    const root = t.push(0, .none, &.{ .size = .{ .px(100), .px(100) } });
    for (p[0..3]) |placement| {
        const node = t.push(root, .none, &style(placement, .{}, .{ 0, 0 }));
        t.seal(node);
    }
    t.seal(root);
    layout.run(&t, &tx, .{ 100, 100 });
    try std.testing.expectEqual(remaining.x0, t.c.pos[0][root + 3]);
    try std.testing.expectEqual(78, t.c.size[0][root + 3]);
    const tiles: [4]Item = .{ .{ .size = .{ 40, 30 } }, .{ .size = .{ 40, 10 } }, .{ .size = .{ 40, 20 } }, .{ .size = .{ 80, 5 }, .span = 2 } };
    var heights: [2]f32 = undefined;
    const height = try masonry(box, &tiles, 2, .{ 2, 2 }, &heights, &p);
    try std.testing.expectEqual(34, p[3].rect.y0);
    try std.testing.expectEqual(39, height);
    _ = try flow(box, &tiles, .{ .gap = .{ 2, 3 }, .distribution = .space_between }, &p);
    try std.testing.expectEqual(60, p[1].rect.x0);
    try radial(tiles[0..2], .{ .center = .{ 50, 50 }, .radius = .{ 20, 20 }, .start = 0 }, &p);
    try std.testing.expectApproxEqAbs(@as(f32, 50), p[0].rect.x0, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), p[1].rect.x0, 0.001);
}

test "bounded flex bases freeze repeatedly and auto margins absorb remaining space" {
    var p: [3]Placement = undefined;
    var scratch: [3]f32 = undefined;
    const box: Rect = .{ .x0 = 0, .y0 = 0, .x1 = 300, .y1 = 50 };
    const items: [3]FlexItem = .{
        .{ .size = .{ 10, 10 }, .basis = 0, .grow = 1, .max = .{ 20, 50 } },
        .{ .size = .{ 10, 20 }, .basis = 0, .grow = 1, .max = .{ 80, 50 } },
        .{ .size = .{ 10, 10 }, .basis = 0, .grow = 1, .stretch = true },
    };
    try flex(box, &items, .{}, &scratch, &p);
    try std.testing.expectEqualSlices(f32, &.{ 20, 80, 200 }, &scratch);
    try std.testing.expectEqual(50, p[2].rect.y1);
    try flex(box, &.{ .{ .size = .{ 20, 10 } }, .{ .size = .{ 20, 10 }, .auto_margin = .{ true, false, false, false } } }, .{}, &scratch, &p);
    try std.testing.expectEqual(280, p[1].rect.x0);
}
