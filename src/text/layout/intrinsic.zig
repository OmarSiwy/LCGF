//! Intrinsic sizes from real shaped glyph advances. These are explicit measurement results
//! which lower to existing Size/min/max inputs; applications may cache them by their own
//! text/font/configuration generation. No layout callback or font registry is introduced.

const std = @import("std");
const lines = @import("lines.zig");
const utf8 = @import("../unicode/utf8.zig");
const Breaks = @import("../unicode/line.zig").LineBreaks;
const Size = @import("../../core/types.zig").Size;

pub const Range = struct { min_content: f32, max_content: f32 };
pub const Options = struct {
    /// break_word retains ordinary word-based min-content; anywhere permits every shaped
    /// grapheme boundary. none gives an unbreakable paragraph between mandatory breaks.
    wrap: enum { word, break_word, anywhere, none } = .word,
    tab_width: f32 = 0,
};
pub const Kind = enum { min_content, max_content, fit_content };
pub const Error = error{InvalidMeasure};

fn hard(cp: u21) bool {
    return cp == '\n' or cp == '\r' or cp == 0x85 or cp == 0x2028 or cp == 0x2029;
}

/// Whitespace normalization/casing happens before shaping. Clusters must be monotonic and
/// already coarsened to graphemes. Hanging trailing spaces do not inflate either intrinsic
/// width; no-break spaces remain ink/advance, and explicit newlines split max-content lines.
pub fn text(g: *const lines.Glyphs, bytes: []const u8, options: Options) Error!Range {
    if (!std.math.isFinite(options.tab_width) or options.tab_width < 0) return error.InvalidMeasure;
    var result: Range = .{ .min_content = 0, .max_content = 0 };
    var max_pen: f32 = 0;
    var max_ink: f32 = 0;
    var min_pen: f32 = 0;
    var min_ink: f32 = 0;
    var iterator: Breaks = .{ .text = bytes };
    var next = iterator.next();
    var i: u32 = 0;
    while (i < g.len) {
        var end = i + 1;
        while (end < g.len and g.cluster[end] == g.cluster[i]) end += 1;
        const cp = utf8.decode(bytes, g.cluster[i]).cp;
        const at: u32 = if (end < g.len) g.cluster[end] else @intCast(bytes.len);
        var advance: f32 = 0;
        for (g.advance[i..end]) |value| {
            if (!std.math.isFinite(value)) return error.InvalidMeasure;
            advance += value;
        }
        if (hard(cp) or cp == 0xad) advance = 0;
        const tab = cp == '\t' and options.tab_width > 0;
        max_pen += if (tab) (@floor(max_pen / options.tab_width) + 1) * options.tab_width - max_pen else advance;
        min_pen += if (tab) (@floor(min_pen / options.tab_width) + 1) * options.tab_width - min_pen else advance;
        if (!lines.isSpace(bytes, g.cluster[i]) and cp != 0xad) {
            max_ink = max_pen;
            min_ink = min_pen;
        }
        while (next != null and next.?.pos < at) next = iterator.next();
        const ordinary = next != null and next.?.pos == at;
        const mandatory = end == g.len or hard(cp) or (ordinary and next.?.mandatory);
        const optional = options.wrap == .anywhere or ((options.wrap == .word or options.wrap == .break_word) and ordinary);
        if (mandatory or optional) {
            result.min_content = @max(result.min_content, min_ink);
            min_pen = 0;
            min_ink = 0;
        }
        if (mandatory) {
            result.max_content = @max(result.max_content, max_ink);
            max_pen = 0;
            max_ink = 0;
        }
        i = end;
    }
    return result;
}

/// Explicit dictionary/soft-hyphen opportunities can supply a more detailed min-content
/// measure. Emergency-only candidates affect intrinsic width only when anywhere is true.
pub fn fromOpportunities(g: *const lines.Glyphs, points: []const @import("break_policy.zig").Opportunity, anywhere: bool) Range {
    var result: Range = .{ .min_content = 0, .max_content = 0 };
    var start: u32 = 0;
    var mandatory_start: u32 = 0;
    for (points) |point| {
        if (point.end == 0) continue;
        if (!point.emergency or anywhere) {
            var width = point.marker;
            for (g.advance[start..@max(start, point.ink)]) |a| width += a;
            result.min_content = @max(result.min_content, width);
            start = point.end;
        }
        if (point.mandatory) {
            var width: f32 = 0;
            for (g.advance[mandatory_start..@max(mandatory_start, point.ink)]) |a| width += a;
            result.max_content = @max(result.max_content, width);
            mandatory_start = point.end;
        }
    }
    return result;
}

/// fit-content = min(max-content, max(min-content, available)). Author minimum/maximum
/// constraints still belong to the ordinary Style and are applied by native layout.
pub fn size(range: Range, kind: Kind, available: f32) Error!Size {
    if (!std.math.isFinite(range.min_content) or !std.math.isFinite(range.max_content) or range.min_content < 0 or range.max_content < range.min_content) return error.InvalidMeasure;
    if (kind == .fit_content and (!std.math.isFinite(available) or available < 0)) return error.InvalidMeasure;
    return .px(switch (kind) {
        .min_content => range.min_content,
        .max_content => range.max_content,
        .fit_content => @min(range.max_content, @max(range.min_content, available)),
    });
}

/// Intrinsic contribution of already-measured child boxes, for custom row/column/overlay
/// measurement. `stacked` adds contributions; a cross axis takes their maximum. Gap and
/// outer padding are explicit, so the caller can use different row and column gaps.
pub fn boxes(children: []const Range, stacked: bool, gap: f32, padding: f32) Error!Range {
    if (!std.math.isFinite(gap) or !std.math.isFinite(padding) or gap < 0 or padding < 0) return error.InvalidMeasure;
    var result: Range = .{ .min_content = 0, .max_content = 0 };
    for (children) |child| {
        _ = try size(child, .min_content, 0);
        if (stacked) {
            result.min_content += child.min_content;
            result.max_content += child.max_content;
        } else {
            result.min_content = @max(result.min_content, child.min_content);
            result.max_content = @max(result.max_content, child.max_content);
        }
    }
    const extra = padding + if (stacked) gap * @as(f32, @floatFromInt(children.len -| 1)) else 0;
    result.min_content += extra;
    result.max_content += extra;
    return result;
}

test "intrinsic widths distinguish unbreakable words anywhere tabs and fit content in real layout" {
    const golden = @import("golden.zig");
    var p: golden.Para = .{};
    p.fixed("one three\nx", 10);
    const range = try text(&p.g, "one three\nx", .{});
    try std.testing.expectEqual(Range{ .min_content = 50, .max_content = 90 }, range);
    try std.testing.expectEqual(@as(f32, 10), (try text(&p.g, "one three\nx", .{ .wrap = .anywhere })).min_content);
    try std.testing.expectEqual(@as(f32, 90), (try text(&p.g, "one three\nx", .{ .wrap = .none })).min_content);
    p.fixed("one\u{a0}two", 10);
    try std.testing.expectEqual(@as(f32, 70), (try text(&p.g, "one\u{a0}two", .{})).min_content);
    p.fixed("a\tb", 10);
    try std.testing.expectEqual(Range{ .min_content = 10, .max_content = 50 }, try text(&p.g, "a\tb", .{ .tab_width = 40 }));
    const mem = @import("../../core/mem.zig");
    const Tree = @import("../../core/tree.zig").Tree;
    const Texts = @import("../../core/texts.zig").Texts;
    var storage: [16384]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &storage };
    var t: Tree = .init(&carver, 4);
    var tx: Texts = .init(&carver, 1);
    const root = t.push(0, .none, &.{});
    const node = t.push(root, .none, &.{ .size = .{ try size(range, .fit_content, 60), .px(10) } });
    t.seal(node);
    t.seal(root);
    @import("../../layout/layout.zig").run(&t, &tx, .{ 200, 50 });
    try std.testing.expectEqual(@as(f32, 60), t.c.size[0][node]);
    try std.testing.expectEqual(@as(f32, 50), (try size(range, .fit_content, 20)).v);
    try std.testing.expectEqual(@as(f32, 90), (try size(range, .fit_content, 200)).v);
}
