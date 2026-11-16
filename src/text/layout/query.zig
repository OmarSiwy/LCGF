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

/// The caret stops of line `k` in text order (left to right unless `lines.reorder` moved
/// glyphs): the grapheme boundaries of its text, each at the leading edge of the cluster it
/// starts (its left edge, the right edge of a right-to-left one), or a share of the cluster it
/// falls inside; the line's end at the trailing edge of its last cluster. Shaping may give a
/// combining mark its own cluster; the boundary walk skips it, as src/text/shape/cluster.zig
/// does. An iterator over the columns: no scratch.
pub const Stops = struct {
    l: *const Lines,
    g: *const Glyphs,
    text: []const u8,
    k: u32,
    /// Graphemes of the line's text from its start.
    it: Graphemes,
    base: u32,
    /// Byte offset where the line's text ends.
    stop: u32,
    /// Next glyph after the open cluster.
    i: u32,
    /// The open cluster (`cs == ce` when none is left): text range, left edge, width, and 1.0
    /// when it is right to left.
    cs: u32 = 0,
    ce: u32 = 0,
    cx: f32,
    cw: f32 = 0,
    rtl: f32 = 0,
    /// The trailing edge of the last cluster closed.
    tail: f32,
    started: bool = false,
    /// The line's end is still to come.
    final: bool,

    pub fn init(l: *const Lines, g: *const Glyphs, text: []const u8, k: u32) Stops {
        const stop = byteAt(g, text, l.end[k]);
        const base = l.start[k];
        var s: Stops = .{
            .l = l,
            .g = g,
            .text = text,
            .k = k,
            .it = .{ .text = text[base..stop] },
            .base = base,
            .stop = stop,
            .i = l.first[k],
            .cx = l.x[k],
            .tail = l.x[k],
            .final = k + 1 == l.len or l.end[k] == l.ink[k],
        };
        s.open();
        return s;
    }

    /// Opens the cluster at glyph `i`, or none past the line's end.
    fn open(s: *Stops) void {
        const g = s.g;
        const end = s.l.end[s.k];
        s.cw = 0;
        if (s.i >= end) {
            s.cs = s.stop;
            s.ce = s.stop;
            return;
        }
        s.cs = g.cluster[s.i];
        s.rtl = @floatFromInt(g.level[s.i] & 1);
        const extra = s.l.extra[s.k];
        var left = std.math.inf(f32);
        while (s.i < end and g.cluster[s.i] == s.cs) : (s.i += 1) {
            left = @min(left, g.x[s.i]);
            s.cw += g.advance[s.i] + extra * @as(f32, @floatFromInt(@intFromBool(lines_.isSpace(s.text, g.cluster[s.i]))));
        }
        s.cx = s.l.x[s.k] + left;
        s.ce = byteAt(g, s.text, s.i);
    }

    pub fn next(s: *Stops) ?Stop {
        if (!s.started) {
            s.started = true;
            return .{ .offset = s.base, .x = s.cx + s.cw * s.rtl };
        }
        const b = if (s.it.next()) |e| s.base + @as(u32, @intCast(e)) else s.stop;
        // Move past the clusters that end at or before this boundary.
        while (s.cs < s.ce and s.ce <= b) {
            s.tail = s.cx + s.cw * (1 - s.rtl);
            s.open();
        }
        if (b >= s.stop) {
            if (!s.final) return null;
            s.final = false;
            return .{ .offset = s.stop, .x = s.tail };
        }
        if (b == s.cs) return .{ .offset = b, .x = s.cx + s.cw * s.rtl };
        // Inside a cluster of several graphemes: an equal share of its width per grapheme,
        // from its leading edge.
        const before = graphemes(s.text[s.cs..b]);
        const all = graphemes(s.text[s.cs..s.ce]);
        return .{ .offset = b, .x = s.cx + s.cw * (s.rtl + (1 - 2 * s.rtl) * before / all) };
    }
};

fn graphemes(text: []const u8) f32 {
    var it: Graphemes = .{ .text = text };
    var n: f32 = 0;
    while (it.next()) |_| n += 1;
    return @max(n, 1);
}

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
