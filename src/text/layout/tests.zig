//! Text layout tests across the lane's files: every golden picture, that the pictures catch
//! mistakes, invariants of breaking, alignment, ellipsis and queries over many random
//! paragraphs, and Unicode cases. The files' own tests check each step by hand.

const std = @import("std");
const lines = @import("lines.zig");
const query = @import("query.zig");
const spans = @import("spans.zig");
/// For src/text/layout/conformance.zig, a separate test root.
pub const golden = @import("golden.zig");
const shape = @import("../shape/shape.zig");
const opentype = @import("../font/opentype.zig");

const testing = std.testing;

test "every golden picture matches its reference" {
    inline for (@typeInfo(golden.Scene).@"enum".field_names) |name| {
        const s = @field(golden.Scene, name);
        if (s == .frame) try golden.expectFrame() else try golden.expectScene(s);
    }
}

test "the golden pictures catch a wrong break and a glyph one pixel off" {
    var buf: [golden.max_w * golden.max_h]u8 = undefined;
    // The bounds hold for the real layout ...
    try testing.expect((try golden.diff(.wrap, try golden.render(.wrap, .{}, &buf))).matches());
    try testing.expect((try golden.diff(.carets, try golden.render(.carets, .{}, &buf))).matches());
    // ... and fail for a box 20 px narrower (other breaks), for text one pixel to the right,
    // and for justified carets laid out in a narrower box.
    try testing.expect(!(try golden.diff(.wrap, try golden.render(.wrap, .{ .narrower = 20 }, &buf))).matches());
    try testing.expect(!(try golden.diff(.wrap, try golden.render(.wrap, .{ .dx = 1 }, &buf))).matches());
    try testing.expect(!(try golden.diff(.justify, try golden.render(.justify, .{ .dx = 0.5 }, &buf))).matches());
    try testing.expect(!(try golden.diff(.carets, try golden.render(.carets, .{ .narrower = 1 }, &buf))).matches());
}

/// A random paragraph over a small alphabet with random advances, at most `text.len` bytes.
fn randomPara(rng: std.Random, p: *golden.Para, text: []u8) []const u8 {
    const alphabet = "abc  \n";
    const n = rng.uintLessThan(usize, text.len + 1);
    for (text[0..n]) |*c| c.* = alphabet[rng.uintLessThan(usize, alphabet.len)];
    p.fixed(text[0..n], 1);
    for (p.advance[0..n]) |*a| a.* = 1 + rng.float(f32) * 15;
    return text[0..n];
}

test "invariants of breaking, placing and querying, over random paragraphs" {
    var prng: std.Random.DefaultPrng = .init(0x7e57);
    const rng = prng.random();
    var p: golden.Para = .{};
    var text_buf: [120]u8 = undefined;
    var checked: u32 = 0;
    for (0..300) |_| {
        const text = randomPara(rng, &p, &text_buf);
        const width = 5 + rng.float(f32) * 100;
        lines.breakLines(&p.g, text, width, &p.l) catch continue; // more than 32 lines
        checked += 1;
        const l = &p.l;
        // Lines cover the glyphs in order, without gaps.
        try testing.expect(l.len >= 1);
        try testing.expectEqual(0, l.first[0]);
        try testing.expectEqual(p.g.len, l.end[l.len - 1]);
        for (0..l.len) |k| {
            try testing.expect(l.first[k] <= l.ink[k] and l.ink[k] <= l.end[k]);
            if (k > 0) {
                try testing.expectEqual(l.end[k - 1], l.first[k]);
                try testing.expect(l.start[k - 1] <= l.start[k]);
            }
            // A line fits, unless it holds a single glyph wider than the box.
            try testing.expect(l.width[k] <= width + lines.slack or l.ink[k] - l.first[k] == 1);
            // Only spaces and newlines hang after the ink.
            for (l.ink[k]..l.end[k]) |i| try testing.expect(lines.isSpace(text, p.g.cluster[i]));
            // A newline always ends its line.
            for (l.first[k]..l.end[k]) |i| try testing.expect(text[p.g.cluster[i]] != '\n' or i + 1 == l.end[k]);
        }
        // Breaking at the widest line gives the same lines (measure, then wrap at the measured
        // width, changes nothing), unless a glyph wider than the box made the widest line.
        const widest = lines.widest(l);
        if (widest <= width) {
            var q: golden.Para = .{};
            q.fixed(text, 1);
            @memcpy(q.advance[0..p.g.len], p.advance[0..p.g.len]);
            try lines.breakLines(&q.g, text, widest, &q.l);
            try testing.expectEqual(l.len, q.l.len);
            try testing.expectEqualSlices(u32, l.end[0..l.len], q.l.end[0..l.len]);
        }

        // Placed in the box: aligned lines stay inside it, justified lines fill it exactly.
        const factor = rng.float(f32);
        const justify = rng.boolean();
        lines.place(l, &p.g, text, &.{.{ .ascent = 8, .descent = 3 }}, .{ .width = width, .factor = factor, .justify = justify });
        for (0..l.len) |k| {
            try testing.expectEqual(@as(f32, @floatFromInt(k * 11)), l.top[k]);
            const right = l.x[k] + l.width[k] + l.extra[k] * spacesIn(&p, text, k);
            if (l.width[k] <= width) try testing.expect(l.x[k] >= -1e-3 and right <= width + 1e-2);
            if (l.extra[k] > 0) try testing.expectApproxEqAbs(width, right, 1e-2);
        }
        // Carets move right along a line, and a click on a caret gives its offset back.
        var prev_line: u32 = 0;
        var prev_x = -std.math.inf(f32);
        for (0..text.len + 1) |i| {
            const c = query.caret(l, &p.g, text, @intCast(i));
            if (c.line == prev_line) try testing.expect(c.x >= prev_x - 1e-3);
            try testing.expect(c.line >= prev_line);
            prev_line = c.line;
            prev_x = c.x;
            const back = query.hit(l, &p.g, text, c.x, c.top + c.height / 2);
            // Equal x on one line (a zero-width step) is the only way to land elsewhere.
            const again = query.caret(l, &p.g, text, back);
            try testing.expectEqual(c.line, again.line);
            try testing.expectApproxEqAbs(c.x, again.x, 1e-3);
        }
        // Clamped to some lines: never more, and the cut line fits with its ellipsis.
        const max_lines = 1 + rng.uintLessThan(u32, 3);
        const was = l.len;
        lines.ellipsize(l, &p.g, text, width, max_lines, 6);
        try testing.expectEqual(@min(was, max_lines), l.len);
        const last = l.len - 1;
        if (l.ellipsis > 0) try testing.expect(l.width[last] <= width + lines.slack or l.ink[last] == l.first[last]);
    }
    // The seed is fixed: 256 of the 300 paragraphs fit 32 lines.
    try testing.expect(checked >= 250);
}

fn spacesIn(p: *const golden.Para, text: []const u8, k: usize) f32 {
    var n: f32 = 0;
    for (p.l.first[k]..p.l.ink[k]) |i| n += @floatFromInt(@intFromBool(lines.isSpace(text, p.g.cluster[i])));
    return n;
}

test "carets stop at grapheme boundaries, also when a mark has its own cluster" {
    const shapers = [_]shape.Shaper{.init(try opentype.Face.parse(golden.font, 0))};
    var p: golden.Para = .{};
    p.bind();
    // "é" precomposed (2 bytes), then e + combining acute (1 + 2 bytes): two graphemes.
    const text = "\u{e9}e\u{301}";
    _ = try p.s.push(0, 0, 20, 0);
    try p.shaped(&shapers, text);
    try testing.expectEqual(3, p.g.len);
    try testing.expectEqualSlices(u32, &.{ 0, 2, 3 }, p.g.cluster[0..3]); // the mark is its own cluster
    try lines.breakLines(&p.g, text, 1000, &p.l);
    lines.place(&p.l, &p.g, text, &.{lines.Metrics.of(&shapers[0].face, 20)}, .{});
    const x = [_]f32{
        query.caret(&p.l, &p.g, text, 0).x,
        query.caret(&p.l, &p.g, text, 1).x,
        query.caret(&p.l, &p.g, text, 2).x,
        query.caret(&p.l, &p.g, text, 3).x,
        query.caret(&p.l, &p.g, text, 4).x,
        query.caret(&p.l, &p.g, text, 5).x,
    };
    try testing.expectEqual(x[0], x[1]); // inside é
    try testing.expectEqual(p.g.advance[0], x[2]);
    try testing.expectEqual(x[2], x[3]); // between e and its mark: not a stop
    try testing.expectEqual(x[2], x[4]);
    try testing.expectApproxEqAbs(p.g.advance[0] + p.g.advance[1] + p.g.advance[2], x[5], 1e-4);
    // Clicks land on 0, 2 or 5 only.
    var f: f32 = -5;
    while (f < x[5] + 5) : (f += 0.5) {
        const o = query.hit(&p.l, &p.g, text, f, 1);
        try testing.expect(o == 0 or o == 2 or o == 5);
    }
}

test "a paragraph of spans keeps its offsets through breaking and queries" {
    const shapers = [_]shape.Shaper{.init(try opentype.Face.parse(golden.font, 0))};
    var p: golden.Para = .{};
    p.bind();
    const text = "tiny HUGE tiny";
    _ = try p.s.push(0, 0, 10, 0);
    _ = try p.s.push(5, 0, 40, 0);
    _ = try p.s.push(9, 0, 10, 0);
    try p.shaped(&shapers, text);
    var m: [3]lines.Metrics = undefined;
    spans.metrics(&shapers, &p.s, &m);
    // Narrow enough that HUGE gets a line of its own.
    try lines.breakLines(&p.g, text, p.g.advance[0] * 6, &p.l);
    lines.place(&p.l, &p.g, text, &m, .{});
    try testing.expect(p.l.len >= 3);
    const c = query.caret(&p.l, &p.g, text, 5);
    try testing.expectEqual(1, c.line);
    try testing.expectEqual(m[1].height(), c.height);
    try testing.expectEqual(5, query.hit(&p.l, &p.g, text, -1, c.top + 1));
}

test "text-edit's screen-order caret sits on the glyph it moved to over reordered lines" {
    const mem = @import("../../core/mem.zig");
    const moves = @import("../edit/moves.zig");
    var raw: [16 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    const s = carver.columns(lines.BidiScratch, 32);
    const ms = carver.columns(moves.BidiScratch, 32);
    var p: golden.Para = .{};
    const texts = [_][]const u8{
        "abc \u{5D0}\u{5D1}\u{5D2} de", // left-to-right paragraph with a Hebrew word
        "\u{5D0}\u{5D1} ab 12 \u{5D2}", // right-to-left paragraph with Latin and digits
        "\u{5D0}(a)\u{5D1}",
    };
    for (texts) |text| {
        p.fixed(text, 10);
        try lines.breakLines(&p.g, text, std.math.inf(f32), &p.l);
        lines.place(&p.l, &p.g, text, &.{.{ .ascent = 8, .descent = 2 }}, .{});
        try lines.reorder(&p.l, &p.g, text, s);
        const v: moves.View = .{ .l = &p.l, .g = &p.g, .text = text };
        // From the left end, Right moves the drawn caret strictly rightwards, each time onto
        // the glyph moves.visual placed the stop at, up to the right end; Left walks back.
        // (Two offsets at a direction change are one stop, so a step can cross two glyphs.)
        const right: f32 = @floatFromInt(p.g.len * 10);
        var at: u32 = 0;
        for (0..2 * p.g.len) |_| at = moves.visual(text, at, -1, ms).?;
        try testing.expectEqual(0, v.x(at));
        var prev: f32 = 0;
        var steps: u32 = 0;
        while (prev < right) : (steps += 1) {
            at = moves.visual(text, at, 1, ms).?;
            try testing.expect(v.x(at) > prev);
            try expectOnGlyph(&p, text, at);
            prev = v.x(at);
        }
        try testing.expectEqual(right, prev);
        try testing.expect(steps + 2 >= p.g.len);
        while (prev > 0) {
            at = moves.visual(text, at, -1, ms).?;
            try testing.expect(v.x(at) < prev);
            try expectOnGlyph(&p, text, at);
            prev = v.x(at);
        }
    }
}

/// The caret at `at` is drawn on the leading edge of the glyph after it (its left edge, the
/// right edge of a right-to-left one) or, at the text's end, the trailing edge of the last.
fn expectOnGlyph(p: *const golden.Para, text: []const u8, at: u32) !void {
    const x = query.caret(&p.l, &p.g, text, at).x;
    for (0..p.g.len) |i| if (p.g.cluster[i] == at) {
        const rtl: f32 = @floatFromInt(p.g.level[i] & 1);
        return testing.expectEqual(p.g.x[i] + p.g.advance[i] * rtl, x);
    };
    const last = p.g.len - 1;
    const rtl: f32 = @floatFromInt(p.g.level[last] & 1);
    try testing.expectEqual(p.g.x[last] + p.g.advance[last] * (1 - rtl), x);
}
