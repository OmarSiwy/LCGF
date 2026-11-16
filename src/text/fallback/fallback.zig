//! Font fallback: which of the caller's faces draws each part of a text. Tier 0.
//!
//! The chain is data the caller fills, from its own fonts or from system discovery
//! (fontconfig.zig, directwrite.zig, coretext.zig): a list of faces, rows of (script, face) in
//! priority order, and default faces tried for every script after its own rows. `resolve`
//! splits a UTF-8 text into runs of one face and one script, the unit `shape.Shaper` takes:
//!
//! - A character of a real script takes the first face of its script's rows, then of the
//!   default list, whose cmap has it.
//! - A Common or Inherited character (space, punctuation, digits, combining marks) stays in the
//!   face of the character before it while that face has it, so "Բարեւ ձեզ" is one run and a
//!   mark is not split from its base; otherwise it searches the chain of its script run
//!   (src/text/unicode/script.zig gives Common characters the script of the run around them).
//! - A character no face has stays in the current face (it draws as .notdef), or the first
//!   default face at the start of the text.
//!
//! This is the per-character rule of the OS text systems (GPUI's README: the platform's text
//! system picks fallback fonts; Slint does the same through the platform's font database), with
//! the candidate list made explicit so the caller controls it. Itemisation is per character,
//! not a per-row pass, so like script.zig it branches.

const std = @import("std");
const opentype = @import("../font/opentype.zig");
const property = @import("../unicode/property.zig");
const script_runs = @import("../unicode/script.zig");
const utf8 = @import("../unicode/utf8.zig");

const Face = opentype.Face;
const Script = property.Script;

/// The candidate faces and their order. All slices are the caller's.
pub const Chain = struct {
    faces: []const Face,
    /// Preference rows, in priority order: row k says `faces[face[k]]` is tried for `script[k]`.
    script: []const Script = &.{},
    face: []const u16 = &.{},
    /// Tried after a script's own rows, for every script; usually every face once.
    default: []const u16,

    /// The first face for `s` whose cmap has `cp`, or null.
    pub fn pick(c: *const Chain, s: Script, cp: u21) ?u16 {
        for (c.script, c.face) |rs, f| {
            if (rs == s and c.faces[f].cmap.glyph(cp) != 0) return f;
        }
        for (c.default) |f| {
            if (c.faces[f].cmap.glyph(cp) != 0) return f;
        }
        return null;
    }
};

/// Runs of one face and one script, in text order: run k covers bytes `end[k-1]..end[k]`
/// (0 first). Capacity is the slices' length, all equal.
pub const Runs = struct {
    end: []u32,
    face: []u16,
    script: []Script,
    len: u32 = 0,
};

/// Splits `text` into `runs` by script and face (see the file comment). `error.NoSpace` when
/// the run columns are short; `chain.default` must not be empty.
pub fn resolve(chain: *const Chain, text: []const u8, runs: *Runs) error{NoSpace}!void {
    std.debug.assert(chain.default.len > 0);
    runs.len = 0;
    var cur: u16 = chain.default[0];
    var started = false;
    var it: script_runs.Scripts = .{ .text = text };
    var i: usize = 0;
    while (it.next()) |sr| {
        while (i < sr.end) {
            const d = utf8.decode(text, i);
            const s = property.script(d.cp);
            const common = s == .Common or s == .Inherited;
            const keep = started and common and chain.faces[cur].cmap.glyph(d.cp) != 0;
            const f = if (keep) cur else chain.pick(sr.script, d.cp) orelse cur;
            const same = runs.len > 0 and runs.face[runs.len - 1] == f and runs.script[runs.len - 1] == sr.script;
            if (!same) {
                if (runs.len == runs.end.len) return error.NoSpace;
                runs.face[runs.len] = f;
                runs.script[runs.len] = sr.script;
                runs.len += 1;
            }
            i += d.len;
            runs.end[runs.len - 1] = @intCast(i);
            cur = f;
            started = true;
        }
    }
}

/// The face of a font file whose PostScript name (name table, ID 6) is `ps`, or null. For
/// discovery that names a face instead of indexing it (Core Text). Names are ASCII; records
/// are read in Macintosh Roman (platform 1) or UTF-16BE (platforms 0 and 3).
pub fn faceByName(data: []const u8, ps: []const u8) opentype.Error!?u32 {
    for (0..try opentype.faceCount(data)) |i| {
        const index: u32 = @intCast(i);
        const dir = opentype.Directory.parse(data, try opentype.faceOffset(data, index)) catch continue;
        const name = (dir.find(opentype.tag("name")) catch continue) orelse continue;
        if (nameHas(name, ps)) return index;
    }
    return null;
}

/// Whether one of the PostScript-name records of `name` is `ps`. A record that does not fit
/// the table is skipped (fonts are untrusted).
fn nameHas(name: []const u8, ps: []const u8) bool {
    if (name.len < 6) return false;
    const count = std.mem.readInt(u16, name[2..4], .big);
    const strings = std.mem.readInt(u16, name[4..6], .big);
    for (0..count) |k| {
        const at = 6 + k * 12;
        if (at + 12 > name.len) return false;
        const rec = name[at..][0..12];
        if (std.mem.readInt(u16, rec[6..8], .big) != 6) continue;
        const platform = std.mem.readInt(u16, rec[0..2], .big);
        const len: usize = std.mem.readInt(u16, rec[8..10], .big);
        const off = @as(usize, strings) + std.mem.readInt(u16, rec[10..12], .big);
        if (off + len > name.len) continue;
        const s = name[off..][0..len];
        if (platform == 1 and std.mem.eql(u8, s, ps)) return true;
        if (platform == 1 or len != ps.len * 2) continue;
        for (ps, 0..) |c, j| {
            if (s[2 * j] != 0 or s[2 * j + 1] != c) break;
        } else return true;
    }
    return false;
}

test faceByName {
    const ttc = @embedFile("../font/testdata/test.ttc");
    // Expected: fontTools TTCollection on test.ttc, nameID 6 of each face.
    try std.testing.expectEqual(0, try faceByName(ttc, "LcgrTest-Sans-Regular"));
    try std.testing.expectEqual(1, try faceByName(ttc, "LcgrTest-Sans-Bold"));
    try std.testing.expectEqual(null, try faceByName(ttc, "LcgrTest-Sans"));
    try std.testing.expectEqual(null, try faceByName(ttc, "LcgrTest-Sans-Bolder"));
    try std.testing.expectEqual(0, try faceByName(test_latin, "LcgrFallbackSans-Regular"));
}

/// Columns for a few test runs.
pub const TestRuns = struct {
    end: [16]u32 = undefined,
    face: [16]u16 = undefined,
    script: [16]Script = undefined,

    pub fn runs(t: *TestRuns) Runs {
        return .{ .end = &t.end, .face = &t.face, .script = &t.script };
    }
};

// ---------------------------------------------------------------------------------------------
// Done when: a mixed-script sample renders. "Hi, Բարեւ! გამარჯობა αβγ" over three faces of
// which none covers it all (testdata/make.py), resolved here, shaped by the built-in shaper,
// rasterised by src/text/raster/, against HarfBuzz's shaping and FreeType's picture of the
// same fallback (testdata/mixed.pgm).

pub const test_latin = @embedFile("testdata/latin.ttf");
pub const test_armenian = @embedFile("testdata/armenian.ttf");
pub const test_georgian = @embedFile("testdata/georgian.ttf");
pub const test_sample = "Hi, Բարեւ! გამარჯობა αβγ";
const mixed_pgm = @embedFile("testdata/mixed.pgm");
// The picture's geometry (make.py).
const px = 24;
const picture_w = 320;
const picture_h = 36;
const baseline = 26;

/// The sample's chain: one face per script, then all three in order.
pub fn testChain(faces: *[3]Face) !Chain {
    faces.* = .{ try .parse(test_latin, 0), try .parse(test_armenian, 0), try .parse(test_georgian, 0) };
    return .{
        .faces = faces,
        .script = &.{ .Latin, .Armenian, .Georgian },
        .face = &.{ 0, 1, 2 },
        .default = &.{ 0, 1, 2 },
    };
}

test "the sample resolves to runs of the face that has each character" {
    var faces: [3]Face = undefined;
    const chain = try testChain(&faces);
    var cols: TestRuns = .{};
    var runs = cols.runs();
    try resolve(&chain, test_sample, &runs);
    const t = test_sample;
    const at = struct {
        fn f(s: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, test_sample, s).?);
        }
    }.f;
    // Armenian has no "!" or space, so they fall back to Latin inside the Armenian script run;
    // the space after the Georgian word stays Georgian (georgian.ttf has it).
    try std.testing.expectEqualSlices(u32, &.{ at("Բ"), at("!"), at("გ"), at("α"), t.len }, runs.end[0..runs.len]);
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 0, 2, 0 }, runs.face[0..runs.len]);
    try std.testing.expectEqualSlices(Script, &.{ .Latin, .Armenian, .Armenian, .Georgian, .Greek }, runs.script[0..runs.len]);
}

test "a mixed-script sample renders" {
    const shape = @import("../shape/shape.zig");
    const raster = @import("../raster/raster.zig");
    var faces: [3]Face = undefined;
    const chain = try testChain(&faces);
    var rcols: TestRuns = .{};
    var runs = rcols.runs();
    try resolve(&chain, test_sample, &runs);

    var img: [picture_w * picture_h]u8 = @splat(0);
    var ocols: raster.TestOutline = .{};
    var acc: [64 * 64]f32 = undefined;
    var cov: [64 * 64]u8 = undefined;
    var pen: f32 = 2;
    var start: u32 = 0;
    var glyphs: u32 = 0;
    for (runs.end[0..runs.len], runs.face[0..runs.len]) |end, fi| {
        defer start = end;
        const face = faces[fi];
        var scols: shape.TestRun = .{};
        var run = scols.run();
        try shape.Shaper.init(face).shape(test_sample[start..end], &run, .{});
        const scale = @as(f32, px) / @as(f32, @floatFromInt(face.units_per_em));
        for (run.glyph[0..run.len], run.advance[0..run.len], run.x_offset[0..run.len], run.y_offset[0..run.len]) |g, adv, xo, yo| {
            defer pen += @as(f32, @floatFromInt(adv)) * scale;
            // Every character was resolved to a face that has it.
            try std.testing.expect(g != 0);
            glyphs += 1;
            try std.testing.expectEqual(0, yo);
            var o = ocols.outline();
            try face.outline(g, &o);
            const x = pen + @as(f32, @floatFromInt(xo)) * scale;
            const pixel = @floor(x);
            const b = raster.box(&o, scale, x - pixel);
            if (b.w == 0) continue;
            raster.fill(&o, scale, x - pixel, b, &acc);
            raster.coverage(&acc, &cov, @as(usize, b.w) * b.h);
            for (0..b.h) |r| for (0..b.w) |c| {
                const ix = @as(i32, @intFromFloat(pixel)) + b.left + @as(i32, @intCast(c));
                const iy = baseline - b.top + @as(i32, @intCast(r));
                if (ix < 0 or iy < 0 or ix >= picture_w or iy >= picture_h) continue;
                const p = @as(usize, @intCast(iy)) * picture_w + @as(usize, @intCast(ix));
                img[p] = @max(img[p], cov[r * b.w + c]);
            };
        }
    }
    try std.testing.expectEqual(24, glyphs);

    const header = "P5\n320 36\n255\n";
    try std.testing.expectEqualStrings(header, mixed_pgm[0..header.len]);
    const ref = mixed_pgm[header.len..];
    var max: u32 = 0;
    var sum: u64 = 0;
    var ink: u64 = 0;
    for (img, ref) |a, b| {
        const d: u32 = @abs(@as(i32, a) - b);
        max = @max(max, d);
        sum += d;
        ink += @intFromBool(b != 0);
    }
    // Same glyphs at the same places, so only the shapers' and rasterisers' rounding differs:
    // the bounds of the HarfBuzz adapter's sample (measured here: max 8 levels of 255, and a
    // sum of 2,824 over 2,288 inked reference pixels).
    try std.testing.expect(max <= 16);
    try std.testing.expect(sum < 2 * ink);
    try std.testing.expect(ink > 1000);
}
