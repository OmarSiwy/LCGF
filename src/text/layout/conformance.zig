//! BidiCharacterTest.txt through text layout: each line's text one glyph per code point, broken
//! (no wrapping), placed and reordered by `lines.reorder`, must show its glyphs left to right in
//! the file's visual order, with the file's levels. `zig build text-conformance`.
//!
//! `reorder` takes the paragraph direction from the text (P2, P3), so lines whose given
//! direction differs from that are left out, as are lines with a mandatory break inside
//! (layout splits paragraphs there; the file does not).

const std = @import("std");
const lcgr = @import("lcgr");
const lines = lcgr.text_lines;
const bidi = lcgr.unicode_bidi;
const property = lcgr.unicode_property;
const Para = lcgr.text_layout_tests.golden.Para;

test "BidiCharacterTest.txt: reordered lines draw in visual order" {
    var raw: [64 * 1024]u8 align(lcgr.mem.column_align) = undefined;
    var carver: lcgr.mem.Carver = .{ .buf = &raw };
    const s = carver.columns(lines.BidiScratch, 256);
    var p: Para = .{};
    var cps: [256]u21 = undefined;
    var want: [256]u8 = undefined;
    var want_order: [256]u32 = undefined;
    var by_x: [256]u32 = undefined;
    var text_buf: [1024]u8 = undefined;
    var file = std.mem.splitScalar(u8, @embedFile("BidiCharacterTest.txt"), '\n');
    var line: usize = 0;
    var cases: usize = 0;
    var rtl: usize = 0;
    next: while (file.next()) |ln| {
        line += 1;
        if (ln.len == 0 or ln[0] == '#') continue;
        var f = std.mem.splitScalar(u8, ln, ';');
        var n: usize = 0;
        var tok = std.mem.tokenizeAny(u8, f.next().?, " ");
        var bytes: usize = 0;
        while (tok.next()) |t| : (n += 1) {
            cps[n] = std.fmt.parseInt(u21, t, 16) catch unreachable;
            switch (property.line(cps[n]).lb) {
                .BK, .CR, .LF, .NL => continue :next,
                else => {},
            }
            bytes += std.unicode.utf8Encode(cps[n], text_buf[bytes..]) catch unreachable;
        }
        const dir = f.next().?[0] - '0';
        const para = f.next().?[0] - '0';
        bidi.classes(cps[0..n], s.orig[0..n]);
        const own = bidi.paragraphLevel(s.orig[0..n], .{ .cls = s.cls, .next = s.next, .pair = s.pair });
        if (dir != 2 and dir != own) continue;
        var levels = std.mem.tokenizeAny(u8, f.next().?, " ");
        for (want[0..n]) |*w| {
            const t = levels.next().?;
            w.* = if (t[0] == 'x') 0xff else std.fmt.parseInt(u8, t, 10) catch unreachable;
        }
        var n_order: usize = 0;
        var ord = std.mem.tokenizeAny(u8, f.next().?, " \r");
        while (ord.next()) |t| : (n_order += 1) want_order[n_order] = std.fmt.parseInt(u32, t, 10) catch unreachable;

        const text = text_buf[0..bytes];
        p.fixed(text, 10);
        try lines.breakLines(&p.g, text, std.math.inf(f32), &p.l);
        try std.testing.expectEqual(1, p.l.len);
        lines.place(&p.l, &p.g, text, &.{.{ .ascent = 8, .descent = 2 }}, .{});
        try lines.reorder(&p.l, &p.g, text, s);
        // Glyphs left to right, those X9 removes left out as the file does.
        var k: usize = 0;
        for (0..n) |i| if (want[i] != 0xff) {
            by_x[k] = @intCast(i);
            k += 1;
        };
        std.mem.sort(u32, by_x[0..k], &p.g, struct {
            fn lt(g: *const lines.Glyphs, a: u32, b: u32) bool {
                return g.x[a] < g.x[b];
            }
        }.lt);
        std.testing.expectEqualSlices(u32, want_order[0..n_order], by_x[0..k]) catch |err| {
            std.debug.print("BidiCharacterTest.txt line {d}\n", .{line});
            return err;
        };
        for (want[0..n], p.g.level[0..n]) |w, l| if (w != 0xff) try std.testing.expectEqual(w, l);
        cases += 1;
        rtl += @intFromBool(para == 1);
    }
    std.debug.print("text-conformance: {d} lines in visual order, {d} right-to-left paragraphs\n", .{ cases, rtl });
    try std.testing.expect(cases > 45_000 and rtl > 20_000);
}
