//! Paragraph layout: shaped glyphs broken into lines and placed. Tier 0.
//!
//! The data flow, over columns the caller owns:
//!
//!   text ──shape──► Glyphs (px) ──breakLines──► Lines ──place──► Glyphs.x, Lines.top/baseline
//!
//! `Glyphs` is one paragraph's shaped glyphs in pixels, in text order (one left-to-right run;
//! bidi reordering is not done here). `breakLines` walks the UAX #14 break opportunities of the
//! text (src/text/unicode/line.zig) and fills lines greedily: a line takes whole segments (a
//! word and the spaces after it) while the width of its ink fits; trailing spaces hang past the
//! edge and do not count. A segment wider than the width on its own is broken between clusters,
//! so no glyph is ever split. A mandatory break (newline) always ends a line.
//!
//! This is a scan over one paragraph's glyphs with a decision per segment, like shaping: it is
//! not a row pass over the tree, and its branches are on the text, not on per-node columns.
//! Ported from the role of `fonts.Mono.wrap` in prototype/ui.zig: Mono counts whole glyphs per
//! line; this breaks real advances at real opportunities.

const std = @import("std");
const shape = @import("../shape/shape.zig");
const property = @import("../unicode/property.zig");
const utf8 = @import("../unicode/utf8.zig");
const LineBreaks = @import("../unicode/line.zig").LineBreaks;

/// Widths may exceed the limit by this much and still fit: layout hands back the width it was
/// given after adding and removing padding, which can differ from it in the last bit.
pub const slack: f32 = 1.0 / 64.0;

/// A paragraph's glyphs in pixels, in text order. Capacity is the slices' length, all equal.
pub const Glyphs = struct {
    glyph: []u16,
    /// Byte offset in the paragraph's text of the first character of the glyph's cluster.
    cluster: []u32,
    /// Pen advance after the glyph, px.
    advance: []f32,
    /// Where the glyph is drawn relative to its pen position, px, y up.
    x_offset: []f32,
    y_offset: []f32,
    /// The span (style run, src/text/layout/spans.zig) the glyph was shaped in; 0 for plain text.
    span: []u32,
    /// Written by `place`: the pen x of the glyph, px from the line's left edge.
    x: []f32,
    len: u32 = 0,

    /// Appends a shaped run at `scale` px per font unit (px / units_per_em), shaped in span
    /// `span`. `base` is the byte offset of the run's text in the paragraph's text.
    pub fn append(g: *Glyphs, run: *const shape.Run, scale: f32, base: u32, span: u32) error{NoSpace}!void {
        if (g.glyph.len - g.len < run.len) return error.NoSpace;
        for (0..run.len) |k| {
            const at = g.len + k;
            g.glyph[at] = run.glyph[k];
            g.cluster[at] = base + run.cluster[k];
            g.advance[at] = @as(f32, @floatFromInt(run.advance[k])) * scale;
            g.x_offset[at] = @as(f32, @floatFromInt(run.x_offset[k])) * scale;
            g.y_offset[at] = @as(f32, @floatFromInt(run.y_offset[k])) * scale;
            g.span[at] = span;
            g.x[at] = 0;
        }
        g.len += run.len;
    }
};

/// A paragraph's lines, top to bottom. Glyph ranges are rows of `Glyphs`.
pub const Lines = struct {
    /// First glyph of the line.
    first: []u32,
    /// One past the last glyph, trailing spaces and the newline included.
    end: []u32,
    /// One past the last glyph with ink: the glyphs to draw are `first..ink`.
    ink: []u32,
    /// Byte offset of the line's text; it runs to the next line's `start` (or the text's end).
    start: []u32,
    /// Width of the ink, px: from the line's pen start to the end of its last inked glyph.
    width: []f32,
    /// 1.0 when the line ends at a mandatory break or the end of the text.
    hard: []f32,
    /// Written by `place`: left edge, top, baseline and height, px from the paragraph's top left,
    /// and the space added after each inner space of a justified line.
    x: []f32,
    top: []f32,
    baseline: []f32,
    height: []f32,
    extra: []f32,
    len: u32 = 0,
    /// Written by `ellipsize`: the advance of the ellipsis that ends the last line (counted in
    /// its `width`, drawn at `x + width - ellipsis`), 0 when the text was not cut.
    ellipsis: f32 = 0,
};

/// Where lines sit in a box `width` px wide. `factor` is 0 for the start, 0.5 for the centre,
/// 1 for the end (the factors of `types.Align`). With `justify`, every line but the last and
/// those ended by a newline fills the box: its free width is shared equally among the spaces
/// inside its ink, and `factor` applies only to the lines left alone (CSS `text-align-last`
/// is start; set `factor` for another).
pub const Align = struct {
    width: f32 = 0,
    factor: f32 = 0,
    justify: bool = false,
};

/// Vertical metrics of a font at a size, px: ascender above the baseline, descender below it
/// (positive), and the gap after a line.
pub const Metrics = struct {
    ascent: f32,
    descent: f32,
    gap: f32 = 0,

    /// The face's hhea metrics at `px` pixels per em.
    pub fn of(face: *const @import("../font/opentype.zig").Face, px: f32) Metrics {
        const s = px / @as(f32, @floatFromInt(face.units_per_em));
        return .{
            .ascent = @as(f32, @floatFromInt(face.ascender)) * s,
            .descent = -@as(f32, @floatFromInt(face.descender)) * s,
            .gap = @as(f32, @floatFromInt(face.line_gap)) * s,
        };
    }

    pub fn height(m: Metrics) f32 {
        return m.ascent + m.descent + m.gap;
    }
};

/// Breaks the glyphs of `text` (shaped from it, so clusters are offsets into it) into lines no
/// wider than `width` px. Fills `lines` from row 0; `error.NoSpace` when it has too few rows.
/// Empty text, and text ending in a newline, end with an empty line (where a caret goes).
pub fn breakLines(g: *const Glyphs, text: []const u8, width: f32, lines: *Lines) error{NoSpace}!void {
    lines.len = 0;
    const limit = width + slack;
    var first: u32 = 0; // first glyph of the open line
    var x0: f32 = 0; // pen at `first`, from the paragraph's start
    var gi: u32 = 0;
    var pen: f32 = 0; // pen at `gi`
    var it: LineBreaks = .{ .text = text };
    while (it.next()) |o| {
        // The segment: glyphs whose cluster starts before the opportunity.
        const seg = gi;
        const seg_pen = pen;
        var ink: f32 = 0;
        var inked = false;
        while (gi < g.len and g.cluster[gi] < o.pos) : (gi += 1) {
            pen += g.advance[gi];
            const space = isSpace(text, g.cluster[gi]);
            ink = if (space) ink else pen;
            inked = inked or !space;
        }
        if (inked and seg > first and ink - x0 > limit) {
            try push(lines, g, text, first, seg, false);
            first = seg;
            x0 = seg_pen;
        }
        if (inked and ink - x0 > limit) {
            // Wider than a line on its own: break between clusters.
            var k = first;
            var kp = x0;
            while (k < gi) {
                var nk = k;
                var np = kp;
                while (nk < gi and g.cluster[nk] == g.cluster[k]) : (nk += 1) np += g.advance[nk];
                if (!isSpace(text, g.cluster[k]) and k > first and np - x0 > limit) {
                    try push(lines, g, text, first, k, false);
                    first = k;
                    x0 = kp;
                }
                k = nk;
                kp = np;
            }
        }
        if (o.mandatory) {
            try push(lines, g, text, first, gi, true);
            first = gi;
            x0 = pen;
        }
    }
    if (lines.len == 0 or endsInBreak(text)) try push(lines, g, text, g.len, g.len, true);
}

fn push(lines: *Lines, g: *const Glyphs, text: []const u8, first: u32, end: u32, hard: bool) error{NoSpace}!void {
    const k = lines.len;
    if (k == lines.first.len) return error.NoSpace;
    lines.first[k] = first;
    lines.end[k] = end;
    lines.start[k] = if (first < g.len) g.cluster[first] else @intCast(text.len);
    lines.hard[k] = @floatFromInt(@intFromBool(hard));
    lines.len = k + 1;
    measure(lines, k, g, text);
}

/// Writes `ink` and `width` of line `k` from its glyphs `first..end`.
fn measure(lines: *Lines, k: usize, g: *const Glyphs, text: []const u8) void {
    var ink = lines.first[k];
    var pen: f32 = 0;
    var w: f32 = 0;
    for (lines.first[k]..lines.end[k]) |i| {
        pen += g.advance[i];
        const space = isSpace(text, g.cluster[i]);
        ink = if (space) ink else @intCast(i + 1);
        w = if (space) w else pen;
    }
    lines.ink[k] = ink;
    lines.width[k] = w;
}

/// Keeps at most `max_lines` lines (at least 1) and, when lines were dropped or the last one
/// is wider than `width`, cuts the last line to end in an ellipsis `ellipsis` px wide: whole
/// clusters are dropped from its end until its ink (trailing spaces hang, as
/// always) and the ellipsis fit, or nothing is left. The cut line becomes hard, so it is never justified.
/// Call after `breakLines` and before `place`. For text that does not wrap, break with an
/// infinite width and pass `max_lines` 1.
pub fn ellipsize(lines: *Lines, g: *const Glyphs, text: []const u8, width: f32, max_lines: u32, ellipsis: f32) void {
    std.debug.assert(lines.len > 0);
    lines.ellipsis = 0;
    const kept = @min(lines.len, @max(max_lines, 1));
    const dropped = kept < lines.len;
    lines.len = kept;
    const k = kept - 1;
    if (!dropped and lines.width[k] <= width + slack) return;
    const first = lines.first[k];
    var end = lines.ink[k];
    lines.end[k] = end;
    measure(lines, k, g, text);
    while (end > first and lines.width[k] + ellipsis > width + slack) {
        const cluster = g.cluster[end - 1];
        while (end > first and g.cluster[end - 1] == cluster) end -= 1;
        lines.end[k] = end;
        measure(lines, k, g, text);
    }
    lines.width[k] += ellipsis;
    lines.hard[k] = 1;
    lines.ellipsis = ellipsis;
}

/// Whether the character at `at` hangs at a line's end: a space or a mandatory break.
pub fn isSpace(text: []const u8, at: u32) bool {
    const lb = property.line(utf8.decode(text, at).cp).lb;
    return switch (lb) {
        .SP, .BK, .CR, .LF, .NL => true,
        else => false,
    };
}

fn endsInBreak(text: []const u8) bool {
    if (text.len == 0) return false;
    var at = text.len - 1;
    while (at > 0 and text[at] & 0xC0 == 0x80) at -= 1;
    return switch (property.line(utf8.decode(text, at).cp).lb) {
        .BK, .CR, .LF, .NL => true,
        else => false,
    };
}

/// Stacks the lines from the paragraph's top, aligns each in `a`, and writes each glyph's pen
/// x from the line's left edge. `metrics` has one row per span (`Glyphs.span`; one row for
/// plain text). A line's baseline is the largest ascent of the spans on it below its top, and
/// below that the largest descent plus gap; an empty line takes the span of the glyph before
/// it. Per line the mode is a coefficient: `j` is 1.0 for a justified line, so the offset and
/// the extra space are products, not branches.
pub fn place(lines: *Lines, g: *Glyphs, text: []const u8, metrics: []const Metrics, a: Align) void {
    std.debug.assert(metrics.len > 0);
    const justify: f32 = @floatFromInt(@intFromBool(a.justify));
    var top: f32 = 0;
    for (0..lines.len) |k| {
        const first = lines.first[k];
        const before = if (first > 0) g.span[first - 1] else 0;
        var ascent = metrics[before].ascent;
        var below = metrics[before].descent + metrics[before].gap;
        // A line with glyphs: the spans of its glyphs only.
        if (lines.end[k] > first) {
            ascent = 0;
            below = 0;
        }
        var spaces: f32 = 0;
        for (first..lines.end[k]) |i| {
            const m = metrics[g.span[i]];
            ascent = @max(ascent, m.ascent);
            below = @max(below, m.descent + m.gap);
        }
        for (first..lines.ink[k]) |i| spaces += space01(text, g.cluster[i]);
        const free = a.width - lines.width[k];
        const j = justify * (1 - lines.hard[k]) * @min(spaces, 1);
        lines.extra[k] = j * free / @max(spaces, 1);
        lines.x[k] = (1 - j) * free * a.factor;
        lines.top[k] = top;
        lines.baseline[k] = top + ascent;
        lines.height[k] = ascent + below;
        top += ascent + below;
        var pen: f32 = 0;
        for (first..lines.end[k]) |i| {
            g.x[i] = pen;
            pen += g.advance[i] + lines.extra[k] * space01(text, g.cluster[i]);
        }
    }
}

fn space01(text: []const u8, at: u32) f32 {
    return @floatFromInt(@intFromBool(isSpace(text, at)));
}

/// Height of the stacked lines, px.
pub fn stackHeight(lines: *const Lines) f32 {
    if (lines.len == 0) return 0;
    const last = lines.len - 1;
    return lines.top[last] + lines.height[last];
}

/// Width of the widest line's ink, px.
pub fn widest(lines: *const Lines) f32 {
    var w: f32 = 0;
    for (lines.width[0..lines.len]) |v| w = @max(w, v);
    return w;
}

// ---------------------------------------------------------------------------------------------

const testing = std.testing;
const golden = @import("golden.zig");

test "breakLines: words fill lines greedily, trailing spaces hang" {
    var t: golden.Para = .{};
    // Every glyph 10 px wide.
    const text = "aa bb  cc dd";
    t.fixed(text, 10);
    // "aa bb" is 50 px of ink; the second space and "cc" do not fit in 60.
    try breakLines(&t.g, text, 60, &t.l);
    try testing.expectEqual(2, t.l.len);
    try testing.expectEqualSlices(u32, &.{ 0, 7 }, t.l.first[0..2]);
    try testing.expectEqualSlices(u32, &.{ 7, 12 }, t.l.end[0..2]);
    try testing.expectEqualSlices(u32, &.{ 5, 12 }, t.l.ink[0..2]);
    try testing.expectEqualSlices(u32, &.{ 0, 7 }, t.l.start[0..2]);
    try testing.expectEqualSlices(f32, &.{ 50, 50 }, t.l.width[0..2]);
    try testing.expectEqualSlices(f32, &.{ 0, 1 }, t.l.hard[0..2]);
    // Exactly the ink width fits; one pixel less does not.
    try breakLines(&t.g, text, 120, &t.l);
    try testing.expectEqual(1, t.l.len);
    try breakLines(&t.g, text, 119, &t.l);
    try testing.expectEqual(2, t.l.len);
}

test "breakLines: newlines are mandatory, a long word breaks between clusters" {
    var t: golden.Para = .{};
    const text = "a\nabcdefg h\n";
    t.fixed(text, 10);
    try breakLines(&t.g, text, 30, &t.l);
    // "a" | "abc" | "def" | "g h" (the rest of the word, then the next one fits) | "" after
    // the final newline.
    try testing.expectEqual(5, t.l.len);
    try testing.expectEqualSlices(u32, &.{ 0, 2, 5, 8, 12 }, t.l.first[0..5]);
    try testing.expectEqualSlices(u32, &.{ 1, 5, 8, 11, 12 }, t.l.ink[0..5]);
    try testing.expectEqualSlices(f32, &.{ 1, 0, 0, 1, 1 }, t.l.hard[0..5]);
    try testing.expectEqual(12, t.l.start[4]);
    // Empty text is one empty line.
    t.fixed("", 10);
    try breakLines(&t.g, "", 30, &t.l);
    try testing.expectEqual(1, t.l.len);
    try testing.expectEqual(0, t.l.ink[0]);
    // Too few rows.
    t.fixed("a\nb\nc", 10);
    t.l.first.len = 2;
    try testing.expectError(error.NoSpace, breakLines(&t.g, "a\nb\nc", 100, &t.l));
}

test "place: alignment is an offset, justification widens inner spaces" {
    var t: golden.Para = .{};
    const text = "aa b cc d\nee";
    t.fixed(text, 10);
    try breakLines(&t.g, text, 60, &t.l);
    // "aa b " | "cc d\n" | "ee"
    try testing.expectEqual(3, t.l.len);
    const m: Metrics = .{ .ascent = 8, .descent = 2 };
    place(&t.l, &t.g, text, &.{m}, .{ .width = 60, .factor = 0.5 });
    try testing.expectEqualSlices(f32, &.{ 10, 10, 20 }, t.l.x[0..3]);
    try testing.expectEqualSlices(f32, &.{ 0, 10, 20 }, t.l.top[0..3]);
    try testing.expectEqualSlices(f32, &.{ 8, 18, 28 }, t.l.baseline[0..3]);
    place(&t.l, &t.g, text, &.{m}, .{ .width = 60, .factor = 1 });
    try testing.expectEqualSlices(f32, &.{ 20, 20, 40 }, t.l.x[0..3]);
    // Justified: line 0 has one inner space (the trailing one hangs) and 20 px free. Line 1
    // ends at a newline and line 2 is the last: aligned as usual.
    place(&t.l, &t.g, text, &.{m}, .{ .width = 60, .factor = 1, .justify = true });
    try testing.expectEqualSlices(f32, &.{ 20, 0, 0 }, t.l.extra[0..3]);
    try testing.expectEqualSlices(f32, &.{ 0, 20, 40 }, t.l.x[0..3]);
    try testing.expectEqualSlices(f32, &.{ 0, 10, 20, 50 }, t.g.x[0..4]);
}

test "golden: aligned and justified paragraphs match the reference" {
    try golden.expectScene(.center);
    try golden.expectScene(.end);
    try golden.expectScene(.justify);
}

test "ellipsize: extra lines are dropped and the last one ends in an ellipsis" {
    var t: golden.Para = .{};
    const text = "aa bb cc dd";
    t.fixed(text, 10);
    try breakLines(&t.g, text, 50, &t.l);
    try testing.expectEqual(2, t.l.len); // "aa bb " | "cc dd"
    // Two lines allowed, nothing dropped, both fit: no ellipsis.
    ellipsize(&t.l, &t.g, text, 50, 2, 15);
    try testing.expectEqual(2, t.l.len);
    try testing.expectEqual(0, t.l.ellipsis);
    // One line: "aa bb" + 15 px is too wide, so "bb" and its space go: "aa" + ellipsis.
    ellipsize(&t.l, &t.g, text, 50, 1, 15);
    try testing.expectEqual(1, t.l.len);
    try testing.expectEqual(3, t.l.end[0]); // the space stays, hanging
    try testing.expectEqual(2, t.l.ink[0]);
    try testing.expectEqual(35, t.l.width[0]);
    try testing.expectEqual(1, t.l.hard[0]);
    try testing.expectEqual(15, t.l.ellipsis);
    // Text that does not wrap: one line, cut where it overflows.
    try breakLines(&t.g, text, std.math.inf(f32), &t.l);
    ellipsize(&t.l, &t.g, text, 75, 1, 15);
    try testing.expectEqual(5, t.l.ink[0]); // "aa bb" + ellipsis = 65
    try testing.expectEqual(65, t.l.width[0]);
    // No room at all: only the ellipsis is left.
    try breakLines(&t.g, text, std.math.inf(f32), &t.l);
    ellipsize(&t.l, &t.g, text, 10, 1, 15);
    try testing.expectEqual(0, t.l.ink[0]);
    try testing.expectEqual(15, t.l.width[0]);
}

test "golden: clamped and truncated paragraphs match the reference" {
    try golden.expectScene(.clamp);
    try golden.expectScene(.single);
}

test "golden: rich text matches the reference" {
    try golden.expectScene(.rich);
}

test "golden: shaped paragraphs wrap like the reference" {
    try golden.expectScene(.wrap);
    try golden.expectScene(.narrow);
}
