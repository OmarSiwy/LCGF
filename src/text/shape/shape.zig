//! Simple shaper: UTF-8 text to positioned glyphs for one face. Tier 0.
//!
//! Output is a glyph run, columns the caller owns (`Run`): glyph id, the byte offset of the text
//! the glyph came from (its cluster), advance and offsets, all in font units so one run serves
//! every pixel size (multiply by `px / units_per_em`). This is the data a renderer turns into
//! quads and an editor maps the cursor through; nothing is retained.
//!
//! What this shaper does: cmap lookup, hmtx advances, and pair kerning (GPOS 'kern' or the
//! kern table, via `Face.kerning`). Text is taken as one left-to-right run of one script; bidi
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

/// Shapes `text` with `face` into `run` (replacing what it held). One glyph per code point
/// before substitutions. Fails with `error.NoSpace`, `run.len` then unspecified, when the
/// run's columns are too short.
pub fn shape(face: *const Face, text: []const u8, run: *Run) error{NoSpace}!void {
    try map(face, text, run);
    kern(face, run);
}

/// Code points to nominal glyphs with their advances.
fn map(face: *const Face, text: []const u8, run: *Run) error{NoSpace}!void {
    run.len = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (run.len == run.glyph.len) return error.NoSpace;
        const d = utf8.decode(text, i);
        const g = face.cmap.glyph(d.cp);
        const k = run.len;
        run.glyph[k] = g;
        run.cluster[k] = @intCast(i);
        run.advance[k] = face.hMetrics(g).advance;
        run.x_offset[k] = 0;
        run.y_offset[k] = 0;
        run.len = k + 1;
        i += d.len;
    }
}

/// Pair kerning of neighbours: the left glyph's advance changes.
fn kern(face: *const Face, run: *Run) void {
    if (run.len < 2) return;
    for (0..run.len - 1) |k| run.advance[k] += face.kerning(run.glyph[k], run.glyph[k + 1]);
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
pub fn measure(face: *const Face, font: u16, tx: *Texts, strings: *const Strings, run: *Run) void {
    const c = &tx.c;
    const line: f32 = @floatFromInt(@as(i32, face.ascender) - face.descender + face.line_gap);
    const em: f32 = @floatFromInt(face.units_per_em);
    for (0..tx.len) |k| {
        // Shaping is per run and reads its bytes: not a row pass, so it may skip rows.
        if (c.font[k] != font) continue;
        const text = strings.get(.{ .start = c.start[k], .bytes = c.bytes[k] });
        shape(face, text, run) catch {};
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
pub fn expectHb(features: []const u8, comptime shaper: fn (*const Face, []const u8, *Run) error{NoSpace}!void) !usize {
    const face = try Face.parse(test_font, 0);
    var buf: [1024]u8 = undefined;
    var cases: [16]HbCase = undefined;
    const n = try hbCases(features, &buf, &cases);
    for (cases[0..n]) |*c| {
        var cols: TestRun = .{};
        var run = cols.run();
        try shaper(&face, c.text, &run);
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
    try std.testing.expectEqual(6, try expectHb("kern", shape));
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
    measure(&face, 1, &tx, &strings, &run);
    // HarfBuzz: 599 + 600 + 476 + 561 + 508 + 605 = 3349 units at 20 / 1000 px per unit.
    try std.testing.expectApproxEqAbs(3349.0 * 20 / @as(f32, @floatFromInt(face.units_per_em)), tx.c.w[a], 1e-3);
    try std.testing.expect(tx.c.h[a] > 20);
    try std.testing.expectEqual(0, tx.c.w[b]);
}
