//! Optional ornamental text passes. Flattened native paths become tangent-aligned glyph
//! quads; measured initials reserve actual line widths; optical margins update the same
//! Lines.x used by glyph emission, caret queries and selection. Caller owns all buffers.

const std = @import("std");
const paths = @import("../../draw/paths.zig");
const draw = @import("../../draw/draw_list.zig");
const lines = @import("lines.zig");
const Image = @import("emit.zig").Image;
const Box = @import("inline_objects.zig").Box;
const utf8 = @import("../unicode/utf8.zig");
pub const Error = error{ NoSpace, InvalidInput, EmptyPath };

pub const Segment = struct { from: [2]f32, tangent: [2]f32, start: f32, end: f32 };
pub const Track = struct { segments: []const Segment, length: f32, closed: bool };

/// Precompute lengths for one native flattened contour. Degenerate edges are omitted;
/// a contour consisting entirely of coincident points reports EmptyPath.
pub fn track(polyline: *const paths.Polyline, contour: u32, out: []Segment) Error!Track {
    if (contour >= polyline.contours or polyline.contours > polyline.end.len or polyline.contours > polyline.closed.len or polyline.points > polyline.x.len or polyline.points > polyline.y.len) return error.InvalidInput;
    const first = if (contour == 0) 0 else polyline.end[contour - 1];
    const end = polyline.end[contour];
    if (first >= end or end > polyline.points) return error.EmptyPath;
    var n: usize = 0;
    var distance: f32 = 0;
    for (first..end) |i| {
        if (!finite(polyline.x[i]) or !finite(polyline.y[i])) return error.InvalidInput;
        if (i + 1 == end and !polyline.closed[contour]) break;
        const next = if (i + 1 == end) first else i + 1;
        if (!finite(polyline.x[next]) or !finite(polyline.y[next])) return error.InvalidInput;
        const dx = polyline.x[next] - polyline.x[i];
        const dy = polyline.y[next] - polyline.y[i];
        const length = @sqrt(dx * dx + dy * dy);
        if (!finite(length) or !finite(distance + length)) return error.InvalidInput;
        if (length == 0) continue;
        if (n == out.len) return error.NoSpace;
        out[n] = .{ .from = .{ polyline.x[i], polyline.y[i] }, .tangent = .{ dx / length, dy / length }, .start = distance, .end = distance + length };
        n += 1;
        distance += length;
    }
    if (n == 0) return error.EmptyPath;
    return .{ .segments = out[0..n], .length = distance, .closed = polyline.closed[contour] };
}
fn finite(value: f32) bool {
    return std.math.isFinite(value);
}

pub const Item = struct {
    /// Already shaped and bidi-positioned pen distance along the line. Logical glyph order
    /// is preserved; this is not a second shaper and never splits/reorders a cluster.
    distance: f32,
    advance: f32,
    offset: [2]f32 = .{ 0, 0 },
    cluster: u32 = 0,
    span: u32 = 0,
};
pub fn fromLine(g: *const lines.Glyphs, l: *const lines.Lines, line: u32, out: []Item) Error![]const Item {
    if (line >= l.len or l.first[line] > l.ink[line] or l.ink[line] > g.len) return error.InvalidInput;
    const count = l.ink[line] - l.first[line];
    if (out.len < count) return error.NoSpace;
    for (l.first[line]..l.ink[line], 0..) |i, row| out[row] = .{ .distance = g.x[i], .advance = g.advance[i], .offset = .{ g.x_offset[i], -g.y_offset[i] }, .cluster = g.cluster[i], .span = g.span[i] };
    return out[0..count];
}
pub const PathOptions = struct {
    offset: f32 = 0,
    /// Alignment inside the track, 0=start, 0.5=center, 1=end.
    factor: f32 = 0,
    baseline_offset: f32 = 0,
    reverse: bool = false,
    /// wrap is legal only for a closed contour. hidden hides glyphs whose advance midpoint
    /// is outside the track; extrapolate follows the endpoint tangent beyond either end.
    overflow: enum { hidden, extrapolate, wrap } = .hidden,
};
pub const Position = struct { pen: [2]f32, tangent: [2]f32, cluster: u32, span: u32, visible: bool };

fn sample(path: Track, distance: f32) struct { point: [2]f32, tangent: [2]f32 } {
    var lo: usize = 0;
    var hi = path.segments.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (path.segments[mid].start <= distance) lo = mid else hi = mid;
    }
    const s = path.segments[lo];
    const along = distance - s.start;
    return .{ .point = .{ s.from[0] + s.tangent[0] * along, s.from[1] + s.tangent[1] * along }, .tangent = s.tangent };
}

/// Map each glyph's advance midpoint to a path tangent; offsets (including combining marks)
/// rotate in that tangent's coordinate system. Positions remain separate from atlas images.
pub fn onPath(path: Track, items: []const Item, options: PathOptions, out: []Position) Error![]const Position {
    if (path.segments.len == 0 or !finite(path.length) or path.length <= 0 or !finite(options.offset) or !finite(options.baseline_offset) or !finite(options.factor) or options.factor < 0 or options.factor > 1 or (options.overflow == .wrap and !path.closed)) return error.InvalidInput;
    if (out.len < items.len) return error.NoSpace;
    var extent: f32 = 0;
    for (items) |item| {
        if (!finite(item.distance) or !finite(item.advance) or !finite(item.offset[0]) or !finite(item.offset[1])) return error.InvalidInput;
        extent = @max(extent, item.distance + item.advance);
    }
    const origin = options.offset + (path.length - extent) * options.factor;
    for (items, out[0..items.len]) |item, *position| {
        var distance = origin + item.distance + item.advance * 0.5;
        const visible = options.overflow != .hidden or (distance >= 0 and distance <= path.length);
        if (options.overflow == .wrap) distance = @mod(distance, path.length);
        if (options.reverse) distance = path.length - distance;
        const at = sample(path, distance);
        const sign: f32 = if (options.reverse) -1 else 1;
        const tangent = [2]f32{ at.tangent[0] * sign, at.tangent[1] * sign };
        const x = item.offset[0] - item.advance * 0.5;
        const y = item.offset[1] + options.baseline_offset;
        position.* = .{ .pen = .{ at.point[0] + tangent[0] * x - tangent[1] * y, at.point[1] + tangent[1] * x + tangent[0] * y }, .tangent = tangent, .cluster = item.cluster, .span = item.span, .visible = visible };
    }
    return out[0..items.len];
}

/// Ordinary text-material quads, with tangent and TextRun transforms composed. Colours are
/// optional authored span colours; empty uses the already effective run colour.
pub fn pathQuads(run: draw.TextRun, positions: []const Position, images: []const Image, colors: []const u32, out: []draw.Quad) Error!u32 {
    if (images.len < positions.len) return error.NoSpace;
    var n: u32 = 0;
    for (positions, images[0..positions.len]) |position, image| {
        if (!position.visible or image.bounds[0] >= image.bounds[2] or image.bounds[1] >= image.bounds[3]) continue;
        if (n == out.len or (colors.len != 0 and position.span >= colors.len)) return error.NoSpace;
        const m = run.xform;
        const c = position.tangent[0];
        const s = position.tangent[1];
        const x = run.rect[0] + position.pen[0];
        const y = run.rect[1] + position.pen[1];
        var color = run.color;
        if (colors.len != 0) {
            var value: @import("../../core/types.zig").Color = @bitCast(colors[position.span]);
            value.a = @intFromFloat(@round(@as(f32, @floatFromInt(value.a)) * std.math.clamp(run.opacity, 0, 1)));
            color = @bitCast(value);
        }
        out[n] = .{ .rect = image.bounds, .clip = run.clip, .params = @splat(0), .uv = image.uv, .radii = @splat(0), .fill = color, .border_color = 0, .border = 0, .opacity = 1, .xform = .{ m[0] * c + m[2] * s, m[1] * c + m[3] * s, m[2] * c - m[0] * s, m[3] * c - m[1] * s, m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5] }, .clip_radii = run.clip_radii };
        n += 1;
    }
    return n;
}

pub const DropOptions = struct { side: enum { start, end } = .start, rtl: bool = false, gap: f32 = 0, top: f32 = 0 };
pub const Drop = struct { initial: [4]f32, widths: []const f32, origins: []const f32 };

/// A measured initial alongside a paragraph with a fixed line-height. Pass widths to both
/// break_policy.Options and Lines.Align, then applyOrigins after placement/reordering. For
/// variable-height paragraphs use dropBands with the caller's actual line top/bottom bands.
pub fn dropCap(initial: Box, paragraph_width: f32, line_height: f32, options: DropOptions, widths: []f32, origins: []f32) Error!Drop {
    if (!finite(line_height) or line_height <= 0 or !finite(options.top) or options.top < 0 or !finite(initial.height)) return error.InvalidInput;
    const affected = @ceil((options.top + initial.height) / line_height);
    if (!finite(affected) or affected > @as(f32, @floatFromInt(@min(widths.len, origins.len)))) return error.NoSpace;
    const count: usize = @intFromFloat(@max(affected, 0));
    try validateDrop(initial, paragraph_width, options);
    const left = (options.side == .start) != options.rtl;
    const reserve = @min(initial.width + options.gap, paragraph_width);
    for (0..count) |i| {
        const overlaps = @as(f32, @floatFromInt(i + 1)) * line_height > options.top;
        widths[i] = paragraph_width - (if (overlaps) reserve else 0);
        origins[i] = if (overlaps and left) reserve else 0;
    }
    const x = if (left) @as(f32, 0) else paragraph_width - initial.width;
    return .{ .initial = .{ x, options.top, x + initial.width, options.top + initial.height }, .widths = widths[0..count], .origins = origins[0..count] };
}

pub fn dropBands(initial: Box, paragraph_width: f32, bands: []const [2]f32, options: DropOptions, widths: []f32, origins: []f32) Error!Drop {
    try validateDrop(initial, paragraph_width, options);
    if (widths.len < bands.len or origins.len < bands.len) return error.NoSpace;
    const left = (options.side == .start) != options.rtl;
    const reserve = @min(initial.width + options.gap, paragraph_width);
    for (bands, 0..) |band, i| {
        if (!finite(band[0]) or !finite(band[1]) or band[1] < band[0] or (i > 0 and band[0] < bands[i - 1][1])) return error.InvalidInput;
        const overlaps = band[0] < options.top + initial.height and band[1] > options.top;
        widths[i] = paragraph_width - (if (overlaps) reserve else 0);
        origins[i] = if (overlaps and left) reserve else 0;
    }
    const x = if (left) @as(f32, 0) else paragraph_width - initial.width;
    return .{ .initial = .{ x, options.top, x + initial.width, options.top + initial.height }, .widths = widths[0..bands.len], .origins = origins[0..bands.len] };
}
fn validateDrop(initial: Box, width: f32, options: DropOptions) Error!void {
    if (!finite(width) or width < 0 or !finite(initial.width) or initial.width < 0 or !finite(initial.height) or initial.height < 0 or !finite(initial.baseline) or initial.baseline < 0 or initial.baseline > initial.height or !finite(options.gap) or options.gap < 0 or !finite(options.top)) return error.InvalidInput;
}
pub fn applyOrigins(l: *lines.Lines, origins: []const f32) Error!void {
    const count = @min(l.len, origins.len);
    for (origins[0..count]) |x| if (!finite(x)) return error.InvalidInput;
    for (l.x[0..count], origins[0..count]) |*x, offset| x.* += offset;
}

pub const Punctuation = struct {
    /// Host policy can replace these UTF-8 scalar lists for language-specific typography.
    left: []const u21 = &.{ '"', '\'', '(', '[', '{', 0x2018, 0x201c, 0x3008, 0x300a, 0x300c, 0x300e, 0x3010 },
    right: []const u21 = &.{ '"', '\'', '.', ',', ':', ';', '!', '?', ')', ']', '}', 0x2019, 0x201d, 0x3001, 0x3002, 0x3009, 0x300b, 0x300d, 0x300f, 0x3011 },
    fraction: f32 = 0.5,
};
pub const Margin = struct { left: f32 = 0, right: f32 = 0 };

/// Measure visual edge punctuation after bidi placement. Multi-glyph clusters are treated
/// as one unit. This pass changes neither source indices nor glyph advances.
pub fn opticalMargins(l: *const lines.Lines, g: *const lines.Glyphs, text: []const u8, policy: Punctuation, out: []Margin) Error![]const Margin {
    if (!finite(policy.fraction) or policy.fraction < 0 or policy.fraction > 1) return error.InvalidInput;
    if (out.len < l.len) return error.NoSpace;
    for (0..l.len) |row| {
        out[row] = .{};
        if (l.first[row] >= l.ink[row]) continue;
        var left = l.first[row];
        var right = left;
        for (l.first[row]..l.ink[row]) |i| {
            if (g.x[i] < g.x[left]) left = @intCast(i);
            if (g.x[i] + g.advance[i] > g.x[right] + g.advance[right]) right = @intCast(i);
        }
        var left_advance: f32 = 0;
        var right_advance: f32 = 0;
        for (l.first[row]..l.ink[row]) |i| {
            if (g.cluster[i] == g.cluster[left]) left_advance += g.advance[i];
            if (g.cluster[i] == g.cluster[right]) right_advance += g.advance[i];
        }
        if (std.mem.indexOfScalar(u21, policy.left, utf8.decode(text, g.cluster[left]).cp) != null) out[row].left = @max(left_advance, 0) * policy.fraction;
        if (std.mem.indexOfScalar(u21, policy.right, utf8.decode(text, g.cluster[right]).cp) != null) out[row].right = @max(right_advance, 0) * policy.fraction;
    }
    return out[0..l.len];
}

/// Align the optical body, retaining existing line breaks. `factors` are the resolved
/// physical alignment factors for each line (0 left, .5 centre, 1 right), not bidi guesses.
/// This is suitable for headings/ragged text; justified rebreaking remains a separate pass.
pub fn hang(l: *lines.Lines, margins: []const Margin, factors: []const f32) Error!void {
    if (margins.len < l.len or factors.len < l.len) return error.NoSpace;
    for (margins[0..l.len], factors[0..l.len]) |margin, factor| if (!finite(margin.left) or !finite(margin.right) or margin.left < 0 or margin.right < 0 or !finite(factor) or factor < 0 or factor > 1) return error.InvalidInput;
    for (l.x[0..l.len], margins[0..l.len], factors[0..l.len]) |*x, margin, factor| x.* += factor * (margin.left + margin.right) - margin.left;
}

test "shaped line follows native path tangents and retains transform opacity clipping" {
    var columns: paths.TestBuffers(8, 64) = .{};
    var path = columns.path();
    path.moveTo(0, 0);
    path.lineTo(20, 0);
    path.lineTo(20, 40);
    var polyline = columns.polyline();
    paths.flatten(&path, 0.1, &polyline);
    var segments: [8]Segment = undefined;
    const route = try track(&polyline, 0, &segments);
    var paragraph: @import("golden.zig").Para = .{};
    paragraph.fixed("abc", 10);
    try lines.breakLines(&paragraph.g, "abc", 100, &paragraph.l);
    lines.place(&paragraph.l, &paragraph.g, "abc", &.{.{ .ascent = 8, .descent = 2 }}, .{});
    var items: [3]Item = undefined;
    var positions: [3]Position = undefined;
    const placed = try onPath(route, try fromLine(&paragraph.g, &paragraph.l, 0, &items), .{}, &positions);
    try std.testing.expectEqual([2]f32{ 1, 0 }, placed[0].tangent);
    try std.testing.expectEqual([2]f32{ 0, 1 }, placed[2].tangent);
    const run: draw.TextRun = .{ .rect = .{ 100, 50, 200, 100 }, .clip = .{ 90, 40, 200, 200 }, .start = 0, .bytes = 3, .px = 10, .font = 0, .color = 0xffffffff, .opacity = 0.5, .xform = .{ 2, 0, 0, 2, 3, 4 }, .clip_radii = .{ 1, 2, 3, 4 } };
    const images: [3]Image = @splat(.{ .bounds = .{ 0, -8, 8, 2 } });
    var quads: [3]draw.Quad = undefined;
    try std.testing.expectEqual(@as(u32, 3), try pathQuads(run, placed, &images, &.{0xffffffff}, &quads));
    try std.testing.expectEqual([6]f32{ 0, 2, -2, 0, 243, 104 }, quads[2].xform);
    const color: @import("../../core/types.zig").Color = @bitCast(quads[0].fill);
    try std.testing.expectEqual(@as(u8, 128), color.a);
    try std.testing.expectEqual(run.clip_radii, quads[0].clip_radii);
    try std.testing.expectError(error.InvalidInput, onPath(route, &items, .{ .overflow = .wrap }, &positions));
}

test "drop cap changes real line breaks positions and caret coordinates in both directions" {
    const policy = @import("break_policy.zig");
    const query = @import("query.zig");
    const text = "abcdefgh";
    var p: @import("golden.zig").Para = .{};
    p.fixed(text, 10);
    var widths: [4]f32 = undefined;
    var origins: [4]f32 = undefined;
    const initial: Box = .{ .width = 25, .height = 20, .baseline = 16 };
    const drop = try dropCap(initial, 60, 10, .{ .gap = 5 }, &widths, &origins);
    var opportunities: [10]policy.Opportunity = undefined;
    const points = try policy.opportunities(&p.g, text, .{ .word = .grapheme }, &.{}, &opportunities);
    var prefix: [10]f32 = undefined;
    var cost: [10]f64 = undefined;
    var previous: [10]u32 = undefined;
    var choices: [10]u32 = undefined;
    var markers: [10]policy.Marker = undefined;
    try policy.breakLines(&p.g, text, points, .{ .width = 60, .line_widths = drop.widths }, .{ .prefix = &prefix, .cost = &cost, .previous = &previous, .choices = &choices }, &p.l, &markers);
    lines.place(&p.l, &p.g, text, &.{.{ .ascent = 8, .descent = 2 }}, .{ .width = 60, .line_widths = drop.widths });
    try applyOrigins(&p.l, drop.origins);
    try std.testing.expectEqualSlices(u32, &.{ 3, 6, 8 }, p.l.end[0..p.l.len]);
    try std.testing.expectEqual(@as(f32, 30), query.caret(&p.l, &p.g, text, 0).x);
    try std.testing.expectEqual(@as(f32, 0), query.caret(&p.l, &p.g, text, 6).x);
    const rtl = try dropCap(initial, 60, 10, .{ .rtl = true, .gap = 5 }, &widths, &origins);
    try std.testing.expectEqual(@as(f32, 35), rtl.initial[0]);
    try std.testing.expectEqual(@as(f32, 0), rtl.origins[0]);
}

test "hanging edge punctuation moves glyphs and carets together without splitting clusters" {
    const query = @import("query.zig");
    const text = "\"hello!";
    var p: @import("golden.zig").Para = .{};
    p.fixed(text, 10);
    try lines.breakLines(&p.g, text, 100, &p.l);
    lines.place(&p.l, &p.g, text, &.{.{ .ascent = 8, .descent = 2 }}, .{ .width = 100 });
    var margins: [1]Margin = undefined;
    _ = try opticalMargins(&p.l, &p.g, text, .{}, &margins);
    try std.testing.expectEqual(Margin{ .left = 5, .right = 5 }, margins[0]);
    try hang(&p.l, &margins, &.{0});
    try std.testing.expectEqual(@as(f32, -5), query.caret(&p.l, &p.g, text, 0).x);
    try std.testing.expectEqual(@as(f32, 10), p.g.advance[0]);
}
