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
