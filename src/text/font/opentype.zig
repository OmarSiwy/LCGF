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
    /// Table contents contradict each other (a glyph id past the glyph count, contour ends
    /// out of order).
    Malformed,
    /// The caller's output columns are full.
    NoSpace,
    /// A face index past the number of faces in the file.
    NoSuchFace,
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

/// Number of faces in a font file: the count of a collection (.ttc, 'ttcf' header), else 1.
pub fn faceCount(data: []const u8) Error!u32 {
    if (try read(u32, data, 0) != tag("ttcf")) return 1;
    const count = try read(u32, data, 8);
    _ = try sub(data, 12, @as(usize, count) *| 4);
    return count;
}

/// Where the table directory of face `index` starts: pass it to `Face.parse`.
pub fn faceOffset(data: []const u8, index: u32) Error!usize {
    if (index >= try faceCount(data)) return error.NoSuchFace;
    if (try read(u32, data, 0) != tag("ttcf")) return 0;
    return try read(u32, data, 12 + @as(usize, index) * 4);
}

/// Style bits a face is selected by, from head.macStyle.
pub const Style = struct {
    bold: bool = false,
    italic: bool = false,
};

/// Face selection: the first face in the file whose style is `style`, or null. Faces that do
/// not parse are skipped.
pub fn findFace(data: []const u8, style: Style) Error!?u32 {
    const want: u16 = @as(u16, @intFromBool(style.bold)) | @as(u16, @intFromBool(style.italic)) << 1;
    for (0..try faceCount(data)) |i| {
        const index: u32 = @intCast(i);
        const dir = Directory.parse(data, try faceOffset(data, index)) catch continue;
        const head = dir.get(tag("head")) catch continue;
        const mac_style = read(u16, head, 44) catch continue;
        if (mac_style & 3 == want) return index;
    }
    return null;
}

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
    /// Glyph offsets into `glyf`, `glyph_count + 1` of them; both empty when the face has no
    /// TrueType outlines.
    loca: []const u8,
    glyf: []const u8,
    /// The legacy kern table, empty when absent.
    kern: []const u8,
    /// The GPOS 'kern' Feature table and the GPOS LookupList it indexes; empty when absent or
    /// unreadable (kerning then falls back to `kern`).
    gpos_kern: []const u8,
    gpos_lookups: []const u8,
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
        const glyf = (try dir.find(tag("glyf"))) orelse &.{};
        const loca_len = (@as(usize, glyph_count) + 1) * @as(usize, if (loca_format == 1) 4 else 2);
        const loca = if (glyf.len == 0) &.{} else try sub(try dir.get(tag("loca")), 0, loca_len);
        const gpos = (try dir.find(tag("GPOS"))) orelse &.{};
        // A damaged GPOS costs kerning, not the face.
        const gpos_kern = if (gpos.len == 0) &.{} else gposKernFeature(gpos) catch &.{};
        const gpos_lookups = gpos[@min(read(u16, gpos, 8) catch 0, gpos.len)..];
        return .{
            .dir = dir,
            .cmap = try Cmap.parse(try dir.get(tag("cmap"))),
            .hmtx = try sub(hmtx, 0, hmtx_len),
            .loca = loca,
            .glyf = glyf,
            .kern = (try dir.find(tag("kern"))) orelse &.{},
            .gpos_kern = gpos_kern,
            .gpos_lookups = gpos_lookups,
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

    /// Change to the advance of `left` when `right` follows it, in font units: GPOS pair
    /// adjustment (feature 'kern') when the face has it, else the legacy kern table. Damaged
    /// kerning data reads as 0.
    pub fn kerning(face: Face, left: Glyph, right: Glyph) i32 {
        if (face.gpos_kern.len != 0) return gposKerning(face.gpos_kern, face.gpos_lookups, left, right) catch 0;
        return kernTable(face.kern, left, right) catch 0;
    }

    /// The glyf record of `g`; empty for a glyph without an outline (a space, or a face
    /// without glyf).
    pub fn glyphRecord(face: Face, g: Glyph) Error![]const u8 {
        if (g >= face.glyph_count) return error.Malformed;
        if (face.glyf.len == 0) return &.{};
        const i: usize = g;
        const start: usize, const end: usize = if (face.loca_long)
            .{ try read(u32, face.loca, i * 4), try read(u32, face.loca, i * 4 + 4) }
        else
            .{ @as(usize, try read(u16, face.loca, i * 2)) * 2, @as(usize, try read(u16, face.loca, i * 2 + 2)) * 2 };
        if (end < start) return error.Malformed;
        return sub(face.glyf, start, end - start);
    }

    /// Appends the outline of `g` to `out`, in font units. A glyph without an outline appends
    /// nothing. Composite glyphs append their components, transformed and offset. Fails with
    /// `error.NoSpace`, leaving `out` as it was, when the columns are full.
    pub fn outline(face: Face, g: Glyph, out: *Outline) Error!void {
        std.debug.assert(out.y.len == out.x.len and out.on.len == out.x.len);
        const points = out.points;
        const contours = out.contours;
        errdefer {
            out.points = points;
            out.contours = contours;
        }
        var budget: u32 = max_components;
        return face.outlineAt(g, out, 0, &budget);
    }

    fn outlineAt(face: Face, g: Glyph, out: *Outline, depth: u32, budget: *u32) Error!void {
        const rec = try face.glyphRecord(g);
        if (rec.len == 0) return;
        const contours = try read(i16, rec, 0);
        if (contours >= 0) return simpleOutline(rec, @intCast(contours), out);
        // Bounded recursion: a deeper (or cyclic) composite is malformed.
        if (depth == max_component_depth) return error.Malformed;
        const base = out.points;
        var at: usize = 10;
        while (true) {
            // Bounded work: components of empty glyphs add no points, so NoSpace alone would
            // not stop a wide, deep composite.
            if (budget.* == 0) return error.Malformed;
            budget.* -= 1;
            const flags = try read(u16, rec, at);
            const child = try read(u16, rec, at + 2);
            at += 4;
            var arg1: i32 = undefined;
            var arg2: i32 = undefined;
            const xy = flags & args_are_xy != 0;
            if (flags & args_are_words != 0) {
                arg1 = if (xy) try read(i16, rec, at) else try read(u16, rec, at);
                arg2 = if (xy) try read(i16, rec, at + 2) else try read(u16, rec, at + 2);
                at += 4;
            } else {
                arg1 = if (xy) try read(i8, rec, at) else try read(u8, rec, at);
                arg2 = if (xy) try read(i8, rec, at + 1) else try read(u8, rec, at + 1);
                at += 2;
            }
            // x' = m[0] x + m[2] y, y' = m[1] x + m[3] y; F2Dot14 entries.
            var m: [4]f32 = .{ 1, 0, 0, 1 };
            if (flags & have_scale != 0) {
                const s = try f2dot14(rec, at);
                m = .{ s, 0, 0, s };
                at += 2;
            } else if (flags & have_xy_scale != 0) {
                m = .{ try f2dot14(rec, at), 0, 0, try f2dot14(rec, at + 2) };
                at += 4;
            } else if (flags & have_2x2 != 0) {
                m = .{ try f2dot14(rec, at), try f2dot14(rec, at + 2), try f2dot14(rec, at + 4), try f2dot14(rec, at + 6) };
                at += 8;
            }

            const start = out.points;
            try face.outlineAt(child, out, depth + 1, budget);
            for (start..out.points) |i| {
                const x = out.x[i];
                const y = out.y[i];
                out.x[i] = m[0] * x + m[2] * y;
                out.y[i] = m[1] * x + m[3] * y;
            }
            var dx: f32 = @floatFromInt(arg1);
            var dy: f32 = @floatFromInt(arg2);
            if (!xy) {
                // Point matching: the component moves so its point arg2 lands on point arg1 of
                // the components before it.
                const parent = base + @as(usize, @intCast(arg1));
                const own = start + @as(usize, @intCast(arg2));
                if (parent >= start or own >= out.points) return error.Malformed;
                dx = out.x[parent] - out.x[own];
                dy = out.y[parent] - out.y[own];
            } else if (flags & scaled_offset != 0 and flags & unscaled_offset == 0) {
                const tx = m[0] * dx + m[2] * dy;
                dy = m[1] * dx + m[3] * dy;
                dx = tx;
            }
            for (start..out.points) |i| {
                out.x[i] += dx;
                out.y[i] += dy;
            }
            if (flags & more_components == 0) return;
        }
    }
};

/// Glyph outlines as columns the caller owns. `outline` appends to them: `points` and `contours`
/// count the rows in use, and the slice lengths are the capacity (`x`, `y`, `on` equally long).
/// Contour `c` runs from `ends[c - 1] + 1` (or 0) to `ends[c]` inclusive. Off-curve points are
/// quadratic control points; two in a row imply an on-curve point midway (TrueType).
pub const Outline = struct {
    x: []f32,
    y: []f32,
    on: []bool,
    ends: []u32,
    points: u32 = 0,
    contours: u32 = 0,
};

// Composite glyph component flag bits.
const args_are_words = 0x0001;
const args_are_xy = 0x0002;
const have_scale = 0x0008;
const more_components = 0x0020;
const have_xy_scale = 0x0040;
const have_2x2 = 0x0080;
const scaled_offset = 0x0800;
const unscaled_offset = 0x1000;

/// Composites nest at most this deep; real fonts use 1 or 2, so deeper means a cycle.
const max_component_depth = 8;
/// Components visited per outline, at all depths.
const max_components = 1024;

/// An F2Dot14 (2.14 fixed point) at `at`.
fn f2dot14(rec: []const u8, at: usize) Error!f32 {
    return @as(f32, @floatFromInt(try read(i16, rec, at))) / 16384;
}

// Simple glyph flag bits.
const on_curve = 0x01;
const x_short = 0x02;
const y_short = 0x04;
const repeat = 0x08;
const x_same = 0x10; // with x_short: the byte is positive; without: dx is 0
const y_same = 0x20;

/// Decodes a simple glyph record (`contours` >= 0) into `out`. Two passes over the flags:
/// the first finds where the x deltas end (which is where the y deltas start), the second
/// reads both delta streams, so no flag buffer is needed.
fn simpleOutline(rec: []const u8, contours: usize, out: *Outline) Error!void {
    if (contours == 0) return;
    const ends_at = 10;
    const count = @as(usize, try read(u16, rec, ends_at + (contours - 1) * 2)) + 1;
    if (out.x.len - out.points < count or out.ends.len - out.contours < contours) return error.NoSpace;
    const instructions = try read(u16, rec, ends_at + contours * 2);
    const flags_at = ends_at + contours * 2 + 2 + @as(usize, instructions);

    var at = flags_at;
    var x_bytes: usize = 0;
    var p: usize = 0;
    while (p < count) {
        const f = try read(u8, rec, at);
        at += 1;
        var times: usize = 1;
        if (f & repeat != 0) {
            times += try read(u8, rec, at);
            at += 1;
        }
        times = @min(times, count - p);
        const size: usize = if (f & x_short != 0) 1 else if (f & x_same != 0) 0 else 2;
        x_bytes += times * size;
        p += times;
    }

    const base = out.points;
    var xa = at;
    var ya = at + x_bytes;
    var fa = flags_at;
    var x: i32 = 0;
    var y: i32 = 0;
    p = 0;
    while (p < count) {
        // The first pass read these flag bytes already.
        const f = rec[fa];
        fa += 1;
        var times: usize = 1;
        if (f & repeat != 0) {
            times += rec[fa];
            fa += 1;
        }
        times = @min(times, count - p);
        for (0..times) |_| {
            x +%= try coordDelta(rec, &xa, f, x_short, x_same);
            y +%= try coordDelta(rec, &ya, f, y_short, y_same);
            out.x[base + p] = @floatFromInt(x);
            out.y[base + p] = @floatFromInt(y);
            out.on[base + p] = f & on_curve != 0;
            p += 1;
        }
    }

    var prev: usize = 0;
    for (0..contours) |c| {
        const e = try read(u16, rec, ends_at + c * 2);
        if (c > 0 and e <= prev) return error.Malformed;
        prev = e;
        out.ends[out.contours + c] = @intCast(base + e);
    }
    out.points += @intCast(count);
    out.contours += @intCast(contours);
}

/// One coordinate delta of a simple glyph, read at `at.*`, which advances past it.
inline fn coordDelta(rec: []const u8, at: *usize, f: u8, short: u8, same: u8) Error!i32 {
    if (f & short != 0) {
        const b: i32 = try read(u8, rec, at.*);
        at.* += 1;
        return if (f & same != 0) b else -b;
    }
    if (f & same != 0) return 0;
    const d = try read(i16, rec, at.*);
    at.* += 2;
    return d;
}

/// The legacy kern table (Microsoft version 0): the sum over horizontal, non-minimum,
/// non-cross-stream format 0 subtables. Apple's version 1 table reads as no kerning.
fn kernTable(kern: []const u8, left: Glyph, right: Glyph) Error!i32 {
    if (kern.len == 0 or try read(u16, kern, 0) != 0) return 0;
    const count = try read(u16, kern, 2);
    const key = @as(u32, left) << 16 | right;
    var total: i32 = 0;
    var at: usize = 4;
    for (0..count) |_| {
        const len = try read(u16, kern, at + 2);
        const coverage = try read(u16, kern, at + 4);
        // Format 0 (high byte), horizontal (bit 0), not minimum (1) or cross-stream (2).
        if (coverage & 0xff07 == 0x0001) {
            const pairs = try read(u16, kern, at + 6);
            var lo: usize = 0;
            var hi: usize = pairs;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const row = at + 14 + mid * 6;
                const k = try read(u32, kern, row);
                if (k == key) {
                    total += try read(i16, kern, row + 4);
                    break;
                }
                if (k < key) lo = mid + 1 else hi = mid;
            }
        }
        // A subtable's 16-bit length field overflows for big tables; such fonts have one.
        if (len < 6) break;
        at += len;
    }
    return total;
}

/// Index of `g` in a Coverage table, or null when it is not covered.
fn coverageIndex(cov: []const u8, g: Glyph) Error!?u16 {
    const format = try read(u16, cov, 0);
    const count = try read(u16, cov, 2);
    var lo: usize = 0;
    var hi: usize = count;
    if (format == 1) {
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const v = try read(u16, cov, 4 + mid * 2);
            if (v == g) return @intCast(mid);
            if (v < g) lo = mid + 1 else hi = mid;
        }
        return null;
    }
    if (format != 2) return error.Unsupported;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const row = 4 + mid * 6;
        const start = try read(u16, cov, row);
        const end = try read(u16, cov, row + 2);
        if (g < start) {
            hi = mid;
        } else if (g > end) {
            lo = mid + 1;
        } else return (try read(u16, cov, row + 4)) +% (g - start);
    }
    return null;
}

/// Class of `g` in a ClassDef table; 0 for a glyph it does not list.
fn classOf(def: []const u8, g: Glyph) Error!u16 {
    const format = try read(u16, def, 0);
    if (format == 1) {
        const first = try read(u16, def, 2);
        const count = try read(u16, def, 4);
        if (g < first or g - first >= count) return 0;
        return read(u16, def, 6 + @as(usize, g - first) * 2);
    }
    if (format != 2) return error.Unsupported;
    var lo: usize = 0;
    var hi: usize = try read(u16, def, 2);
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const row = 4 + mid * 6;
        if (g < try read(u16, def, row)) {
            hi = mid;
        } else if (g > try read(u16, def, row + 2)) {
            lo = mid + 1;
        } else return read(u16, def, row + 4);
    }
    return 0;
}

/// Bytes of a ValueRecord with format `vf`: two per set bit.
fn valueSize(vf: u16) usize {
    return @as(usize, @popCount(vf)) * 2;
}

/// The XAdvance field of the ValueRecord at `at`, 0 when `vf` has none.
fn xAdvance(st: []const u8, at: usize, vf: u16) Error!i32 {
    if (vf & 0x0004 == 0) return 0;
    return try read(i16, st, at + valueSize(vf & 0x0003));
}

/// One PairPos subtable: the first glyph's x advance change, or null when the subtable does
/// not cover the pair (the next subtable of the lookup is tried then).
fn pairPos(st: []const u8, left: Glyph, right: Glyph) Error!?i32 {
    const format = try read(u16, st, 0);
    const cov = try read(u16, st, 2);
    const index = (try coverageIndex(st[@min(cov, st.len)..], left)) orelse return null;
    const vf1 = try read(u16, st, 4);
    const vf2 = try read(u16, st, 6);
    const row = 2 + valueSize(vf1) + valueSize(vf2);
    if (format == 1) {
        const set_off = try read(u16, st, 10 + @as(usize, index) * 2);
        const set = st[@min(set_off, st.len)..];
        var lo: usize = 0;
        var hi: usize = try read(u16, set, 0);
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const at = 2 + mid * row;
            const second = try read(u16, set, at);
            if (second == right) return try xAdvance(set, at + 2, vf1);
            if (second < right) lo = mid + 1 else hi = mid;
        }
        return null;
    }
    if (format != 2) return error.Unsupported;
    const def1 = try read(u16, st, 8);
    const def2 = try read(u16, st, 10);
    const class1 = try classOf(st[@min(def1, st.len)..], left);
    const class2 = try classOf(st[@min(def2, st.len)..], right);
    const count1 = try read(u16, st, 12);
    const count2 = try read(u16, st, 14);
    if (class1 >= count1 or class2 >= count2) return error.Malformed;
    const at = 16 + (@as(usize, class1) * count2 + class2) * (row - 2);
    return try xAdvance(st, at, vf1);
}

/// Sum of the GPOS pair adjustments for `left` then `right` over the lookups of `feature`
/// (a Feature table), each lookup applying its first subtable that covers the pair.
fn gposKerning(feature: []const u8, lookups: []const u8, left: Glyph, right: Glyph) Error!i32 {
    if (feature.len == 0) return 0;
    const count = try read(u16, feature, 2);
    var total: i32 = 0;
    for (0..count) |i| {
        const index = try read(u16, feature, 4 + i * 2);
        const lookup = lookups[@min(try read(u16, lookups, 2 + @as(usize, index) * 2), lookups.len)..];
        const kind = try read(u16, lookup, 0);
        if (kind != 2 and kind != 9) continue;
        const subtables = try read(u16, lookup, 4);
        for (0..subtables) |s| {
            var st = lookup[@min(try read(u16, lookup, 6 + s * 2), lookup.len)..];
            // Extension (type 9): a 32-bit offset to the real subtable.
            if (kind == 9) {
                if (try read(u16, st, 2) != 2) break;
                st = st[@min(try read(u32, st, 4), st.len)..];
            }
            if (try pairPos(st, left, right)) |v| {
                total += v;
                break;
            }
        }
    }
    return total;
}

/// The Feature table of the 'kern' feature for the default language of script DFLT, else
/// latn, else the first script; empty when there is none. One language system lists each
/// feature once, so no lookup is counted twice.
fn gposKernFeature(gpos: []const u8) Error![]const u8 {
    if (try read(u16, gpos, 0) != 1) return error.Unsupported;
    const scripts = gpos[@min(try read(u16, gpos, 4), gpos.len)..];
    const features = gpos[@min(try read(u16, gpos, 6), gpos.len)..];
    const script_count = try read(u16, scripts, 0);
    if (script_count == 0) return &.{};
    var pick: usize = 0;
    var rank: u8 = 0;
    for (0..script_count) |i| {
        const t = try read(u32, scripts, 2 + i * 6);
        const r: u8 = if (t == tag("DFLT")) 2 else if (t == tag("latn")) 1 else 0;
        if (r > rank) {
            pick = i;
            rank = r;
        }
    }
    const script = scripts[@min(try read(u16, scripts, 2 + pick * 6 + 4), scripts.len)..];
    const lang_off = try read(u16, script, 0);
    if (lang_off == 0) return &.{};
    const lang = script[@min(lang_off, script.len)..];
    const lang_count = try read(u16, lang, 4);
    for (0..lang_count) |i| {
        const f = try read(u16, lang, 6 + i * 2);
        const rec = 2 + @as(usize, f) * 6;
        if (try read(u32, features, rec) != tag("kern")) continue;
        return features[@min(try read(u16, features, rec + 4), features.len)..];
    }
    return &.{};
}

// Test font: a subset of Liberation Sans 2.1.5 (SIL OFL 1.1), built by testdata/make.py.
// Expected numbers come from fontTools reading the same file.
const test_ttf = @embedFile("testdata/test.ttf");
// Collection: the same Regular face and the Bold of the same family.
const test_ttc = @embedFile("testdata/test.ttc");

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

fn expectOutline(out: Outline, xy: []const [2]f32, on: []const u1, ends: []const u32) !void {
    try std.testing.expectEqual(xy.len, out.points);
    for (xy, on, 0..) |p, o, i| {
        try std.testing.expectEqual(p[0], out.x[i]);
        try std.testing.expectEqual(p[1], out.y[i]);
        try std.testing.expectEqual(o == 1, out.on[i]);
    }
    try std.testing.expectEqualSlices(u32, ends, out.ends[0..out.contours]);
}

test "simple glyph outlines of the test font" {
    const face = try Face.parse(test_ttf, 0);
    var x: [64]f32 = undefined;
    var y: [64]f32 = undefined;
    var on: [64]bool = undefined;
    var ends: [8]u32 = undefined;
    var out: Outline = .{ .x = &x, .y = &y, .on = &on, .ends = &ends };
    // Expected points: fontTools glyf['o'] and glyf['V'] of test.ttf.
    try face.outline(face.cmap.glyph('o'), &out);
    try expectOutline(out, &.{
        .{ 1053, 542 }, .{ 1053, 258 }, .{ 803, -20 },  .{ 565, -20 },  .{ 328, -20 },  .{ 86, 269 },
        .{ 86, 542 },   .{ 86, 1102 },  .{ 571, 1102 }, .{ 819, 1102 }, .{ 1053, 829 }, .{ 864, 542 },
        .{ 864, 766 },  .{ 731, 969 },  .{ 574, 969 },  .{ 416, 969 },  .{ 275, 762 },  .{ 275, 542 },
        .{ 275, 328 },  .{ 414, 113 },  .{ 563, 113 },  .{ 725, 113 },  .{ 864, 321 },
    }, &.{ 1, 0, 0, 1, 0, 0, 1, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0 }, &.{ 10, 22 });
    // Appending: V's points follow o's and its contour end is offset by o's 23 points.
    try face.outline(face.cmap.glyph('V'), &out);
    try std.testing.expectEqual(32, out.points);
    try std.testing.expectEqualSlices(u32, &.{ 10, 22, 31 }, out.ends[0..3]);
    try std.testing.expectEqual(@as(f32, 782), out.x[23]);
    try std.testing.expectEqual(@as(f32, 1357), out.x[31]);
    try std.testing.expectEqual(@as(f32, 1409), out.y[31]);
    // A space has no outline.
    try face.outline(face.cmap.glyph(' '), &out);
    try std.testing.expectEqual(32, out.points);
}

test "outline errors leave the columns as they were" {
    const face = try Face.parse(test_ttf, 0);
    var x: [8]f32 = undefined;
    var y: [8]f32 = undefined;
    var on: [8]bool = undefined;
    var ends: [1]u32 = undefined;
    var out: Outline = .{ .x = &x, .y = &y, .on = &on, .ends = &ends };
    try std.testing.expectError(error.NoSpace, face.outline(face.cmap.glyph('o'), &out));
    try std.testing.expectEqual(0, out.points);
    try std.testing.expectEqual(0, out.contours);
    try std.testing.expectError(error.Malformed, face.outline(face.glyph_count, &out));
}

test "kerning of the test font" {
    var face = try Face.parse(test_ttf, 0);
    const g = struct {
        fn of(f: Face, c: u21) Glyph {
            return f.cmap.glyph(c);
        }
    }.of;
    // GPOS: PairPos format 1 pairs, and the format 2 class pair [o e eacute] v (make.py).
    try std.testing.expectEqual(-152, face.kerning(g(face, 'A'), g(face, 'V')));
    try std.testing.expectEqual(-227, face.kerning(g(face, 'T'), g(face, 'o')));
    try std.testing.expectEqual(-113, face.kerning(g(face, ' '), g(face, 'A')));
    try std.testing.expectEqual(-50, face.kerning(g(face, 'o'), g(face, 'v')));
    try std.testing.expectEqual(-50, face.kerning(g(face, 0xe9), g(face, 'v')));
    try std.testing.expectEqual(0, face.kerning(g(face, 'a'), g(face, 'v')));
    try std.testing.expectEqual(0, face.kerning(g(face, 'V'), g(face, 'T')));
    // The legacy kern table (fontTools kern.kernTables[0]): the same pairs, no class pair.
    face.gpos_kern = &.{};
    try std.testing.expectEqual(-152, face.kerning(g(face, 'A'), g(face, 'V')));
    try std.testing.expectEqual(-113, face.kerning(g(face, 'V'), g(face, 'e')));
    try std.testing.expectEqual(-37, face.kerning(g(face, 'A'), g(face, 'v')));
    try std.testing.expectEqual(0, face.kerning(g(face, 'o'), g(face, 'v')));
    // Damaged data reads as no kerning.
    face.kern = face.kern[0..20];
    try std.testing.expectEqual(0, face.kerning(g(face, 'V'), g(face, 'o')));
}

test "a composite glyph of the test font" {
    const face = try Face.parse(test_ttf, 0);
    var x: [64]f32 = undefined;
    var y: [64]f32 = undefined;
    var on: [64]bool = undefined;
    var ends: [8]u32 = undefined;
    var out: Outline = .{ .x = &x, .y = &y, .on = &on, .ends = &ends };
    // eacute = e + acute moved right by 368. Expected: fontTools glyf['eacute'].getCoordinates.
    try face.outline(face.cmap.glyph(0xe9), &out);
    try expectOutline(out, &.{
        .{ 276, 503 },  .{ 276, 317 },  .{ 430, 115 },  .{ 578, 115 },  .{ 695, 115 },   .{ 836, 209 },
        .{ 861, 281 },  .{ 1019, 236 }, .{ 922, -20 },  .{ 578, -20 },  .{ 338, -20 },   .{ 87, 266 },
        .{ 87, 548 },   .{ 87, 816 },   .{ 338, 1102 }, .{ 571, 1102 }, .{ 1048, 1102 }, .{ 1048, 527 },
        .{ 1048, 503 }, .{ 862, 641 },  .{ 847, 812 },  .{ 703, 969 },  .{ 568, 969 },   .{ 437, 969 },
        .{ 284, 794 },  .{ 278, 641 },  .{ 440, 1201 }, .{ 440, 1221 }, .{ 657, 1508 },  .{ 864, 1508 },
        .{ 864, 1479 }, .{ 534, 1201 },
    }, &.{ 1, 0, 0, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 0, 0, 1, 0, 1, 1, 1, 0, 0, 1, 0, 0, 1, 1, 1, 1, 1, 1, 1 }, &.{ 18, 25, 31 });
}

test "composite scale, point matching and cycles" {
    var face = try Face.parse(test_ttf, 0);
    // Glyph 0: simple, (100, 0) (200, 100). Glyph 1: glyph 0 scaled by 0.5 and moved by
    // (10, 20), then glyph 0 again with its point 0 matched to point 1 of the first copy.
    // Glyph 2: a composite that contains itself.
    const simple = "\x00\x01" ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x00\x01\x00\x00\x01\x01\x00\x64\x00\x64\x00\x00\x00\x64";
    const composite = "\xff\xff" ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x00\x2b\x00\x00\x00\x0a\x00\x14\x20\x00" ++
        "\x00\x00\x00\x00\x01\x00";
    const cyclic = "\xff\xff" ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x00\x02\x00\x02\x00\x00";
    face.glyf = simple ++ composite ++ cyclic;
    face.loca = "\x00\x00\x00\x0c\x00\x19\x00\x21";
    face.loca_long = false;
    face.glyph_count = 3;
    var x: [8]f32 = undefined;
    var y: [8]f32 = undefined;
    var on: [8]bool = undefined;
    var ends: [4]u32 = undefined;
    var out: Outline = .{ .x = &x, .y = &y, .on = &on, .ends = &ends };
    try face.outline(1, &out);
    try expectOutline(out, &.{ .{ 60, 20 }, .{ 110, 70 }, .{ 110, 70 }, .{ 210, 170 } }, &.{ 1, 1, 1, 1 }, &.{ 1, 3 });
    try std.testing.expectError(error.Malformed, face.outline(2, &out));
    try std.testing.expectEqual(4, out.points);
    // The second copy does not fit: nothing of glyph 1 is kept.
    out.points = 5;
    out.contours = 0;
    try std.testing.expectError(error.NoSpace, face.outline(1, &out));
    try std.testing.expectEqual(5, out.points);
}

test "faces of a collection" {
    try std.testing.expectEqual(1, try faceCount(test_ttf));
    try std.testing.expectEqual(0, try faceOffset(test_ttf, 0));
    try std.testing.expectError(error.NoSuchFace, faceOffset(test_ttf, 1));
    // Expected: fontTools TTCollection on test.ttc.
    try std.testing.expectEqual(2, try faceCount(test_ttc));
    try std.testing.expectEqual(20, try faceOffset(test_ttc, 0));
    try std.testing.expectEqual(2096, try faceOffset(test_ttc, 1));
    try std.testing.expectError(error.NoSuchFace, faceOffset(test_ttc, 2));
    const regular = try Face.parse(test_ttc, try faceOffset(test_ttc, 0));
    const bold = try Face.parse(test_ttc, try faceOffset(test_ttc, 1));
    try std.testing.expectEqual(HMetrics{ .advance = 1366, .left_bearing = 4 }, regular.hMetrics(regular.cmap.glyph('A')));
    try std.testing.expectEqual(HMetrics{ .advance = 1479, .left_bearing = 51 }, bold.hMetrics(bold.cmap.glyph('A')));
    try std.testing.expectEqual(1854, bold.ascender);
    try std.testing.expectEqual(2048, bold.units_per_em);
    try std.testing.expectEqual(1, bold.mac_style);
    // A collection header that claims more faces than it has offsets for.
    try std.testing.expectError(error.Truncated, faceCount(test_ttc[0..15]));
}

test "face selection by style" {
    try std.testing.expectEqual(0, try findFace(test_ttc, .{}));
    try std.testing.expectEqual(1, try findFace(test_ttc, .{ .bold = true }));
    try std.testing.expectEqual(null, try findFace(test_ttc, .{ .italic = true }));
    try std.testing.expectEqual(0, try findFace(test_ttf, .{}));
    try std.testing.expectEqual(null, try findFace(test_ttf, .{ .bold = true }));
}

test "mutated test fonts are errors, not crashes" {
    // A short run of the fuzzer (fuzz.zig); `zig build font-fuzz` runs it for a set time.
    const fuzz = @import("fuzz.zig");
    var buf: [@max(test_ttf.len, test_ttc.len)]u8 = undefined;
    for (0..300) |i| {
        var prng: std.Random.DefaultPrng = .init(i);
        fuzz.exercise(fuzz.mutate(prng.random(), &buf));
    }
}
