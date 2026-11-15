//! OpenType / TrueType parsing over the caller's bytes. Tier 0: no allocator, no I/O.
//!
//! Every function reads the font file the caller hands in and returns plain values or slices
//! into it; nothing is copied or kept. Fonts are untrusted input, so every read is bounds
//! checked and returns `error.Truncated` instead of reading past the end, and offset arithmetic
//! saturates (`+|`, `*|`) so a hostile 32-bit offset fails the check instead of wrapping on a
//! 32-bit target. Parsing is not a per-row pass, so the branchless rule does not apply here.
//!
//! Spec: https://learn.microsoft.com/typography/opentype/spec/ (font file, table directory).

const std = @import("std");

pub const Error = error{
    /// An offset or length points past the end of the data.
    Truncated,
    /// The data does not start with a TrueType or OpenType signature.
    NotAFont,
    /// A table the caller asked for is not in the font.
    MissingTable,
    /// Valid OpenType that this parser does not read (CFF outlines, an unknown table version).
    Unsupported,
};

/// A table tag as the big-endian u32 the directory stores: `tag("glyf")`.
pub fn tag(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

/// Reads a big-endian `T` at `off`, or fails if it does not fit.
fn read(comptime T: type, d: []const u8, off: usize) Error!T {
    if (off > d.len or d.len - off < @sizeOf(T)) return error.Truncated;
    return std.mem.readInt(T, d[off..][0..@sizeOf(T)], .big);
}

/// `d[off..][0..len]`, or fails if it does not fit.
fn sub(d: []const u8, off: usize, len: usize) Error![]const u8 {
    if (off > d.len or d.len - off < len) return error.Truncated;
    return d[off..][0..len];
}

/// The table directory of one font: a list of (tag, offset, length) records. Offsets are from
/// the start of the file, which in a collection is not the start of the face.
pub const Directory = struct {
    /// The whole file; table offsets index it.
    data: []const u8,
    /// The table records, 16 bytes each: tag, checksum, offset, length.
    records: []const u8,

    /// Reads the directory that starts at `offset` (0 for a plain .ttf).
    pub fn parse(data: []const u8, offset: usize) Error!Directory {
        const version = try read(u32, data, offset);
        if (version == tag("OTTO")) return error.Unsupported;
        if (version != 0x0001_0000 and version != tag("true")) return error.NotAFont;
        const count = try read(u16, data, offset +| 4);
        return .{ .data = data, .records = try sub(data, offset +| 12, @as(usize, count) * 16) };
    }

    /// The table with tag `t`, null if the font has none. Fails if the record points outside
    /// the file. Linear: directories hold a few dozen records and are not reliably sorted.
    pub fn find(dir: Directory, t: u32) Error!?[]const u8 {
        var i: usize = 0;
        while (i < dir.records.len) : (i += 16) {
            if (try read(u32, dir.records, i) != t) continue;
            const off = try read(u32, dir.records, i + 8);
            const len = try read(u32, dir.records, i + 12);
            return try sub(dir.data, off, len);
        }
        return null;
    }

    /// The table with tag `t`, or `error.MissingTable`.
    pub fn get(dir: Directory, t: u32) Error![]const u8 {
        return (try dir.find(t)) orelse error.MissingTable;
    }
};

/// A glyph id: an index into the font's glyph tables. OpenType stores them in 16 bits.
pub const Glyph = u16;

/// The character map: codepoint to glyph. Holds the one subtable that covers the most of
/// Unicode: format 12 (all planes) over format 4 (the BMP), Unicode encodings over symbol.
pub const Cmap = struct {
    /// 4 or 12.
    format: u16,
    /// The chosen subtable; `parse` checked that its arrays fit.
    table: []const u8,

    pub fn parse(cmap: []const u8) Error!Cmap {
        const count = try read(u16, cmap, 2);
        var best: Cmap = .{ .format = 0, .table = &.{} };
        var best_rank: u8 = 0;
        for (0..count) |i| {
            const rec = 4 + i * 8;
            const platform = try read(u16, cmap, rec);
            const encoding = try read(u16, cmap, rec + 2);
            const off = try read(u32, cmap, rec + 4);
            const format = try read(u16, cmap, off);
            const unicode = platform == 0 or (platform == 3 and (encoding == 1 or encoding == 10));
            const symbol = platform == 3 and encoding == 0;
            const rank: u8 = if (format == 12 and unicode) 3 else if (format == 4 and unicode) 2 else if (format == 4 and symbol) 1 else 0;
            if (rank <= best_rank) continue;
            best = .{ .format = format, .table = try checkSubtable(cmap[off..], format) };
            best_rank = rank;
        }
        if (best_rank == 0) return error.Unsupported;
        return best;
    }

    /// Cuts a format 4 or 12 subtable to the bytes its arrays need, or fails if they do not fit.
    fn checkSubtable(st: []const u8, format: u16) Error![]const u8 {
        if (format == 12) return sub(st, 0, 16 +| @as(usize, try read(u32, st, 12)) *| 12);
        const seg2 = try read(u16, st, 6);
        if (seg2 & 1 != 0) return error.Unsupported;
        // The glyph id array after the four segment arrays is checked per lookup.
        return st;
    }

    /// The glyph for codepoint `cp`; 0 (`.notdef`) when the font has none, or when a format 4
    /// range offset points outside the table.
    pub fn glyph(c: Cmap, cp: u32) Glyph {
        return if (c.format == 12) c.glyph12(cp) else c.glyph4(cp);
    }

    fn glyph4(c: Cmap, cp: u32) Glyph {
        if (cp > 0xffff) return 0;
        const st = c.table;
        const seg2: usize = read(u16, st, 6) catch return 0;
        const ends = 14;
        const starts = 16 + seg2;
        const deltas = starts + seg2;
        const ranges = deltas + seg2;
        // First segment whose end code is >= cp; segments are sorted by end code.
        var lo: usize = 0;
        var hi: usize = seg2 / 2;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const end = read(u16, st, ends + mid * 2) catch return 0;
            if (end < cp) lo = mid + 1 else hi = mid;
        }
        if (lo == seg2 / 2) return 0;
        const start = read(u16, st, starts + lo * 2) catch return 0;
        if (cp < start) return 0;
        const delta = read(u16, st, deltas + lo * 2) catch return 0;
        const range = read(u16, st, ranges + lo * 2) catch return 0;
        if (range == 0) return @truncate(cp +% delta);
        // The range offset is relative to its own position in the idRangeOffset array.
        const at = ranges + lo * 2 + range + (cp - start) * 2;
        const g = read(u16, st, at) catch return 0;
        return if (g == 0) 0 else g +% delta;
    }

    fn glyph12(c: Cmap, cp: u32) Glyph {
        const groups = (c.table.len - 16) / 12;
        var lo: usize = 0;
        var hi: usize = groups;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const end = read(u32, c.table, 16 + mid * 12 + 4) catch return 0;
            if (end < cp) lo = mid + 1 else hi = mid;
        }
        if (lo == groups) return 0;
        const g = 16 + lo * 12;
        const start = read(u32, c.table, g) catch return 0;
        if (cp < start) return 0;
        const first = read(u32, c.table, g + 8) catch return 0;
        const id = first +| (cp - start);
        return if (id > 0xffff) 0 else @intCast(id);
    }
};

/// Horizontal metrics of one glyph, in font units.
pub const HMetrics = struct {
    advance: u16,
    left_bearing: i16,
};

/// One font face: the tables a text stack reads for every glyph, located and checked once.
/// Values are in font units; multiply by `px / units_per_em` for pixels.
pub const Face = struct {
    dir: Directory,
    cmap: Cmap,
    /// `hmetric_count` (advance, left bearing) pairs, then one left bearing per further glyph.
    hmtx: []const u8,
    units_per_em: u16,
    /// Typographic line metrics from hhea: baseline to top (positive), to bottom (negative),
    /// and the extra gap between lines.
    ascender: i16,
    descender: i16,
    line_gap: i16,
    /// The union of all glyph boxes: x min, y min, x max, y max.
    bbox: [4]i16,
    /// head.macStyle: bit 0 bold, bit 1 italic.
    mac_style: u16,
    /// loca holds 32-bit offsets (head.indexToLocFormat 1) instead of 16-bit halves.
    loca_long: bool,
    glyph_count: u16,
    hmetric_count: u16,

    /// Reads the face whose table directory starts at `offset` (0 for a plain .ttf).
    pub fn parse(data: []const u8, offset: usize) Error!Face {
        const dir = try Directory.parse(data, offset);
        const head = try dir.get(tag("head"));
        const hhea = try dir.get(tag("hhea"));
        const maxp = try dir.get(tag("maxp"));
        const hmtx = try dir.get(tag("hmtx"));
        const units_per_em = try read(u16, head, 18);
        // The spec allows 16 to 16384; zero would divide by zero in every scale.
        if (units_per_em < 16 or units_per_em > 16384) return error.Unsupported;
        const loca_format = try read(i16, head, 50);
        if (loca_format != 0 and loca_format != 1) return error.Unsupported;
        const glyph_count = try read(u16, maxp, 4);
        const hmetric_count = try read(u16, hhea, 34);
        if (hmetric_count == 0 or hmetric_count > glyph_count) return error.Unsupported;
        const hmtx_len = @as(usize, hmetric_count) * 4 + @as(usize, glyph_count - hmetric_count) * 2;
        return .{
            .dir = dir,
            .cmap = try Cmap.parse(try dir.get(tag("cmap"))),
            .hmtx = try sub(hmtx, 0, hmtx_len),
            .units_per_em = units_per_em,
            .ascender = try read(i16, hhea, 4),
            .descender = try read(i16, hhea, 6),
            .line_gap = try read(i16, hhea, 8),
            .bbox = .{ try read(i16, head, 36), try read(i16, head, 38), try read(i16, head, 40), try read(i16, head, 42) },
            .mac_style = try read(u16, head, 44),
            .loca_long = loca_format == 1,
            .glyph_count = glyph_count,
            .hmetric_count = hmetric_count,
        };
    }

    /// Advance and left bearing of `g`; zeros for a glyph the face does not have. Glyphs past
    /// `hmetric_count` share the last advance (monospaced tails).
    pub fn hMetrics(face: Face, g: Glyph) HMetrics {
        if (g >= face.glyph_count) return .{ .advance = 0, .left_bearing = 0 };
        const last = @as(usize, face.hmetric_count) - 1;
        const row = @min(@as(usize, g), last) * 4;
        const bearing = if (g <= last) row + 2 else (last + 1) * 4 + (g - last - 1) * 2;
        // parse sized hmtx for every glyph, so these reads cannot fail.
        return .{
            .advance = read(u16, face.hmtx, row) catch unreachable,
            .left_bearing = read(i16, face.hmtx, bearing) catch unreachable,
        };
    }
};

// Test font: a subset of Liberation Sans 2.1.5 (SIL OFL 1.1), built by testdata/make.py.
// Expected numbers come from fontTools reading the same file.
const test_ttf = @embedFile("testdata/test.ttf");

fn offsetIn(data: []const u8, s: []const u8) usize {
    return @intFromPtr(s.ptr) - @intFromPtr(data.ptr);
}

test "the table directory of the test font" {
    const dir = try Directory.parse(test_ttf, 0);
    try std.testing.expectEqual(12 * 16, dir.records.len);
    const glyf = try dir.get(tag("glyf"));
    try std.testing.expectEqual(608, offsetIn(test_ttf, glyf));
    try std.testing.expectEqual(582, glyf.len);
    const head = try dir.get(tag("head"));
    try std.testing.expectEqual(204, offsetIn(test_ttf, head));
    try std.testing.expectEqual(54, head.len);
    try std.testing.expectEqual(null, try dir.find(tag("CFF ")));
    try std.testing.expectError(error.MissingTable, dir.get(tag("CFF ")));
}

test "a damaged directory is an error, not a crash" {
    try std.testing.expectError(error.Truncated, Directory.parse(test_ttf[0..20], 0));
    try std.testing.expectError(error.Truncated, Directory.parse(test_ttf[0..2], 0));
    try std.testing.expectError(error.NotAFont, Directory.parse("abcdabcdabcd", 0));
    try std.testing.expectError(error.Unsupported, Directory.parse("OTTO\x00\x00", 0));
    // A record whose table runs past the end of the file.
    const dir = try Directory.parse(test_ttf[0..1000], 0);
    try std.testing.expectError(error.Truncated, dir.find(tag("glyf")));
}

test "cmap maps the test font's characters" {
    const dir = try Directory.parse(test_ttf, 0);
    const cmap = try Cmap.parse(try dir.get(tag("cmap")));
    try std.testing.expectEqual(4, cmap.format);
    const chars = " AVTaeové";
    const glyphs = [_]Glyph{ 1, 2, 4, 3, 5, 6, 7, 8, 10 };
    var view = std.unicode.Utf8View.initUnchecked(chars).iterator();
    var i: usize = 0;
    while (view.nextCodepoint()) |cp| : (i += 1) try std.testing.expectEqual(glyphs[i], cmap.glyph(cp));
    try std.testing.expectEqual(glyphs.len, i);
    for ([_]u32{ 0, 'B', 0xffff, 0x1f600, 0xffff_ffff }) |cp| try std.testing.expectEqual(0, cmap.glyph(cp));
}

test "cmap format 12 covers the astral planes" {
    // One encoding record (3, 10) pointing at a format 12 subtable with one group:
    // U+1F600..U+1F602 -> glyphs 5..7.
    const bytes = "\x00\x00\x00\x01" ++ "\x00\x03\x00\x0a\x00\x00\x00\x0c" ++
        "\x00\x0c\x00\x00\x00\x00\x00\x1c\x00\x00\x00\x00\x00\x00\x00\x01" ++
        "\x00\x01\xf6\x00\x00\x01\xf6\x02\x00\x00\x00\x05";
    const cmap = try Cmap.parse(bytes);
    try std.testing.expectEqual(12, cmap.format);
    try std.testing.expectEqual(6, cmap.glyph(0x1f601));
    try std.testing.expectEqual(0, cmap.glyph(0x1f603));
    try std.testing.expectEqual(0, cmap.glyph('A'));
    // The group count claims more groups than there are bytes.
    try std.testing.expectError(error.Truncated, Cmap.parse(bytes[0 .. bytes.len - 1]));
}

test "face metrics of the test font" {
    const face = try Face.parse(test_ttf, 0);
    try std.testing.expectEqual(2048, face.units_per_em);
    try std.testing.expectEqual(1854, face.ascender);
    try std.testing.expectEqual(-434, face.descender);
    try std.testing.expectEqual(67, face.line_gap);
    try std.testing.expectEqual([4]i16{ 4, -20, 1362, 1508 }, face.bbox);
    try std.testing.expectEqual(0, face.mac_style);
    try std.testing.expectEqual(false, face.loca_long);
    try std.testing.expectEqual(11, face.glyph_count);
    try std.testing.expectEqual(11, face.hmetric_count);
    const a = face.hMetrics(face.cmap.glyph('A'));
    try std.testing.expectEqual(HMetrics{ .advance = 1366, .left_bearing = 4 }, a);
    try std.testing.expectEqual(HMetrics{ .advance = 1139, .left_bearing = 87 }, face.hMetrics(face.cmap.glyph(0xe9)));
    try std.testing.expectEqual(HMetrics{ .advance = 569, .left_bearing = 0 }, face.hMetrics(face.cmap.glyph(' ')));
    try std.testing.expectEqual(HMetrics{ .advance = 0, .left_bearing = 0 }, face.hMetrics(11));
    try std.testing.expectError(error.Truncated, Face.parse(test_ttf[0..500], 0));
}

test "glyphs past the last long metric share its advance" {
    // Two long metrics and one bearing-only glyph.
    var face = try Face.parse(test_ttf, 0);
    face.glyph_count = 3;
    face.hmetric_count = 2;
    face.hmtx = "\x01\x00\x00\x05\x02\x00\xff\xfe\x00\x07";
    try std.testing.expectEqual(HMetrics{ .advance = 0x200, .left_bearing = -2 }, face.hMetrics(1));
    try std.testing.expectEqual(HMetrics{ .advance = 0x200, .left_bearing = 7 }, face.hMetrics(2));
}
