//! OpenType layout tables (GSUB, GPOS, GDEF): the common structures the shaper reads. Tier 0.
//!
//! Like src/text/font/opentype.zig, every read is bounds checked and fails with
//! `error.Truncated` rather than reading past the end; fonts are untrusted. Spec:
//! https://learn.microsoft.com/typography/opentype/spec/chapter2 (common table formats).
//! Coverage and class lookups are binary searches; this is per glyph, not per row of a pass.
//! (opentype.zig has private copies of `coverageIndex` and `classOf` for its kerning.)

const std = @import("std");
const opentype = @import("../font/opentype.zig");

pub const Error = error{ Truncated, Unsupported };

/// A big-endian `T` at `at`.
pub fn read(comptime T: type, data: []const u8, at: usize) Error!T {
    const n = @sizeOf(T);
    if (at > data.len or data.len - at < n) return error.Truncated;
    return std.mem.readInt(T, data[at..][0..n], .big);
}

/// `data` from the 16-bit offset stored at `at` (relative to `data`), to its end.
pub fn at16(data: []const u8, at: usize) Error![]const u8 {
    const off = try read(u16, data, at);
    if (off > data.len) return error.Truncated;
    return data[off..];
}

/// Lookup indices of a feature, at most `max_lookups`, in the order the feature lists them.
pub const Lookups = struct {
    index: [max_lookups]u16 = undefined,
    len: u32 = 0,

    pub const max_lookups = 32;

    pub fn slice(l: *const Lookups) []const u16 {
        return l.index[0..l.len];
    }
};

/// Appends to `out` the lookups of feature `feature` in GSUB or GPOS `table`, for the default
/// language system of script `DFLT`, else `latn`, else the first script. Sorted, as lookups
/// apply in LookupList order. Several calls merge features (duplicates dropped).
pub fn featureLookups(table: []const u8, feature: u32, out: *Lookups) Error!void {
    if (table.len == 0) return;
    if (try read(u16, table, 0) != 1) return error.Unsupported;
    const scripts = try at16(table, 4);
    const features = try at16(table, 6);
    const script_count = try read(u16, scripts, 0);
    if (script_count == 0) return;
    var pick: usize = 0;
    var rank: u8 = 0;
    for (0..script_count) |i| {
        const t = try read(u32, scripts, 2 + i * 6);
        const r: u8 = if (t == opentype.tag("DFLT")) 2 else if (t == opentype.tag("latn")) 1 else 0;
        if (r > rank) {
            pick = i;
            rank = r;
        }
    }
    const script = try at16(scripts, 2 + pick * 6 + 4);
    if (try read(u16, script, 0) == 0) return;
    const lang = try at16(script, 0);
    const count = try read(u16, lang, 4);
    for (0..count) |i| {
        const f = try read(u16, lang, 6 + i * 2);
        const rec = 2 + @as(usize, f) * 6;
        if (try read(u32, features, rec) != feature) continue;
        const ft = try at16(features, rec + 4);
        const n = try read(u16, ft, 2);
        for (0..n) |j| insert(out, try read(u16, ft, 4 + j * 2));
    }
}

fn insert(out: *Lookups, index: u16) void {
    const have = out.slice();
    const at = std.sort.lowerBound(u16, have, index, struct {
        fn order(a: u16, b: u16) std.math.Order {
            return std.math.order(a, b);
        }
    }.order);
    if (at < have.len and have[at] == index) return;
    if (out.len == Lookups.max_lookups) return;
    std.mem.copyBackwards(u16, out.index[at + 1 .. out.len + 1], out.index[at..out.len]);
    out.index[at] = index;
    out.len += 1;
}

/// Lookup `index` of GSUB or GPOS `table`.
pub fn lookup(table: []const u8, index: u16) Error![]const u8 {
    const list = try at16(table, 8);
    if (index >= try read(u16, list, 0)) return error.Truncated;
    return at16(list, 2 + @as(usize, index) * 2);
}

/// Lookup flag bits.
pub const ignore_marks = 0x0008;

/// Subtable `s` of `lk` with its type, extension subtables (GSUB 7, GPOS 9) resolved.
pub fn subtable(lk: []const u8, s: usize, extension: u16) Error!struct { kind: u16, data: []const u8 } {
    const kind = try read(u16, lk, 0);
    const st = try at16(lk, 6 + s * 2);
    if (kind != extension) return .{ .kind = kind, .data = st };
    const off = try read(u32, st, 4);
    if (off > st.len) return error.Truncated;
    return .{ .kind = try read(u16, st, 2), .data = st[off..] };
}

/// Index of `g` in a Coverage table, or null.
pub fn coverageIndex(cov: []const u8, g: u16) Error!?u16 {
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
        if (g < try read(u16, cov, row)) {
            hi = mid;
        } else if (g > try read(u16, cov, row + 2)) {
            lo = mid + 1;
        } else return (try read(u16, cov, row + 4)) +% (g - try read(u16, cov, row));
    }
    return null;
}

/// Class of `g` in a ClassDef table; 0 for a glyph it does not list.
pub fn classOf(def: []const u8, g: u16) Error!u16 {
    if (def.len == 0) return 0;
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

test "coverage and class tables" {
    // Coverage format 1 [3 5 9], format 2 ranges [10..12 -> 0] [20..20 -> 3].
    const c1 = [_]u8{ 0, 1, 0, 3, 0, 3, 0, 5, 0, 9 };
    try std.testing.expectEqual(@as(?u16, 1), try coverageIndex(&c1, 5));
    try std.testing.expectEqual(@as(?u16, null), try coverageIndex(&c1, 4));
    const c2 = [_]u8{ 0, 2, 0, 2, 0, 10, 0, 12, 0, 0, 0, 20, 0, 20, 0, 3 };
    try std.testing.expectEqual(@as(?u16, 2), try coverageIndex(&c2, 12));
    try std.testing.expectEqual(@as(?u16, 3), try coverageIndex(&c2, 20));
    try std.testing.expectEqual(@as(?u16, null), try coverageIndex(&c2, 13));
    // ClassDef format 1 from glyph 4: classes [1 2].
    const d1 = [_]u8{ 0, 1, 0, 4, 0, 2, 0, 1, 0, 2 };
    try std.testing.expectEqual(2, try classOf(&d1, 5));
    try std.testing.expectEqual(0, try classOf(&d1, 6));
    try std.testing.expectError(error.Truncated, coverageIndex(c1[0..7], 9));
}
