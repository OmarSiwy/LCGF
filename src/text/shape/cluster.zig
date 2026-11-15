//! Cluster mapping: where the cursor goes in a shaped run, and which text offset a click hits.
//! Tier 0.
//!
//! A cursor stops at grapheme boundaries (src/text/unicode/grapheme.zig), never inside a
//! user-perceived character such as e + combining acute. Shaping groups text into clusters
//! (the glyphs that share a `Run.cluster` value): usually one grapheme each, but a ligature
//! covers several (ffi is three), and then its advance is shared equally among the graphemes
//! it covers, the rule HarfBuzz documents and browsers use when the font gives no ligature
//! caret positions.
//!
//! `carets` lists every stop of a run once (byte offset and x), so a frame can answer caret
//! and hit queries from columns without reshaping. One left-to-right run; x in font units
//! from the run's start.

const std = @import("std");
const shape = @import("shape.zig");
const Graphemes = @import("../unicode/grapheme.zig").Graphemes;

/// Caret stops of a run, in text order: `offset[k]` is a grapheme boundary, `x[k]` the pen x
/// of a caret there. The first stop is offset 0 at x 0, the last the end of the text.
pub const Carets = struct {
    offset: []u32,
    x: []i32,
    len: u32 = 0,
};

/// The stops of `run`, shaped from `text`. `out` needs one row per grapheme plus one;
/// `error.NoSpace` otherwise. Clusters must increase along the run (left-to-right shaping).
pub fn carets(run: *const shape.Run, text: []const u8, out: *Carets) error{NoSpace}!void {
    out.len = 0;
    try push(out, 0, 0);
    var pen: i32 = 0;
    var g: u32 = 0; // first glyph of the current cluster
    var span = clusterAt(run, text, g);
    var it: Graphemes = .{ .text = text };
    while (it.next()) |b| {
        // Move past the clusters that end at or before this boundary.
        while (g < run.len and span.end <= b) {
            pen += span.width;
            g = span.next;
            span = clusterAt(run, text, g);
        }
        const x = if (g == run.len or b == span.start) pen else inside: {
            // A boundary inside a cluster: a share of its advance per grapheme.
            const before = graphemes(text[span.start..b]);
            const all = graphemes(text[span.start..span.end]);
            break :inside pen + @divTrunc(span.width * before, all);
        };
        try push(out, @intCast(b), x);
    }
}

fn push(out: *Carets, offset: u32, x: i32) error{NoSpace}!void {
    if (out.len == out.offset.len or out.len == out.x.len) return error.NoSpace;
    out.offset[out.len] = offset;
    out.x[out.len] = x;
    out.len += 1;
}

/// The cluster starting at glyph `g`: its text range, total advance, and its last glyph + 1.
const Span = struct { start: u32, end: u32, width: i32, next: u32 };

fn clusterAt(run: *const shape.Run, text: []const u8, g: u32) Span {
    if (g >= run.len) return .{ .start = @intCast(text.len), .end = @intCast(text.len), .width = 0, .next = g };
    const start = run.cluster[g];
    var next = g;
    var width: i32 = 0;
    while (next < run.len and run.cluster[next] == start) : (next += 1) width += run.advance[next];
    const end: u32 = if (next < run.len) run.cluster[next] else @intCast(text.len);
    return .{ .start = start, .end = end, .width = width, .next = next };
}

fn graphemes(text: []const u8) i32 {
    var it: Graphemes = .{ .text = text };
    var n: i32 = 0;
    while (it.next()) |_| n += 1;
    return n;
}

/// The x of a caret at byte `offset`: that of the last stop at or before it, so an offset
/// inside a grapheme snaps back to the grapheme's start. Stops are sorted, so that is the
/// stop before the first one past `offset`: a count, no branch.
pub fn caretX(c: *const Carets, offset: u32) i32 {
    std.debug.assert(c.len > 0);
    var before: u32 = 0;
    for (c.offset[0..c.len]) |o| before += @intFromBool(o <= offset);
    return c.x[@max(before, 1) - 1];
}

/// The byte offset of the stop nearest to `x` (font units from the run's start); the earlier
/// one on a tie. A click left of the run gives 0, right of it the end. One pass: the minimum
/// of distance and row packed into one integer, so the compare is a `min`, not a jump.
pub fn hit(c: *const Carets, x: i32) u32 {
    std.debug.assert(c.len > 0);
    var best: u64 = std.math.maxInt(u64);
    for (c.x[0..c.len], 0..) |cx, k| best = @min(best, (@as(u64, @abs(@as(i64, cx) - x)) << 32) | k);
    return c.offset[@intCast(best & 0xffff_ffff)];
}

// ---------------------------------------------------------------------------------------------

const TestCarets = struct {
    offset: [32]u32 = undefined,
    x: [32]i32 = undefined,

    fn carets(t: *TestCarets) Carets {
        return .{ .offset = &t.offset, .x = &t.x };
    }
};

fn testShape(text: []const u8, run: *shape.Run) !void {
    const face = try @import("../font/opentype.zig").Face.parse(shape.test_font, 0);
    try shape.shape(&face, text, run);
}

test "a ligature shares its advance among the characters it covers" {
    var cols: shape.TestRun = .{};
    var run = cols.run();
    try testShape("office", &run);
    var tc: TestCarets = .{};
    var c = tc.carets();
    try carets(&run, "office", &c);
    // o 605, ffi 946 for three characters (315 each, rounded down), c 480, e 564.
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5, 6 }, c.offset[0..c.len]);
    try std.testing.expectEqualSlices(i32, &.{ 0, 605, 920, 1235, 1551, 2031, 2595 }, c.x[0..c.len]);
    try std.testing.expectEqual(shape.width(&run), c.x[c.len - 1]);
}

test "no caret inside a character built from a base and marks" {
    var cols: shape.TestRun = .{};
    var run = cols.run();
    const text = "e\u{301}a\u{300}o\u{323}";
    try testShape(text, &run);
    var tc: TestCarets = .{};
    var c = tc.carets();
    try carets(&run, text, &c);
    // Three graphemes of three bytes each; marks take no advance.
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 6, 9 }, c.offset[0..c.len]);
    try std.testing.expectEqualSlices(i32, &.{ 0, 564, 1125, 1730 }, c.x[0..c.len]);
    // An offset inside e + acute snaps back to before the e.
    try std.testing.expectEqual(0, caretX(&c, 1));
    try std.testing.expectEqual(564, caretX(&c, 3));
}

test "a click goes to the nearest caret stop" {
    var cols: shape.TestRun = .{};
    var run = cols.run();
    try testShape("office", &run);
    var tc: TestCarets = .{};
    var c = tc.carets();
    try carets(&run, "office", &c);
    try std.testing.expectEqual(0, hit(&c, -50));
    try std.testing.expectEqual(1, hit(&c, 700));
    try std.testing.expectEqual(2, hit(&c, 900)); // inside the ffi ligature
    try std.testing.expectEqual(3, hit(&c, 1300));
    try std.testing.expectEqual(6, hit(&c, 9000));
    // Every stop round-trips.
    for (c.offset[0..c.len], c.x[0..c.len]) |o, x| try std.testing.expectEqual(o, hit(&c, x));
}

test "too few stops fail" {
    var cols: shape.TestRun = .{};
    var run = cols.run();
    try testShape("office", &run);
    var tc: TestCarets = .{};
    var c = tc.carets();
    c.offset = c.offset[0..3];
    try std.testing.expectError(error.NoSpace, carets(&run, "office", &c));
}
