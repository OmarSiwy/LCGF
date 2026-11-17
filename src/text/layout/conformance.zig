//! BidiCharacterTest.txt through text layout: each line's text one glyph per code point, broken
//! (no wrapping), placed and reordered by `lines.reorder` in the line's given paragraph
//! direction, must show its glyphs left to right in the file's visual order, with the file's
//! levels. `zig build text-conformance`.
//!
//! The file has no line with a mandatory break inside, so each line is checked twice: alone,
//! and as the second paragraph of a text whose first paragraph (right to left, with an
//! isolate and an embedding left open) ends in U+2029 PARAGRAPH SEPARATOR. Layout splits
//! paragraphs there (P1), so the second must come out as if alone.

const std = @import("std");
const lcgf = @import("lcgf");
const lines = lcgf.text_lines;
const bidi = lcgf.unicode_bidi;
const Para = lcgf.text_layout_tests.golden.Para;

/// RLI, RLE, alef, "a", then U+2029: five code points, five glyphs, one line of its own.
const before = "\u{2067}\u{202B}\u{5D0}a\u{2029}";

const Case = struct {
    n: usize,
    /// The file's levels, 0xff where X9 removes the character.
    want: []const u8,
    want_order: []const u32,
};

test "BidiCharacterTest.txt: reordered lines draw in visual order" {
    var raw: [64 * 1024]u8 align(lcgf.mem.column_align) = undefined;
    var carver: lcgf.mem.Carver = .{ .buf = &raw };
    const s = carver.columns(lines.BidiScratch, 256);
    var p: Para = .{};
    var want: [256]u8 = undefined;
    var want_order: [256]u32 = undefined;
    var text_buf: [1024]u8 = undefined;
    @memcpy(text_buf[0..before.len], before);
    var file = std.mem.splitScalar(u8, @embedFile("BidiCharacterTest.txt"), '\n');
    var line: usize = 0;
    var cases: usize = 0;
    var rtl: usize = 0;
    var given: usize = 0;
    while (file.next()) |ln| {
        line += 1;
        if (ln.len == 0 or ln[0] == '#') continue;
        var f = std.mem.splitScalar(u8, ln, ';');
        var n: usize = 0;
        var tok = std.mem.tokenizeAny(u8, f.next().?, " ");
        var bytes: usize = before.len;
        while (tok.next()) |t| : (n += 1) {
            const cp = std.fmt.parseInt(u21, t, 16) catch unreachable;
            bytes += std.unicode.utf8Encode(cp, text_buf[bytes..]) catch unreachable;
        }
        const dir: bidi.Direction = @fromBackingInt(@intCast(f.next().?[0] - '0'));
        const para = f.next().?[0] - '0';
        var levels = std.mem.tokenizeAny(u8, f.next().?, " ");
        for (want[0..n]) |*w| {
            const t = levels.next().?;
            w.* = if (t[0] == 'x') 0xff else std.fmt.parseInt(u8, t, 10) catch unreachable;
        }
        var n_order: usize = 0;
        var ord = std.mem.tokenizeAny(u8, f.next().?, " \r");
        while (ord.next()) |t| : (n_order += 1) want_order[n_order] = std.fmt.parseInt(u32, t, 10) catch unreachable;
        const c: Case = .{ .n = n, .want = want[0..n], .want_order = want_order[0..n_order] };

        check(&p, s, text_buf[before.len..bytes], dir, 0, c) catch |err| {
            std.debug.print("BidiCharacterTest.txt line {d}\n", .{line});
            return err;
        };
        check(&p, s, text_buf[0..bytes], dir, 1, c) catch |err| {
            std.debug.print("BidiCharacterTest.txt line {d}, after a paragraph\n", .{line});
            return err;
        };
        cases += 1;
        rtl += @intFromBool(para == 1);
        given += @intFromBool(dir != .auto);
    }
    std.debug.print("text-conformance: {d} lines in visual order, {d} right-to-left paragraphs, {d} in a given direction, each alone and after a paragraph separator\n", .{ cases, rtl, given });
    try std.testing.expect(cases > 90_000 and rtl > 40_000 and given > 50_000);
}

/// Lays `text` out and checks its line `k` (0 alone, 1 after `before`) against the file.
fn check(p: *Para, s: lines.BidiScratch, text: []const u8, dir: bidi.Direction, k: u32, c: Case) !void {
    p.fixed(text, 10);
    try lines.breakLines(&p.g, text, std.math.inf(f32), &p.l);
    try std.testing.expectEqual(k + 1, p.l.len);
    const a: lines.Align = .{ .direction = dir };
    lines.place(&p.l, &p.g, text, &.{.{ .ascent = 8, .descent = 2 }}, a);
    try lines.reorder(&p.l, &p.g, text, a, s);
    const first = p.l.first[k];
    try std.testing.expectEqual(c.n, p.l.end[k] - first);
    // Glyphs left to right, those X9 removes left out as the file does.
    var by_x: [256]u32 = undefined;
    var m: usize = 0;
    for (0..c.n) |i| if (c.want[i] != 0xff) {
        by_x[m] = @intCast(i);
        m += 1;
    };
    const x = p.g.x[first..];
    std.mem.sort(u32, by_x[0..m], x, struct {
        fn lt(xs: []const f32, l: u32, r: u32) bool {
            return xs[l] < xs[r];
        }
    }.lt);
    try std.testing.expectEqualSlices(u32, c.want_order, by_x[0..m]);
    for (c.want, p.g.level[first..][0..c.n]) |w, l| if (w != 0xff) try std.testing.expectEqual(w, l);
}
