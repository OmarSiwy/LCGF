//! Rich text: one paragraph in several styles. Tier 0.
//!
//! A span is a byte range of the paragraph's text with one font, size and colour. Spans are
//! columns (`Spans`), sorted by `start`, the first at 0, each running to the next one's start.
//! `shape` shapes each span on its own with its font and appends its glyphs to one `Glyphs`,
//! tagged with the span (`Glyphs.span`), so breaking, alignment, ellipsis and queries see one
//! paragraph. `metrics` gives `lines.place` each span's vertical metrics, so a line is as tall
//! as the tallest span on it. Kerning and ligatures do not cross a span boundary (the text is
//! shaped in pieces), as in browsers when the font or size changes.

const std = @import("std");
const shape_ = @import("../shape/shape.zig");
const opentype = @import("../font/opentype.zig");
const lines = @import("lines.zig");

/// Style runs of a paragraph. Capacity is the slices' length, all equal.
pub const Spans = struct {
    /// Byte offset of the span's text; ascending, the first is 0.
    start: []u32,
    /// Index into the caller's table of shapers.
    font: []u16,
    px: []f32,
    /// Carried for the renderer (`types.Color` bits); layout does not read it.
    color: []u32,
    len: u32 = 0,

    /// Appends a span from byte `start` on. Returns its row.
    pub fn push(s: *Spans, start: u32, font: u16, px: f32, color: u32) error{NoSpace}!u32 {
        const k = s.len;
        if (k == s.start.len) return error.NoSpace;
        std.debug.assert(if (k == 0) start == 0 else start >= s.start[k - 1]);
        s.start[k] = start;
        s.font[k] = font;
        s.px[k] = px;
        s.color[k] = color;
        s.len = k + 1;
        return k;
    }

    /// The span byte `at` is in: the last one starting at or before it. A count over the
    /// sorted starts, no branch.
    pub fn at(s: *const Spans, byte: u32) u32 {
        std.debug.assert(s.len > 0);
        var n: u32 = 0;
        for (s.start[0..s.len]) |st| n += @intFromBool(st <= byte);
        return @max(n, 1) - 1;
    }

    /// Byte offset where span `k` ends.
    pub fn end(s: *const Spans, k: u32, text_len: usize) u32 {
        return if (k + 1 < s.len) s.start[k + 1] else @intCast(text_len);
    }
};

/// Shapes every span of `text` with `shapers[spans.font[k]]` and its size into `g`, which it
/// empties first. `run` is scratch for one span's glyphs. `error.NoSpace` when a span does not
/// fit in `run` or the paragraph does not fit in `g`.
pub fn shape(shapers: []const shape_.Shaper, text: []const u8, spans: *const Spans, run: *shape_.Run, g: *lines.Glyphs) error{NoSpace}!void {
    g.len = 0;
    for (0..spans.len) |k| {
        const sh = &shapers[spans.font[k]];
        const start = spans.start[k];
        try sh.shape(text[start..spans.end(@intCast(k), text.len)], run, .{});
        const scale = spans.px[k] / @as(f32, @floatFromInt(sh.face.units_per_em));
        try g.append(run, scale, start, @intCast(k));
    }
}

/// Vertical metrics of each span, for `lines.place`. `out` has a row per span.
pub fn metrics(shapers: []const shape_.Shaper, spans: *const Spans, out: []lines.Metrics) void {
    for (0..spans.len) |k| out[k] = .of(&shapers[spans.font[k]].face, spans.px[k]);
}

// ---------------------------------------------------------------------------------------------

const testing = std.testing;
const golden = @import("golden.zig");

test "spans: shaped in pieces, glyphs tagged with their span, lines as tall as their tallest span" {
    const shapers = [_]shape_.Shaper{.init(try opentype.Face.parse(golden.font, 0))};
    var p: golden.Para = .{};
    p.bind();
    const text = "aa BB cc";
    _ = try p.s.push(0, 0, 10, 0);
    _ = try p.s.push(3, 0, 20, 0xff0000ff);
    _ = try p.s.push(5, 0, 10, 0);
    try testing.expectEqual(1, p.s.at(4));
    try testing.expectEqual(2, p.s.at(5));
    try testing.expectEqual(2, p.s.at(100));
    var cols: golden.RunCols = .{};
    var run = cols.run();
    try shape(&shapers, text, &p.s, &run, &p.g);
    try testing.expectEqual(8, p.g.len);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 1, 1, 2, 2, 2 }, p.g.span[0..8]);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, p.g.cluster[0..8]);
    // B at 20 px is twice as wide as B at 10 px would be.
    const b10 = @as(f32, @floatFromInt(shapers[0].face.hMetrics(shapers[0].face.cmap.glyph('B')).advance)) * 10 / 1000;
    try testing.expectApproxEqAbs(2 * b10, p.g.advance[3], 1e-4);

    var m: [3]lines.Metrics = undefined;
    metrics(&shapers, &p.s, &m);
    try lines.breakLines(&p.g, text, 1000, &p.l);
    lines.place(&p.l, &p.g, text, &m, .{});
    try testing.expectEqual(m[1].ascent, p.l.baseline[0]);
    try testing.expectEqual(m[1].height(), p.l.height[0]);
    // Broken after "aa ": the first line is all 10 px.
    try lines.breakLines(&p.g, text, p.g.advance[0] * 2.5, &p.l);
    lines.place(&p.l, &p.g, text, &m, .{});
    try testing.expect(p.l.len >= 3);
    try testing.expectEqual(m[0].height(), p.l.height[0]);
    try testing.expectEqual(m[0].height() + m[1].ascent, p.l.baseline[1]);
}
