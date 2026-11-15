//! The Unicode 16.0.0 conformance files, run against the package: `zig build conformance`.
//! A separate test step because they take seconds, not milliseconds, in Debug.

const std = @import("std");
const lcgr = @import("lcgr");
const property = lcgr.unicode_property;

const grapheme_test = @embedFile("data/GraphemeBreakTest.txt");
const word_test = @embedFile("data/WordBreakTest.txt");
const line_test = @embedFile("data/LineBreakTest.txt");

/// One line of a *BreakTest.txt file: code points, whether a boundary precedes each position
/// (`breaks[i]` is before `cps[i]`, `breaks[cps.len]` is the end), and the class name the comment
/// gives each code point.
const Case = struct {
    cps: [256]u21 = undefined,
    breaks: [257]bool = undefined,
    names: [256][]const u8 = undefined,
    len: usize = 0,
    line: usize = 0,
};

const Cases = struct {
    text: []const u8,
    pos: usize = 0,
    line: usize = 0,

    fn next(it: *Cases) ?Case {
        while (it.pos < it.text.len) {
            const end = std.mem.indexOfScalarPos(u8, it.text, it.pos, '\n') orelse it.text.len;
            const ln = it.text[it.pos..end];
            it.pos = end + 1;
            it.line += 1;
            const hash = std.mem.indexOfScalar(u8, ln, '#') orelse ln.len;
            var c: Case = .{ .line = it.line };
            var tok = std.mem.tokenizeAny(u8, ln[0..hash], " \t");
            while (tok.next()) |t| {
                if (std.mem.eql(u8, t, "÷") or std.mem.eql(u8, t, "×")) {
                    c.breaks[c.len] = std.mem.eql(u8, t, "÷");
                } else {
                    c.cps[c.len] = std.fmt.parseInt(u21, t, 16) catch unreachable;
                    c.len += 1;
                }
            }
            if (c.len == 0) continue;
            // Comment: "÷ [0.2] NAME (Class) × [9.0] NAME (Class) ÷ [0.3]". The class is the
            // last parenthesis before each rule marker after the first.
            const comment = ln[hash..];
            var n: usize = 0;
            var i: usize = 0;
            while (std.mem.indexOfPos(u8, comment, i, " [")) |m| : (i = m + 2) {
                const close = std.mem.lastIndexOfScalar(u8, comment[0..m], ')') orelse continue;
                if (close + 4 != m) continue; // the marker must follow ") ÷" or ") ×" (2 bytes each)
                const open = std.mem.lastIndexOfScalar(u8, comment[0..close], '(').?;
                c.names[n] = comment[open + 1 .. close];
                n += 1;
            }
            std.debug.assert(n == c.len);
            return c;
        }
        return null;
    }
};

fn prefix(name: []const u8) []const u8 {
    return name[0 .. std.mem.indexOfScalar(u8, name, '_') orelse name.len];
}

test "property: classes named in GraphemeBreakTest.txt" {
    var it = Cases{ .text = grapheme_test };
    var checked: usize = 0;
    while (it.next()) |c| for (c.cps[0..c.len], c.names[0..c.len]) |cp, name| {
        const g = property.grapheme(cp);
        const want: property.Gcb = if (std.mem.eql(u8, name, "RI"))
            .Regional_Indicator
        else if (std.mem.eql(u8, name, "ExtPict") or std.mem.startsWith(u8, name, "ConjunctLinkingScripts"))
            .Other
        else
            std.meta.stringToEnum(property.Gcb, prefix(name)).?;
        try std.testing.expectEqual(want, g.gcb);
        if (std.mem.eql(u8, name, "ExtPict")) try std.testing.expect(g.ext_pict);
        if (std.mem.indexOf(u8, name, "LinkingConsonant") != null) try std.testing.expectEqual(property.InCB.Consonant, g.incb);
        if (std.mem.indexOf(u8, name, "ConjunctLinker") != null) try std.testing.expectEqual(property.InCB.Linker, g.incb);
        checked += 1;
    };
    try std.testing.expect(checked > 2000);
}

test "property: classes named in WordBreakTest.txt" {
    var it = Cases{ .text = word_test };
    while (it.next()) |c| for (c.cps[0..c.len], c.names[0..c.len]) |cp, name| {
        const w = property.word(cp);
        const want: property.Wb = if (std.mem.eql(u8, name, "RI"))
            .Regional_Indicator
        else if (std.mem.eql(u8, name, "ExtPict"))
            .Other
        else
            std.meta.stringToEnum(property.Wb, name) orelse std.meta.stringToEnum(property.Wb, prefix(name)).?;
        try std.testing.expectEqual(want, w.wb);
        if (std.mem.eql(u8, name, "ExtPict")) try std.testing.expect(w.ext_pict);
    };
}

test "property: classes named in LineBreakTest.txt" {
    var it = Cases{ .text = line_test };
    var checked: usize = 0;
    while (it.next()) |c| for (c.cps[0..c.len], c.names[0..c.len]) |cp, name| {
        if (std.mem.eql(u8, name, "Other")) continue; // one sample, an unassigned code point
        const base = prefix(name);
        // "CM1" is a sample set of CM, not a class; B2, H2 and H3 are classes.
        const want = std.meta.stringToEnum(property.Lb, base) orelse std.meta.stringToEnum(property.Lb, base[0 .. base.len - 1]) orelse {
            std.debug.print("line {d}: class '{s}'\n", .{ c.line, name });
            return error.UnknownClass;
        };
        try std.testing.expectEqual(want, property.line(cp).lb);
        checked += 1;
    };
    try std.testing.expect(checked > 40_000);
}

/// Runs a segmenter over every line of a *BreakTest.txt file: the offsets `Iter.next` returns
/// must be exactly the boundaries the line marks with ÷ (after the first code point).
fn expectBoundaries(comptime Iter: type, file: []const u8) !void {
    var it = Cases{ .text = file };
    var cases: usize = 0;
    while (it.next()) |c| : (cases += 1) {
        var buf: [1024]u8 = undefined;
        var want: [257]usize = undefined;
        var n_want: usize = 0;
        var len: usize = 0;
        for (c.cps[0..c.len], 1..) |cp, i| {
            len += std.unicode.utf8Encode(cp, buf[len..]) catch unreachable;
            if (c.breaks[i]) {
                want[n_want] = len;
                n_want += 1;
            }
        }
        var seg = Iter{ .text = buf[0..len] };
        var got: [257]usize = undefined;
        var n_got: usize = 0;
        while (seg.next()) |e| : (n_got += 1) got[n_got] = e;
        std.testing.expectEqualSlices(usize, want[0..n_want], got[0..n_got]) catch |err| {
            std.debug.print("line {d}: {s}\n", .{ c.line, file[lineStart(file, c.line)..][0..@min(160, file.len - lineStart(file, c.line))] });
            return err;
        };
    }
    try std.testing.expect(cases > 1000);
}

fn lineStart(file: []const u8, line: usize) usize {
    var pos: usize = 0;
    for (1..line) |_| pos = std.mem.indexOfScalarPos(u8, file, pos, '\n').? + 1;
    return pos;
}

test "GraphemeBreakTest.txt" {
    try expectBoundaries(lcgr.unicode_grapheme.Graphemes, grapheme_test);
}

test "WordBreakTest.txt" {
    try expectBoundaries(lcgr.unicode_word.Words, word_test);
}
