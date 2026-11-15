//! Simple shaper: UTF-8 text to positioned glyphs for one face. Tier 0.
//!
//! Output is a glyph run, columns the caller owns (`Run`): glyph id, the byte offset of the text
//! the glyph came from (its cluster), advance and offsets, all in font units so one run serves
//! every pixel size (multiply by `px / units_per_em`). This is the data a renderer turns into
//! quads and an editor maps the cursor through; nothing is retained.
//!
//! What this shaper does: cmap lookup, ligatures (GSUB 'liga', lookup type 4), hmtx advances,
//! pair kerning (GPOS 'kern' or the kern table, via `Face.kerning`), skipping marks, and mark
//! attachment (GPOS 'mark' and 'mkmk', lookup types 4 and 6; marks are GDEF class 3 and take
//! no advance). Text is taken as one left-to-right run of one script; bidi
//! and script itemisation run before it (src/text/unicode/). Results match HarfBuzz for that
//! case (testdata/hb.txt).
//!
//! It plugs into the measure protocol (src/text/protocol.zig) as `measure`: one more font that
//! fills `Texts.w` and `Texts.h` for the runs whose `font` column names it.

const std = @import("std");
const opentype = @import("../font/opentype.zig");
const utf8 = @import("../unicode/utf8.zig");
const Texts = @import("../../core/texts.zig").Texts;
const Strings = @import("../../core/strings.zig").Strings;

const layout = @import("layout.zig");

const Face = opentype.Face;

/// A shaped glyph run: `len` rows of glyph columns in visual (here: logical) order. Capacity is
/// the slices' length, all equal.
pub const Run = struct {
    glyph: []u16,
    /// Byte offset in the text of the first character of the glyph's cluster.
    cluster: []u32,
    /// Pen advance after the glyph, font units.
    advance: []i32,
    /// Where the glyph is drawn relative to the pen, font units, y up.
    x_offset: []i32,
    y_offset: []i32,
    len: u32 = 0,
};

/// Which steps `Shaper.shape` runs. All on is what HarfBuzz does by default for these features.
pub const Features = struct {
    liga: bool = true,
    kern: bool = true,
    /// Mark attachment, 'mark' and 'mkmk'.
    mark: bool = true,
};

/// A face with its layout tables located and the lookups of each feature collected, once.
/// Damaged layout tables cost the features they hold, not the face.
pub const Shaper = struct {
    face: Face,
    gsub: []const u8 = &.{},
    liga: layout.Lookups = .{},
    gpos: []const u8 = &.{},
    /// 'mark' and 'mkmk' lookups, merged in LookupList order.
    marks: layout.Lookups = .{},
    /// GDEF GlyphClassDef: class 3 is a mark. Empty without GDEF: then nothing is a mark.
    classes: []const u8 = &.{},

    pub fn init(face: Face) Shaper {
        var s: Shaper = .{ .face = face };
        s.gsub = (face.dir.find(opentype.tag("GSUB")) catch null) orelse &.{};
        layout.featureLookups(s.gsub, opentype.tag("liga"), &s.liga) catch {
            s.liga = .{};
        };
        s.gpos = (face.dir.find(opentype.tag("GPOS")) catch null) orelse &.{};
        for ([_]u32{ opentype.tag("mark"), opentype.tag("mkmk") }) |t| layout.featureLookups(s.gpos, t, &s.marks) catch {
            s.marks = .{};
            break;
        };
        const gdef = (face.dir.find(opentype.tag("GDEF")) catch null) orelse &.{};
        // GlyphClassDef offset at 4; 0 (or unreadable) means no classes.
        const off = layout.read(u16, gdef, 4) catch 0;
        s.classes = if (off == 0 or off > gdef.len) &.{} else gdef[off..];
        return s;
    }

    /// Whether glyph `g` is a mark (GDEF glyph class 3).
    pub fn isMark(s: *const Shaper, g: u16) bool {
        return (layout.classOf(s.classes, g) catch 0) == 3;
    }

    /// Shapes `text` into `run` (replacing what it held). Fails with `error.NoSpace`, `run.len`
    /// then unspecified, when the run's columns are too short for the text's code points.
    pub fn shape(s: *const Shaper, text: []const u8, run: *Run, features: Features) error{NoSpace}!void {
        try map(&s.face, text, run);
        if (features.liga) for (s.liga.slice()) |index| s.ligatures(index, run) catch {};
        advances(&s.face, run);
        if (features.mark) for (run.glyph[0..run.len], run.advance[0..run.len]) |g, *a| {
            a.* = if (s.isMark(g)) 0 else a.*;
        };
        if (features.kern) s.kern(run);
        if (features.mark) for (s.marks.slice()) |index| s.attach(index, run) catch {};
    }

    /// Pair kerning: each glyph's advance changes by the kerning with the next glyph that is
    /// not a mark (kern lookups skip marks, so a mark between two letters keeps their pair).
    fn kern(s: *const Shaper, run: *Run) void {
        var k: u32 = 0;
        while (k < run.len) : (k += 1) {
            if (s.isMark(run.glyph[k])) continue;
            var next = k + 1;
            while (next < run.len and s.isMark(run.glyph[next])) next += 1;
            if (next == run.len) break;
            run.advance[k] += s.face.kerning(run.glyph[k], run.glyph[next]);
        }
    }

    /// Applies GPOS lookup `index` if it attaches marks: mark-to-base (type 4) puts a mark's
    /// anchor on the anchor of the closest glyph before it that is not a mark; mark-to-mark
    /// (type 6) on the anchor of the mark right before it. Offsets are relative to the mark's
    /// own pen position, as HarfBuzz gives them: the base's offset, plus the anchor difference,
    /// minus the advances from the base to the mark.
    fn attach(s: *const Shaper, index: u16, run: *Run) layout.Error!void {
        const lk = try layout.lookup(s.gpos, index);
        const count = try layout.read(u16, lk, 4);
        var i: u32 = 1;
        while (i < run.len) : (i += 1) {
            if (!s.isMark(run.glyph[i])) continue;
            for (0..count) |t| {
                const st = try layout.subtable(lk, t, 9);
                if ((st.kind != 4 and st.kind != 6) or try layout.read(u16, st.data, 0) != 1) continue;
                const mark_index = (try layout.coverageIndex(try layout.at16(st.data, 2), run.glyph[i])) orelse continue;
                // The glyph the mark attaches to.
                var base = i - 1;
                if (st.kind == 4) {
                    while (base > 0 and s.isMark(run.glyph[base])) base -= 1;
                    if (s.isMark(run.glyph[base])) continue;
                } else if (!s.isMark(run.glyph[base])) continue;
                const base_index = (try layout.coverageIndex(try layout.at16(st.data, 4), run.glyph[base])) orelse continue;
                const classes = try layout.read(u16, st.data, 6);
                const marks = try layout.at16(st.data, 8);
                const bases = try layout.at16(st.data, 10);
                if (mark_index >= try layout.read(u16, marks, 0) or base_index >= try layout.read(u16, bases, 0)) continue;
                const rec = 2 + @as(usize, mark_index) * 4;
                const class = try layout.read(u16, marks, rec);
                if (class >= classes) continue;
                const mark_anchor = try anchor(try layout.at16(marks, rec + 2));
                const off = try layout.read(u16, bases, 2 + (@as(usize, base_index) * classes + class) * 2);
                if (off == 0 or off > bases.len) continue; // no anchor for this class
                const base_anchor = try anchor(bases[off..]);
                var between: i32 = 0;
                for (run.advance[base..i]) |a| between += a;
                run.x_offset[i] = run.x_offset[base] + base_anchor[0] - mark_anchor[0] - between;
                run.y_offset[i] = run.y_offset[base] + base_anchor[1] - mark_anchor[1];
                break;
            }
        }
    }

    /// Applies GSUB lookup `index` (ligature substitution, type 4) along the run: at each glyph
    /// the first ligature of its set whose components follow it replaces them all. The ligature
    /// keeps the cluster of its first component. Other lookup types are skipped.
    fn ligatures(s: *const Shaper, index: u16, run: *Run) layout.Error!void {
        const lk = try layout.lookup(s.gsub, index);
        const count = try layout.read(u16, lk, 4);
        var i: u32 = 0;
        while (i < run.len) : (i += 1) {
            subtables: for (0..count) |t| {
                const st = try layout.subtable(lk, t, 7);
                if (st.kind != 4 or try layout.read(u16, st.data, 0) != 1) continue;
                const cov = try layout.at16(st.data, 2);
                const set_index = (try layout.coverageIndex(cov, run.glyph[i])) orelse continue;
                if (set_index >= try layout.read(u16, st.data, 4)) continue;
                const set = try layout.at16(st.data, 6 + @as(usize, set_index) * 2);
                for (0..try layout.read(u16, set, 0)) |l| {
                    const lig = try layout.at16(set, 2 + l * 2);
                    const comps = try layout.read(u16, lig, 2);
                    if (comps == 0 or i + comps > run.len) continue;
                    const matched = for (1..comps) |c| {
                        if (run.glyph[i + c] != try layout.read(u16, lig, 4 + (c - 1) * 2)) break false;
                    } else true;
                    if (!matched) continue;
                    run.glyph[i] = try layout.read(u16, lig, 0);
                    remove(run, i + 1, comps - 1);
                    break :subtables;
                }
                // The first subtable that covers the glyph decides, matched or not.
                break;
            }
        }
    }
};

/// Shapes `text` with every feature: the common case in one call.
pub fn shape(face: *const Face, text: []const u8, run: *Run) error{NoSpace}!void {
    const s: Shaper = .init(face.*);
    return s.shape(text, run, .{});
}

/// Code points to nominal glyphs, with clusters.
fn map(face: *const Face, text: []const u8, run: *Run) error{NoSpace}!void {
    run.len = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (run.len == run.glyph.len) return error.NoSpace;
        const d = utf8.decode(text, i);
        const k = run.len;
        run.glyph[k] = face.cmap.glyph(d.cp);
        run.cluster[k] = @intCast(i);
        run.len = k + 1;
        i += d.len;
    }
}

/// Drops `n` glyphs from row `at` on.
fn remove(run: *Run, at: u32, n: u32) void {
    if (n == 0) return;
    const len = run.len;
    std.mem.copyForwards(u16, run.glyph[at .. len - n], run.glyph[at + n .. len]);
    std.mem.copyForwards(u32, run.cluster[at .. len - n], run.cluster[at + n .. len]);
    run.len = len - n;
}

/// Nominal advances from hmtx, offsets zero.
fn advances(face: *const Face, run: *Run) void {
    for (run.glyph[0..run.len], run.advance[0..run.len], run.x_offset[0..run.len], run.y_offset[0..run.len]) |g, *a, *x, *y| {
        a.* = face.hMetrics(g).advance;
        x.* = 0;
        y.* = 0;
    }
}

/// The x, y of an Anchor table (formats 1 to 3 start alike; device and contour-point data
/// are hinting, not used unhinted).
fn anchor(a: []const u8) layout.Error![2]i32 {
    return .{ try layout.read(i16, a, 2), try layout.read(i16, a, 4) };
}

/// Total advance of the run, font units.
pub fn width(run: *const Run) i32 {
    var w: i32 = 0;
    for (run.advance[0..run.len]) |a| w += a;
    return w;
}

/// The measure step of the protocol for `face`: shapes every run of `tx` whose `font` column
/// is `font` and writes its single-line extent, `w` the shaped width and `h` the face's line
/// height (ascender - descender + line gap), in pixels. Other runs are left as they are.
/// `run` is scratch for one run's glyphs; a run that does not fit in it is measured as far as
/// it fits.
pub fn measure(shaper: *const Shaper, font: u16, tx: *Texts, strings: *const Strings, run: *Run) void {
    const face = &shaper.face;
    const c = &tx.c;
    const line: f32 = @floatFromInt(@as(i32, face.ascender) - face.descender + face.line_gap);
    const em: f32 = @floatFromInt(face.units_per_em);
    for (0..tx.len) |k| {
        // Shaping is per run and reads its bytes: not a row pass, so it may skip rows.
        if (c.font[k] != font) continue;
        const text = strings.get(.{ .start = c.start[k], .bytes = c.bytes[k] });
        shaper.shape(text, run, .{}) catch {};
        const scale = c.px[k] / em;
        c.w[k] = @as(f32, @floatFromInt(width(run))) * scale;
        c.h[k] = line * scale;
    }
}

// ---------------------------------------------------------------------------------------------
// Tests against HarfBuzz (testdata/make.py wrote hb.txt from testdata/shape.ttf).

pub const test_font = @embedFile("testdata/shape.ttf");
const hb_txt = @embedFile("testdata/hb.txt");

/// Columns for a test run.
pub const TestRun = struct {
    glyph: [64]u16 = undefined,
    cluster: [64]u32 = undefined,
    advance: [64]i32 = undefined,
    x_offset: [64]i32 = undefined,
    y_offset: [64]i32 = undefined,

    pub fn run(t: *TestRun) Run {
        return .{ .glyph = &t.glyph, .cluster = &t.cluster, .advance = &t.advance, .x_offset = &t.x_offset, .y_offset = &t.y_offset };
    }
};

/// One line of hb.txt: the features HarfBuzz shaped with, the text, and its glyphs.
pub const HbCase = struct {
    features: []const u8,
    text: []const u8,
    expected: TestRun,
    len: u32,
};

/// The cases of hb.txt shaped with exactly the feature set `features`. `text` points into
/// `buf`.
pub fn hbCases(features: []const u8, buf: *[1024]u8, out: []HbCase) !usize {
    var n: usize = 0;
    var used: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, hb_txt, '\n');
    while (lines.next()) |line| {
        var cols = std.mem.splitScalar(u8, line, '\t');
        const feats = cols.next().?;
        if (!std.mem.eql(u8, feats, features)) continue;
        const start = used;
        var cps = std.mem.tokenizeScalar(u8, cols.next().?, ' ');
        while (cps.next()) |hex| {
            const cp = try std.fmt.parseInt(u21, hex, 16);
            used += try std.unicode.utf8Encode(cp, buf[used..]);
        }
        var c: HbCase = .{ .features = feats, .text = buf[start..used], .expected = .{}, .len = 0 };
        var glyphs = std.mem.tokenizeScalar(u8, cols.next().?, ';');
        while (glyphs.next()) |g| : (c.len += 1) {
            var f = std.mem.splitScalar(u8, g, ',');
            c.expected.glyph[c.len] = try std.fmt.parseInt(u16, f.next().?, 10);
            c.expected.cluster[c.len] = try std.fmt.parseInt(u32, f.next().?, 10);
            c.expected.advance[c.len] = try std.fmt.parseInt(i32, f.next().?, 10);
            c.expected.x_offset[c.len] = try std.fmt.parseInt(i32, f.next().?, 10);
            c.expected.y_offset[c.len] = try std.fmt.parseInt(i32, f.next().?, 10);
        }
        out[n] = c;
        n += 1;
    }
    return n;
}

/// Shapes every case of `features` with `shaper` and compares each column with HarfBuzz's.
pub fn expectHb(features: []const u8, opts: Features) !usize {
    const shaper: Shaper = .init(try Face.parse(test_font, 0));
    var buf: [1024]u8 = undefined;
    var cases: [16]HbCase = undefined;
    const n = try hbCases(features, &buf, &cases);
    for (cases[0..n]) |*c| {
        var cols: TestRun = .{};
        var run = cols.run();
        try shaper.shape(c.text, &run, opts);
        errdefer std.debug.print("case {s} \"{s}\"\n", .{ c.features, c.text });
        try std.testing.expectEqual(c.len, run.len);
        try std.testing.expectEqualSlices(u16, c.expected.glyph[0..c.len], run.glyph[0..run.len]);
        try std.testing.expectEqualSlices(u32, c.expected.cluster[0..c.len], run.cluster[0..run.len]);
        try std.testing.expectEqualSlices(i32, c.expected.advance[0..c.len], run.advance[0..run.len]);
        try std.testing.expectEqualSlices(i32, c.expected.x_offset[0..c.len], run.x_offset[0..run.len]);
        try std.testing.expectEqualSlices(i32, c.expected.y_offset[0..c.len], run.y_offset[0..run.len]);
    }
    return n;
}

test "simple shaping matches HarfBuzz with kerning only" {
    try std.testing.expectEqual(6, try expectHb("kern", .{ .liga = false, .mark = false }));
}

test "ligatures match HarfBuzz" {
    // "office fluff fi" becomes o ffi c e space fl u ff space fi; "Ta\u{301}ffi" ends in ffi.
    try std.testing.expectEqual(6, try expectHb("kern,liga", .{ .mark = false }));
}

test "mark positioning matches HarfBuzz" {
    // e + acute, a + grave, o + dot below (mark-to-base), e + two acutes (mark-to-mark: the
    // second sits 229 units above the first), and a mark between T a and the ffi ligature.
    try std.testing.expectEqual(6, try expectHb("kern,liga,mark,mkmk", .{}));
}

test "marks are GDEF class 3 and take no advance" {
    const shaper: Shaper = .init(try Face.parse(test_font, 0));
    const face = &shaper.face;
    try std.testing.expect(shaper.isMark(face.cmap.glyph(0x301)));
    try std.testing.expect(!shaper.isMark(face.cmap.glyph('e')));
    // The Liberation test font of font-load has no GDEF: nothing is a mark there.
    const plain: Shaper = .init(try Face.parse(@import("../raster/raster.zig").test_font, 0));
    try std.testing.expect(!plain.isMark(plain.face.cmap.glyph('e')));
    try std.testing.expectEqual(0, plain.marks.len);
}

test "ligatures keep the first component's cluster" {
    const face = try Face.parse(test_font, 0);
    var cols: TestRun = .{};
    var run = cols.run();
    try shape(&face, "office", &run);
    try std.testing.expectEqual(4, run.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 4, 5 }, run.cluster[0..4]);
}

test "a run that does not fit fails" {
    const face = try Face.parse(test_font, 0);
    var cols: TestRun = .{};
    var run = cols.run();
    run.glyph = run.glyph[0..3];
    try std.testing.expectError(error.NoSpace, shape(&face, "office", &run));
}

test "measure fills the extents of the runs in this font" {
    const mem = @import("../../core/mem.zig");
    const face = try Face.parse(test_font, 0);
    var buf: [16 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var tx: Texts = .init(&carver, 4);
    var bytes: [64]u8 = undefined;
    var strings: Strings = .{ .buf = &bytes };
    const a = tx.push(0, strings.add("AVTavo"), &.{ .px = 20, .font = @fromBackingInt(1) });
    const b = tx.push(1, strings.add("AVTavo"), &.{ .px = 20, .font = @fromBackingInt(0) });
    var cols: TestRun = .{};
    var run = cols.run();
    const shaper: Shaper = .init(face);
    measure(&shaper, 1, &tx, &strings, &run);
    // HarfBuzz: 599 + 600 + 476 + 561 + 508 + 605 = 3349 units at 20 / 1000 px per unit.
    try std.testing.expectApproxEqAbs(3349.0 * 20 / @as(f32, @floatFromInt(face.units_per_em)), tx.c.w[a], 1e-3);
    try std.testing.expect(tx.c.h[a] > 20);
    try std.testing.expectEqual(0, tx.c.w[b]);
}
