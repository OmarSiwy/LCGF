//! Rich text: one paragraph in several styles. Tier 0.
//!
//! A span is a byte range of the paragraph's text with one font, size and colour. Spans are
//! columns (`Spans`), sorted by `start`, the first at 0, each running to the next one's start.
//! `shape` shapes adjacent spans with the same font and size together and appends to `Glyphs`,
//! tagged with the span (`Glyphs.span`), so breaking, alignment, ellipsis and queries see one
//! paragraph. `metrics` gives `lines.place` each span's vertical metrics, so a line is as tall
//! as the tallest span on it. Paint-only boundaries preserve kerning, ligatures and marks.
//! A glyph which covers several paint spans takes the colour of its first cluster byte;
//! changing the font or size still starts a separate shaping run.

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
    return shapeFeatures(shapers, text, spans, run, g, .{});
}

/// The same segmentation with explicit shaping features. Paint-only boundaries do not
/// restart the shaper. `run` must fit the largest adjacent group with the same font and size.
pub fn shapeFeatures(shapers: []const shape_.Shaper, text: []const u8, spans: *const Spans, run: *shape_.Run, g: *lines.Glyphs, features: shape_.Features) error{NoSpace}!void {
    return shapeCached(shapers, text, spans, run, g, features, null, &.{}, &.{});
}

/// Optional caller-owned shaping cache. Font identities and reload generations are separate
/// from local span indices; omitted entries use the span font index and generation zero.
pub fn shapeCached(shapers: []const shape_.Shaper, text: []const u8, spans: *const Spans, run: *shape_.Run, g: *lines.Glyphs, features: shape_.Features, cache: ?*@import("../shape/cache.zig").Cache, font_ids: []const u64, generations: []const u64) error{NoSpace}!void {
    g.len = 0;
    g.fonts = .{ .spans = spans.font[0..spans.len] };
    var k: u32 = 0;
    while (k < spans.len) {
        var end = k + 1;
        while (end < spans.len and spans.font[end] == spans.font[k] and spans.px[end] == spans.px[k]) end += 1;
        const sh = &shapers[spans.font[k]];
        const start = spans.start[k];
        const byte_end = if (end < spans.len) spans.start[end] else text.len;
        const font = spans.font[k];
        const shaped = if (cache) |c| try c.shapeVersioned(sh, .{
            .font = if (font < font_ids.len) font_ids[font] else font,
            .generation = if (font < generations.len) generations[font] else 0,
        }, text[start..byte_end], features, run) else blk: {
            try sh.shape(text[start..byte_end], run, features);
            break :blk run.*;
        };
        const scale = spans.px[k] / @as(f32, @floatFromInt(sh.face.units_per_em));
        const first = g.len;
        try g.append(&shaped, scale, start, k);
        // Clusters are monotonic in this shaper. Walk the paint spans once, including empty
        // spans, instead of rescanning the whole table for every glyph.
        var paint = k;
        for (first..g.len) |i| {
            while (paint + 1 < end and spans.start[paint + 1] <= g.cluster[i]) paint += 1;
            g.span[i] = paint;
        }
        k = end;
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

test "paint-only spans preserve kerning and ligatures and features remain explicit" {
    const shapers = [_]shape_.Shaper{.init(try opentype.Face.parse(golden.font, 0))};
    const text = "AV office";
    var p: golden.Para = .{};
    p.bind();
    _ = try p.s.push(0, 0, 20, 0xff0000ff);
    _ = try p.s.push(1, 0, 20, 0x00ff00ff);
    _ = try p.s.push(5, 0, 20, 0x0000ffff);
    var cols: golden.RunCols = .{};
    var run = cols.run();
    try shape(&shapers, text, &p.s, &run, &p.g);

    var plain_cols: golden.RunCols = .{};
    var plain = plain_cols.run();
    try shapers[0].shape(text, &plain, .{});
    try testing.expectEqual(plain.len, p.g.len);
    try testing.expectEqualSlices(u16, plain.glyph[0..plain.len], p.g.glyph[0..p.g.len]);
    try testing.expectEqualSlices(u32, plain.cluster[0..plain.len], p.g.cluster[0..p.g.len]);
    const scale = 20 / @as(f32, @floatFromInt(shapers[0].face.units_per_em));
    for (0..plain.len) |i| {
        try testing.expectApproxEqAbs(@as(f32, @floatFromInt(plain.advance[i])) * scale, p.g.advance[i], 1e-4);
        try testing.expectEqual(p.s.at(p.g.cluster[i]), p.g.span[i]);
    }
    // The fixture contains an ffi ligature: a colour boundary inside it must not split it.
    try testing.expect(p.g.len < text.len);
    const joined_count = p.g.len;
    try shapeFeatures(&shapers, text, &p.s, &run, &p.g, .{ .liga = false, .kern = false });
    try testing.expect(p.g.len > joined_count);
    try testing.expectEqual(text.len, p.g.len);
}
