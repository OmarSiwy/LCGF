//! Position queries on a laid-out paragraph: index to position (where the caret for a byte
//! offset is drawn) and position to index (which offset a click hits). Tier 0.
//!
//! Both read the columns `lines.place` wrote; nothing is reshaped and nothing is stored. A
//! caret stops at grapheme boundaries (src/text/unicode/grapheme.zig). A cluster covering
//! several graphemes (a ligature such as ffi) shares its advance equally among them, the rule
//! of src/text/shape/cluster.zig, which this applies per line in pixels and with justification.
//!
//! Lines own the offsets from their `start` up to the next line's start. A line ending in a
//! space or newline does not offer its end as a stop (that offset is the next line's start),
//! so a click right of a line lands before its trailing space or newline; a line broken inside
//! a word, and the last line, do. Text hidden by an ellipsis maps to the end of the last line.

const std = @import("std");
const lines_ = @import("lines.zig");
const Graphemes = @import("../unicode/grapheme.zig").Graphemes;

const Lines = lines_.Lines;
const Glyphs = lines_.Glyphs;

/// A caret stop: a byte offset and the caret's x, px from the paragraph's left edge.
pub const Stop = struct { offset: u32, x: f32 };

/// The caret stops of line `k`, left to right. An iterator over the columns: no scratch.
pub const Stops = struct {
    l: *const Lines,
    g: *const Glyphs,
    text: []const u8,
    k: u32,
    /// First glyph of the next cluster.
    i: u32,
    /// The open cluster: its text range, x, width, graphemes in it and emitted so far.
    cs: u32 = 0,
    ce: u32 = 0,
    cx: f32 = 0,
    cw: f32 = 0,
    n: u32 = 0,
    j: u32 = 0,
    inner: Graphemes = .{ .text = "" },
    /// The line's end is still to come.
    final: bool,

    pub fn init(l: *const Lines, g: *const Glyphs, text: []const u8, k: u32) Stops {
        const last = k + 1 == l.len;
        return .{ .l = l, .g = g, .text = text, .k = k, .i = l.first[k], .cx = l.x[k], .final = last or l.end[k] == l.ink[k] };
    }

    pub fn next(s: *Stops) ?Stop {
        if (s.inner.next()) |e| {
            const b = s.cs + @as(u32, @intCast(e));
            if (b < s.ce) {
                s.j += 1;
                return .{ .offset = b, .x = s.cx + s.cw * @as(f32, @floatFromInt(s.j)) / @as(f32, @floatFromInt(s.n)) };
            }
        }
        const end = s.l.end[s.k];
        if (s.i >= end) {
            if (!s.final) return null;
            s.final = false;
            return .{ .offset = byteAt(s.g, s.text, end), .x = s.cx + s.cw };
        }
        // Open the cluster at glyph i.
        const g = s.g;
        s.cx += s.cw;
        s.cs = g.cluster[s.i];
        s.cw = 0;
        const extra = s.l.extra[s.k];
        while (s.i < end and g.cluster[s.i] == s.cs) : (s.i += 1) {
            s.cw += g.advance[s.i] + extra * @as(f32, @floatFromInt(@intFromBool(lines_.isSpace(s.text, g.cluster[s.i]))));
        }
        s.ce = byteAt(g, s.text, s.i);
        var count: Graphemes = .{ .text = s.text[s.cs..s.ce] };
        s.n = 0;
        while (count.next()) |_| s.n += 1;
        s.n = @max(s.n, 1);
        s.j = 0;
        s.inner = .{ .text = s.text[s.cs..s.ce] };
        return .{ .offset = s.cs, .x = s.cx };
    }
};

/// The byte offset where glyph `i` starts: its cluster, or the end of the text past the last.
fn byteAt(g: *const Glyphs, text: []const u8, i: u32) u32 {
    return if (i < g.len) g.cluster[i] else @intCast(text.len);
}

/// Where the caret goes: x, and the line's top, baseline and height (px from the paragraph's
/// top left), and the line.
pub const Caret = struct { x: f32, top: f32, baseline: f32, height: f32, line: u32 };

/// The caret for byte offset `index`: on the last line starting at or before it, at the last
/// stop at or before it (an offset inside a grapheme snaps back to its start).
pub fn caret(l: *const Lines, g: *const Glyphs, text: []const u8, index: u32) Caret {
    std.debug.assert(l.len > 0);
    var n: u32 = 0;
    for (l.start[0..l.len]) |st| n += @intFromBool(st <= index);
    const k = @max(n, 1) - 1;
    var s: Stops = .init(l, g, text, k);
    var x = l.x[k];
    while (s.next()) |stop| {
        if (stop.offset > index) break;
        x = stop.x;
    }
    return .{ .x = x, .top = l.top[k], .baseline = l.baseline[k], .height = l.height[k], .line = k };
}

/// The byte offset a click at (`x`, `y`) hits, px from the paragraph's top left: on the line
/// whose band holds `y` (the first above the paragraph, the last below it), the stop nearest
/// to `x`, the earlier on a tie.
pub fn hit(l: *const Lines, g: *const Glyphs, text: []const u8, x: f32, y: f32) u32 {
    std.debug.assert(l.len > 0);
    var n: u32 = 0;
    for (l.top[0..l.len]) |t| n += @intFromBool(t <= y);
    const k = @max(n, 1) - 1;
    var s: Stops = .init(l, g, text, k);
    var best: u32 = l.start[k];
    var dist = std.math.inf(f32);
    while (s.next()) |stop| {
        const d = @abs(stop.x - x);
        best = if (d < dist) stop.offset else best;
        dist = @min(d, dist);
    }
    return best;
}

// ---------------------------------------------------------------------------------------------

const testing = std.testing;
const golden = @import("golden.zig");

test "caret and hit on fixed glyphs: lines own their offsets, hanging spaces are not stops" {
    var t: golden.Para = .{};
    const text = "ab cd\nef";
    t.fixed(text, 10);
    try lines_.breakLines(&t.g, text, 25, &t.l);
    // "ab " | "cd\n" | "ef"
    try testing.expectEqual(3, t.l.len);
    lines_.place(&t.l, &t.g, text, &.{.{ .ascent = 8, .descent = 2 }}, .{ .width = 25 });
    const want_x = [_]f32{ 0, 10, 20, 0, 10, 20, 0, 10, 20 };
    const want_line = [_]u32{ 0, 0, 0, 1, 1, 1, 2, 2, 2 };
    for (0..text.len + 1) |i| {
        const c = caret(&t.l, &t.g, text, @intCast(i));
        try testing.expectEqual(want_x[i], c.x);
        try testing.expectEqual(want_line[i], c.line);
        try testing.expectEqual(@as(f32, @floatFromInt(want_line[i] * 10)), c.top);
    }
    // Every stop is hit at its own x; right of "ab " lands before the space, right of "cd\n"
    // before the newline, right of the last line at the end.
    try testing.expectEqual(1, hit(&t.l, &t.g, text, 9, 5));
    try testing.expectEqual(2, hit(&t.l, &t.g, text, 100, 5));
    try testing.expectEqual(5, hit(&t.l, &t.g, text, 100, 15));
    try testing.expectEqual(8, hit(&t.l, &t.g, text, 100, 25));
    try testing.expectEqual(0, hit(&t.l, &t.g, text, -5, -5));
    try testing.expectEqual(6, hit(&t.l, &t.g, text, 4, 1000));
    // A tie goes to the earlier stop.
    try testing.expectEqual(6, hit(&t.l, &t.g, text, 5, 25));
}

test "caret inside a ligature takes an equal share; hit inverts caret at every stop" {
    const shapers = [_]@import("../shape/shape.zig").Shaper{.init(try @import("../font/opentype.zig").Face.parse(golden.font, 0))};
    var t: golden.Para = .{};
    t.bind();
    const text = "office";
    _ = try t.s.push(0, 0, 20, 0);
    try t.shaped(&shapers, text);
    // o, ffi (one glyph, cluster 1), c, e.
    try testing.expectEqual(4, t.g.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 4, 5 }, t.g.cluster[0..4]);
    try lines_.breakLines(&t.g, text, 1000, &t.l);
    lines_.place(&t.l, &t.g, text, &.{lines_.Metrics.of(&shapers[0].face, 20)}, .{});
    const ffi = t.g.advance[1];
    const o = t.g.advance[0];
    try testing.expectApproxEqAbs(o + ffi / 3, caret(&t.l, &t.g, text, 2).x, 1e-4);
    try testing.expectApproxEqAbs(o + 2 * ffi / 3, caret(&t.l, &t.g, text, 3).x, 1e-4);
    for (0..text.len + 1) |i| {
        const c = caret(&t.l, &t.g, text, @intCast(i));
        try testing.expectEqual(@as(u32, @intCast(i)), hit(&t.l, &t.g, text, c.x, c.top + 1));
    }
}

test "golden: carets at every offset match the reference" {
    try golden.expectScene(.carets);
}
