//! Explicit baseline and text-edge metrics over the ordinary glyph/line columns. Callers
//! can trim a paragraph's outer leading, align a span to a chosen baseline, or report its
//! last baseline to native layout without inventing a retained inline formatting context.
//! https://www.w3.org/TR/css-inline-3/#text-box-trim

const std = @import("std");
const lines = @import("lines.zig");
const opentype = @import("../font/opentype.zig");
const match = @import("../font/match.zig");
const Texts = @import("../../core/texts.zig").Texts;

pub const Error = error{ InvalidMetric, MissingMetric, InvalidRow, NoSpace };
pub const Source = enum { first, last };
pub const Font = struct {
    ascent: f32,
    descent: f32,
    em_over: f32,
    em_under: f32,
    cap_height: ?f32 = null,
    x_height: ?f32 = null,

    /// Native static-face metrics. Em edges proportionally normalize hhea ascent/descent;
    /// optional x/cap heights use OS/2 or real glyph bounds, never a guessed cap-height ratio.
    pub fn of(face: *const opentype.Face, px: f32) Error!Font {
        if (!std.math.isFinite(px) or px < 0) return error.InvalidMetric;
        const measured: lines.Metrics = .of(face, px);
        const ascent = @max(measured.ascent, 0);
        const descent = @max(measured.descent, 0);
        const total = ascent + descent;
        const over = if (total > 0) px * ascent / total else px;
        return .{ .ascent = ascent, .descent = descent, .em_over = over, .em_under = px - over, .cap_height = if (match.metricRatio(face, .cap_height)) |ratio| ratio * px else |_| null, .x_height = if (match.metricRatio(face, .x_height)) |ratio| ratio * px else |_| null };
    }
};
pub const Over = enum { font, em, cap_height, x_height, alphabetic };
pub const Under = enum { font, em, alphabetic };
pub const Trim = struct {
    /// Desired first-line edge distance above its alphabetic baseline; null keeps the edge.
    before: ?f32 = null,
    /// Desired last-line edge distance below its alphabetic baseline; null keeps the edge.
    after: ?f32 = null,
};
pub const Removed = struct { before: f32, after: f32 };

pub fn edges(font: Font, over: ?Over, under: ?Under) Error!Trim {
    const result: Trim = .{
        .before = if (over) |edge| switch (edge) {
            .font => font.ascent,
            .em => font.em_over,
            .cap_height => font.cap_height orelse return error.MissingMetric,
            .x_height => font.x_height orelse return error.MissingMetric,
            .alphabetic => 0,
        } else null,
        .after = if (under) |edge| switch (edge) {
            .font => font.descent,
            .em => font.em_under,
            .alphabetic => 0,
        } else null,
    };
    try validate(result);
    return result;
}

fn validate(value: Trim) error{InvalidMetric}!void {
    if (value.before) |distance| if (!std.math.isFinite(distance) or distance < 0) return error.InvalidMetric;
    if (value.after) |distance| if (!std.math.isFinite(distance) or distance < 0) return error.InvalidMetric;
}

/// After placement/reorder, before query/emission: removes only outside first/last leading.
/// Baseline-to-baseline distances remain unchanged. Ink may extend beyond the new box;
/// clipping is the caller's explicit overflow policy, not an accidental glyph distortion.
pub fn trim(l: *lines.Lines, value: Trim) error{InvalidMetric}!Removed {
    try validate(value);
    if (l.len == 0) return .{ .before = 0, .after = 0 };
    const last = l.len - 1;
    const before = if (value.before) |distance| std.math.clamp(l.baseline[0] - l.top[0] - distance, 0, l.height[0]) else 0;
    const remaining = @max(l.height[last] - (if (last == 0) before else 0), 0);
    const after = if (value.after) |distance| std.math.clamp(l.top[last] + l.height[last] - l.baseline[last] - distance, 0, remaining) else 0;
    for (l.top[0..l.len], l.baseline[0..l.len]) |*top, *base| {
        top.* -= before;
        base.* -= before;
    }
    l.top[0] += before;
    l.height[0] -= before;
    l.height[last] -= after;
    return .{ .before = before, .after = after };
}

pub fn baseline(l: *const lines.Lines, source: Source) f32 {
    if (l.len == 0) return 0;
    return l.baseline[if (source == .first) @as(usize, 0) else l.len - 1];
}

/// Writes the real extents and selected baseline into the existing text-measure protocol.
/// layout.baseline.apply then consumes first or last baselines using its ordinary rows.
pub fn commit(tx: *Texts, row: u32, l: *const lines.Lines, source: Source, baselines: []f32) Error!void {
    if (row >= tx.len) return error.InvalidRow;
    if (row >= baselines.len) return error.NoSpace;
    tx.c.w[row] = lines.widest(l);
    tx.c.h[row] = lines.stackHeight(l);
    baselines[row] = baseline(l, source);
}

pub const Baseline = enum { alphabetic, central, hanging, mathematical, ideographic };
/// Coordinates in logical pixels, positive above the face's alphabetic baseline. Fonts,
/// shapers or host BASE/MATH readers supply non-alphabetic values explicitly when known.
pub const Baselines = struct {
    alphabetic: f32 = 0,
    central: ?f32 = null,
    hanging: ?f32 = null,
    mathematical: ?f32 = null,
    ideographic: ?f32 = null,

    pub fn get(value: Baselines, which: Baseline) error{MissingMetric}!f32 {
        return switch (which) {
            .alphabetic => value.alphabetic,
            inline else => |tag| @field(value, @tagName(tag)) orelse return error.MissingMetric,
        };
    }
};

/// Before lines.place: align one reserved span's chosen baseline and an explicit shift.
/// Updates both glyph offsets and the metrics used for line height, so shifted scripts,
/// icons and mixed baseline conventions do not merely paint outside stale line geometry.
pub fn alignSpan(g: *lines.Glyphs, metrics: []lines.Metrics, span: u32, source: Baselines, source_kind: Baseline, target: Baselines, target_kind: Baseline, extra: f32) Error!void {
    if (span >= metrics.len) return error.InvalidRow;
    const amount = (try target.get(target_kind)) - (try source.get(source_kind)) + extra;
    if (!std.math.isFinite(amount)) return error.InvalidMetric;
    for (0..g.len) |i| if (g.span[i] == span) {
        g.y_offset[i] += amount;
    };
    metrics[span].ascent = @max(metrics[span].ascent + amount, 0);
    metrics[span].descent = @max(metrics[span].descent - amount, 0);
}

test "edge trim and selected last baselines drive glyph queries and native baseline layout" {
    const golden = @import("golden.zig");
    const mem = @import("../../core/mem.zig");
    const Tree = @import("../../core/tree.zig").Tree;
    const Flex = @import("../../layout/flex.zig").Flex;
    const layout = @import("../../layout/layout.zig");
    var paragraph: golden.Para = .{};
    paragraph.fixed("ab\ncd", 10);
    try lines.breakLines(&paragraph.g, "ab\ncd", 100, &paragraph.l);
    lines.place(&paragraph.l, &paragraph.g, "ab\ncd", &.{.{ .ascent = 12, .descent = 4, .gap = 4 }}, .{});
    const removed = try trim(&paragraph.l, .{ .before = 7, .after = 0 });
    try std.testing.expectEqual(Removed{ .before = 5, .after = 8 }, removed);
    try std.testing.expectEqual(@as(f32, 27), lines.stackHeight(&paragraph.l));
    try std.testing.expectEqual(@as(f32, 7), baseline(&paragraph.l, .first));
    try std.testing.expectEqual(@as(f32, 27), baseline(&paragraph.l, .last));
    const caret = @import("query.zig").caret(&paragraph.l, &paragraph.g, "ab\ncd", 5);
    try std.testing.expectEqual(@as(f32, 15), caret.top);
    var storage: [65536]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &storage };
    var tree: Tree = .init(&carver, 4);
    var tx: Texts = .init(&carver, 2);
    var flex: Flex = .init(&carver, 4);
    const root = tree.push(0, .none, &.{ .dir = .x });
    flex.set(root, &.{ .baseline = true });
    const a = tree.push(root, .none, &.{});
    tree.c.text[a] = tx.push(a, .{ .start = 0, .bytes = 5 }, &.{});
    tree.seal(a);
    const b = tree.push(root, .none, &.{});
    tree.c.text[b] = tx.push(b, .{ .start = 0, .bytes = 1 }, &.{});
    tree.seal(b);
    tree.seal(root);
    var baselines: [2]f32 = undefined;
    try commit(&tx, 0, &paragraph.l, .last, &baselines);
    paragraph.fixed("x", 10);
    try lines.breakLines(&paragraph.g, "x", 100, &paragraph.l);
    lines.place(&paragraph.l, &paragraph.g, "x", &.{.{ .ascent = 8, .descent = 2 }}, .{});
    try commit(&tx, 1, &paragraph.l, .first, &baselines);
    @import("../../layout/baseline.zig").apply(&tree, &flex, &tx, &baselines);
    layout.runFlex(&tree, &flex, &tx, .{ 100, 50 });
    try std.testing.expectEqual(tree.c.pos[1][a] + baselines[0], tree.c.pos[1][b] + baselines[1]);
    const face = try opentype.Face.parse(golden.font, 0);
    const font = try Font.of(&face, 20);
    const selected = try edges(font, .cap_height, .alphabetic);
    try std.testing.expect(selected.before.? > 0 and selected.before.? < font.ascent);
    try std.testing.expectEqual(@as(?f32, 0), selected.after);
}

test "span baseline selection changes real offsets and line-height metrics" {
    var p: @import("golden.zig").Para = .{};
    p.fixed("ab", 10);
    p.g.span[1] = 1;
    var measurements = [_]lines.Metrics{ .{ .ascent = 8, .descent = 2 }, .{ .ascent = 8, .descent = 2 } };
    try alignSpan(&p.g, &measurements, 1, .{ .mathematical = 3 }, .mathematical, .{ .mathematical = 5 }, .mathematical, 1);
    try lines.breakLines(&p.g, "ab", 100, &p.l);
    lines.place(&p.l, &p.g, "ab", &measurements, .{});
    try std.testing.expectEqual(@as(f32, 3), p.g.y_offset[1]);
    try std.testing.expectEqual(@as(f32, 11), p.l.baseline[0]);
    try std.testing.expectEqual(@as(f32, 13), p.l.height[0]);
    try std.testing.expectError(error.MissingMetric, alignSpan(&p.g, &measurements, 1, .{}, .hanging, .{}, .alphabetic, 0));
}
