//! The Unicode 16.0.0 conformance files, run against the package: `zig build conformance`.
//! A separate test step because they take seconds, not milliseconds, in Debug.

const std = @import("std");
const lcgr = @import("lcgr");
const property = lcgr.unicode_property;

const grapheme_test = @embedFile("GraphemeBreakTest.txt");
const word_test = @embedFile("WordBreakTest.txt");
const line_test = @embedFile("LineBreakTest.txt");

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

/// LineBreaks yields opportunities; the test files mark every opportunity, mandatory or not.
const LineOffsets = struct {
    text: []const u8,
    it: ?lcgr.unicode_line.LineBreaks = null,

    fn next(s: *LineOffsets) ?usize {
        if (s.it == null) s.it = .{ .text = s.text };
        return if (s.it.?.next()) |o| o.pos else null;
    }
};

test "LineBreakTest.txt" {
    try expectBoundaries(LineOffsets, line_test);
}

const bidi = lcgr.unicode_bidi;
const bidi_test = @embedFile("BidiTest.txt");
const bidi_character_test = @embedFile("BidiCharacterTest.txt");

const BidiBuffers = struct {
    orig: [256]property.BidiClass = undefined,
    cls: [256]property.BidiClass = undefined,
    next: [256]u32 = undefined,
    pair: [256]u32 = undefined,
    levels: [256]u8 = undefined,

    fn scratch(b: *BidiBuffers) bidi.Scratch {
        return .{ .cls = &b.cls, .next = &b.next, .pair = &b.pair };
    }
};

/// Parses "1 x 0 2" into levels with 0xff for x.
fn parseLevels(s: []const u8, out: []u8) usize {
    var n: usize = 0;
    var tok = std.mem.tokenizeAny(u8, s, " \t");
    while (tok.next()) |t| : (n += 1) out[n] = if (t[0] == 'x') 0xff else std.fmt.parseInt(u8, t, 10) catch unreachable;
    return n;
}

fn expectLevels(want: []const u8, got: []const u8, line: usize) !void {
    for (want, got[0..want.len]) |w, g| if (w != 0xff and w != g) {
        std.debug.print("line {d}: levels want {any} got {any}\n", .{ line, want, got[0..want.len] });
        return error.TestUnexpectedLevels;
    };
}

test "BidiTest.txt: levels and order" {
    var b: BidiBuffers = .{};
    var want: [256]u8 = undefined;
    var n_want: usize = 0;
    var want_order: [256]u32 = undefined;
    var n_order: usize = 0;
    var order: [256]u32 = undefined;
    var lines = std.mem.splitScalar(u8, bidi_test, '\n');
    var line: usize = 0;
    var cases: usize = 0;
    while (lines.next()) |ln| {
        line += 1;
        if (ln.len == 0 or ln[0] == '#') continue;
        if (std.mem.startsWith(u8, ln, "@Levels:")) {
            n_want = parseLevels(ln["@Levels:".len..], &want);
            continue;
        }
        if (std.mem.startsWith(u8, ln, "@Reorder:")) {
            n_order = parseOrder(ln["@Reorder:".len..], &want_order);
            continue;
        }
        if (ln[0] == '@') continue;
        const semi = std.mem.indexOfScalar(u8, ln, ';').?;
        var n: usize = 0;
        var tok = std.mem.tokenizeAny(u8, ln[0..semi], " \t");
        while (tok.next()) |t| : (n += 1) b.orig[n] = std.meta.stringToEnum(property.BidiClass, t).?;
        std.debug.assert(n == n_want);
        const set = std.fmt.parseInt(u8, std.mem.trim(u8, ln[semi + 1 ..], " \t\r"), 16) catch unreachable;
        for ([_]?u8{ null, 0, 1 }, 0..) |dir, bit| {
            if (set & (@as(u8, 1) << @intCast(bit)) == 0) continue;
            const orig = b.orig[0..n];
            const para = dir orelse bidi.paragraphLevel(orig, b.scratch());
            bidi.resolve(orig, &.{}, para, &b.levels, b.scratch());
            bidi.lineLevels(orig, b.levels[0..n], para);
            try expectLevels(want[0..n], &b.levels, line);
            try expectOrder(want_order[0..n_order], order[0..visualOrder(want[0..n], &b.levels, &order)], line);
            cases += 1;
        }
    }
    try std.testing.expect(cases > 400_000);
}

test "BidiCharacterTest.txt: levels and order" {
    var b: BidiBuffers = .{};
    var cps: [256]u21 = undefined;
    var want: [256]u8 = undefined;
    var lines = std.mem.splitScalar(u8, bidi_character_test, '\n');
    var line: usize = 0;
    var cases: usize = 0;
    while (lines.next()) |ln| : (line += 1) {
        if (ln.len == 0 or ln[0] == '#') continue;
        var f = std.mem.splitScalar(u8, ln, ';');
        var n: usize = 0;
        var tok = std.mem.tokenizeAny(u8, f.next().?, " ");
        while (tok.next()) |t| : (n += 1) cps[n] = std.fmt.parseInt(u21, t, 16) catch unreachable;
        const dir = f.next().?[0] - '0';
        const want_para = f.next().?[0] - '0';
        std.debug.assert(parseLevels(f.next().?, &want) == n);
        const orig = b.orig[0..n];
        bidi.classes(cps[0..n], orig);
        const para = if (dir == 2) bidi.paragraphLevel(orig, b.scratch()) else dir;
        try std.testing.expectEqual(want_para, para);
        bidi.resolve(orig, cps[0..n], para, &b.levels, b.scratch());
        bidi.lineLevels(orig, b.levels[0..n], para);
        try expectLevels(want[0..n], &b.levels, line + 1);
        var want_order: [256]u32 = undefined;
        var order: [256]u32 = undefined;
        const n_order = parseOrder(f.next().?, &want_order);
        try expectOrder(want_order[0..n_order], order[0..visualOrder(want[0..n], &b.levels, &order)], line + 1);
        cases += 1;
    }
    try std.testing.expect(cases > 90_000);
}

/// L2 over the characters that have a level (the x ones are left out, as the files do), as
/// logical indices into the whole input.
fn visualOrder(want_levels: []const u8, levels: []const u8, out: []u32) usize {
    var kept_levels: [256]u8 = undefined;
    var kept_index: [256]u32 = undefined;
    var k: usize = 0;
    for (want_levels, levels[0..want_levels.len], 0..) |w, l, i| if (w != 0xff) {
        kept_levels[k] = l;
        kept_index[k] = @intCast(i);
        k += 1;
    };
    var order: [256]u32 = undefined;
    bidi.reorder(kept_levels[0..k], order[0..k]);
    for (order[0..k], out[0..k]) |o, *v| v.* = kept_index[o];
    return k;
}

fn parseOrder(s: []const u8, out: []u32) usize {
    var n: usize = 0;
    var tok = std.mem.tokenizeAny(u8, s, " \t\r");
    while (tok.next()) |t| : (n += 1) out[n] = std.fmt.parseInt(u32, t, 10) catch unreachable;
    return n;
}

fn expectOrder(want: []const u32, got: []const u32, line: usize) !void {
    std.testing.expectEqualSlices(u32, want, got) catch |err| {
        std.debug.print("line {d}: order\n", .{line});
        return err;
    };
}

test "Scripts.txt: every code point" {
    // Parsed here independently of gen.zig: unlisted code points are Unknown.
    const want = try std.testing.allocator.alloc(property.Script, 0x110000);
    defer std.testing.allocator.free(want);
    @memset(want, .Unknown);
    var lines = std.mem.splitScalar(u8, @embedFile("Scripts.txt"), '\n');
    while (lines.next()) |ln| {
        const data = ln[0 .. std.mem.indexOfScalar(u8, ln, '#') orelse ln.len];
        const semi = std.mem.indexOfScalar(u8, data, ';') orelse continue;
        const range = std.mem.trim(u8, data[0..semi], " ");
        var ends = std.mem.splitSequence(u8, range, "..");
        const lo = try std.fmt.parseInt(u21, ends.next().?, 16);
        const hi = if (ends.next()) |h| try std.fmt.parseInt(u21, h, 16) else lo;
        const s = std.meta.stringToEnum(property.Script, std.mem.trim(u8, data[semi + 1 ..], " ")).?;
        @memset(want[lo .. @as(usize, hi) + 1], s);
    }
    for (want, 0..) |s, cp| try std.testing.expectEqual(s, property.script(@intCast(cp)));
}

test "script runs: one script each, Common only where nothing else" {
    const text = "1. Hello, Κόσμε (мир) — こんにちは「世界」! مرحبا 123 שָׁלוֹם\u{301}";
    var it = lcgr.unicode_script.Scripts{ .text = text };
    var start: usize = 0;
    var runs: usize = 0;
    var prev: ?property.Script = null;
    while (it.next()) |r| : (runs += 1) {
        try std.testing.expect(r.end > start);
        try std.testing.expect(prev == null or prev.? != r.script);
        var i = start;
        while (i < r.end) {
            const d = lcgr.unicode_utf8.decode(text, i);
            const s = property.script(d.cp);
            if (s != .Common and s != .Inherited) try std.testing.expectEqual(s, r.script);
            i += d.len;
        }
        start = r.end;
        prev = r.script;
    }
    try std.testing.expectEqual(text.len, start);
    // Latin, Greek, Cyrillic, Greek (")" closes the Greek bracket), Hiragana, Han, Hiragana
    // ("」" closes the Hiragana bracket), Arabic, Hebrew.
    try std.testing.expectEqual(9, runs);
}

test "lookup speed" {
    // Prints ns per line+grapheme lookup pair over every 7th code point; read it in ReleaseFast
    // (`zig build conformance -Doptimize=ReleaseFast`). Timing only, nothing asserted.
    var ts0: std.os.linux.timespec = undefined;
    var ts1: std.os.linux.timespec = undefined;
    var acc: u32 = 0;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts0);
    for (0..20) |r| {
        var cp: u32 = @intCast(r);
        while (cp < 0x110000) : (cp += 7) acc +%= @as(u16, @bitCast(property.line(@intCast(cp)))) +% @as(u8, @bitCast(property.grapheme(@intCast(cp))));
    }
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts1);
    const ns: u64 = @intCast((ts1.sec - ts0.sec) * 1_000_000_000 + (ts1.nsec - ts0.nsec));
    const pairs: u64 = 20 * (0x110000 / 7);
    std.debug.print("unicode lookups: {d}.{d:0>2} ns per line+grapheme pair (checksum {d})\n", .{ ns / pairs, (ns * 100 / pairs) % 100, acc });
}
