//! Shaping cache: shaped glyph runs kept across frames, so a run is shaped once while its text,
//! font and features stay the same. Tier 0: the table is carved from the caller's buffer and
//! never grows.
//!
//! The same shape as the extents cache of the measure protocol (src/text/protocol.zig, `Cache`):
//! direct-mapped, keyed by Wyhash of the text seeded with the font and features, one entry per
//! slot, a new key evicts the old one. Each slot owns room for `per_slot` glyphs; a run with
//! more is shaped every time instead of cached. Runs are in font units, so the pixel size is
//! not part of the key: one entry serves every size.

const std = @import("std");
const mem = @import("../../core/mem.zig");
const shaping = @import("shape.zig");

pub const Cache = struct {
    /// Slots - 1. Index from bit 1 because generated keys reserve bit 0 for the empty marker.
    mask: u32,
    per_slot: u32,
    /// Per slot: the key (0 marks an empty slot; `key` never returns 0) and the glyph count.
    keys: []u64,
    lens: []u32,
    /// `per_slot` rows per slot, slot s at rows s * per_slot.
    glyphs: shaping.Run,

    /// Carves a table of `slots` entries (a power of two) of up to `per_slot` glyphs each, all
    /// empty. With a counting carver this sizes the buffer instead.
    pub fn init(carver: *mem.Carver, slots: u32, per_slot: u32) Cache {
        std.debug.assert(std.math.isPowerOfTwo(slots) and per_slot > 0);
        const rows = @as(usize, slots) * per_slot;
        return .{
            .mask = slots - 1,
            .per_slot = per_slot,
            .keys = carver.slice(u64, slots),
            .lens = carver.slice(u32, slots),
            .glyphs = .{
                .glyph = carver.slice(u16, rows),
                .cluster = carver.slice(u32, rows),
                .advance = carver.slice(i32, rows),
                .x_offset = carver.slice(i32, rows),
                .y_offset = carver.slice(i32, rows),
            },
        };
    }

    /// Forgets every entry, e.g. after a font is reloaded.
    pub fn clear(c: *Cache) void {
        @memset(c.keys, 0);
    }

    /// The key of a run: Wyhash of its bytes, seeded with the font and the features. Two
    /// different runs share a key with probability about 2^-63; the cache accepts that
    /// instead of storing the bytes (as the extents cache does).
    pub fn key(text: []const u8, font: u16, features: shaping.Features) u64 {
        const flags: u64 = @as(u64, @intFromBool(features.liga)) | (@as(u64, @intFromBool(features.kern)) << 1) |
            (@as(u64, @intFromBool(features.mark)) << 2);
        return std.hash.Wyhash.hash((@as(u64, font) << 8) | flags, text) | 1;
    }

    /// The cached run of key `k`, as a view of its slot (valid until the slot is replaced), or
    /// null.
    pub fn get(c: *const Cache, k: u64) ?shaping.Run {
        const s: usize = @intCast((k >> 1) & c.mask); // mask < slot count, so it fits a 32-bit usize
        if (c.keys[s] != k) return null;
        return c.slot(s, c.lens[s]);
    }

    /// Records `run` under key `k`, replacing what the slot held. Returns false, storing
    /// nothing, when the run is longer than a slot.
    pub fn put(c: *Cache, k: u64, run: *const shaping.Run) bool {
        if (run.len > c.per_slot) return false;
        const s: usize = @intCast((k >> 1) & c.mask);
        const dst = c.slot(s, run.len);
        @memcpy(dst.glyph, run.glyph[0..run.len]);
        @memcpy(dst.cluster, run.cluster[0..run.len]);
        @memcpy(dst.advance, run.advance[0..run.len]);
        @memcpy(dst.x_offset, run.x_offset[0..run.len]);
        @memcpy(dst.y_offset, run.y_offset[0..run.len]);
        c.keys[s] = k;
        c.lens[s] = run.len;
        return true;
    }

    /// The common case in one call: the shaped run of `text` in `font` with `features`, from
    /// the cache, else shaped into `scratch` and stored. The result is a view of the slot or
    /// of `scratch`.
    pub fn shape(c: *Cache, shaper: *const shaping.Shaper, font: u16, text: []const u8, features: shaping.Features, scratch: *shaping.Run) error{NoSpace}!shaping.Run {
        const k = key(text, font, features);
        if (c.get(k)) |hit| return hit;
        try shaper.shape(text, scratch, features);
        _ = c.put(k, scratch);
        return scratch.*;
    }

    fn slot(c: *const Cache, s: usize, n: u32) shaping.Run {
        const at = s * c.per_slot;
        const g = c.glyphs;
        return .{
            .glyph = g.glyph[at..][0..n],
            .cluster = g.cluster[at..][0..n],
            .advance = g.advance[at..][0..n],
            .x_offset = g.x_offset[at..][0..n],
            .y_offset = g.y_offset[at..][0..n],
            .len = n,
        };
    }
};

// ---------------------------------------------------------------------------------------------

const Face = @import("../font/opentype.zig").Face;

fn Fixture(comptime slots: u32, comptime per_slot: u32) type {
    return struct {
        buf: [bytes]u8 align(mem.column_align) = undefined,

        const bytes = blk: {
            var counter: mem.Carver = .{ .buf = null };
            _ = Cache.init(&counter, slots, per_slot);
            break :blk counter.off;
        };

        fn cache(f: *@This()) Cache {
            var carver: mem.Carver = .{ .buf = &f.buf };
            return .init(&carver, slots, per_slot);
        }
    };
}

fn expectSameRun(want: *const shaping.Run, got: *const shaping.Run) !void {
    try std.testing.expectEqual(want.len, got.len);
    try std.testing.expectEqualSlices(u16, want.glyph[0..want.len], got.glyph[0..got.len]);
    try std.testing.expectEqualSlices(u32, want.cluster[0..want.len], got.cluster[0..got.len]);
    try std.testing.expectEqualSlices(i32, want.advance[0..want.len], got.advance[0..got.len]);
    try std.testing.expectEqualSlices(i32, want.x_offset[0..want.len], got.x_offset[0..got.len]);
    try std.testing.expectEqualSlices(i32, want.y_offset[0..want.len], got.y_offset[0..got.len]);
}

test "cached runs equal freshly shaped ones" {
    // Every HarfBuzz case, twice through a cache: the second pass is all hits and gives the
    // same glyphs, which still match HarfBuzz.
    const shaper: shaping.Shaper = .init(try Face.parse(shaping.test_font, 0));
    var fx: Fixture(64, 32) = .{};
    var cache = fx.cache();
    var buf: [1024]u8 = undefined;
    var cases: [16]shaping.HbCase = undefined;
    const n = try shaping.hbCases("kern,liga,mark,mkmk", &buf, &cases);
    var scratch_cols: shaping.TestRun = .{};
    var scratch = scratch_cols.run();
    var hits: u32 = 0;
    for (0..2) |_| {
        for (cases[0..n]) |*c| {
            hits += @intFromBool(cache.get(Cache.key(c.text, 0, .{})) != null);
            const got = try cache.shape(&shaper, 0, c.text, .{}, &scratch);
            var want = c.expected.run();
            want.len = c.len;
            try expectSameRun(&want, &got);
        }
    }
    try std.testing.expectEqual(n, hits);
}

test "font and features are part of the key, the pixel size is not" {
    const a = Cache.key("office", 0, .{});
    try std.testing.expect(a != Cache.key("office", 1, .{}));
    try std.testing.expect(a != Cache.key("office", 0, .{ .liga = false }));
    try std.testing.expect(a != Cache.key("offices", 0, .{}));
    try std.testing.expect(a & 1 == 1);
    const shaper: shaping.Shaper = .init(try Face.parse(shaping.test_font, 0));
    var fx: Fixture(64, 32) = .{};
    var cache = fx.cache();
    var cols: shaping.TestRun = .{};
    var scratch = cols.run();
    const with = try cache.shape(&shaper, 0, "office", .{}, &scratch);
    try std.testing.expectEqual(4, with.len); // ffi ligature
    const without = try cache.shape(&shaper, 0, "office", .{ .liga = false }, &scratch);
    try std.testing.expectEqual(6, without.len);
}

test "both slots hold shaped runs and a collision replaces only one" {
    const shaper: shaping.Shaper = .init(try Face.parse(shaping.test_font, 0));
    var fx: Fixture(2, 8) = .{};
    var cache = fx.cache();
    var cols: shaping.TestRun = .{};
    var scratch = cols.run();
    const type_key = Cache.key("Type", 0, .{});
    const avta_key = Cache.key("AVTa", 0, .{});
    _ = try cache.shape(&shaper, 0, "Type", .{}, &scratch);
    _ = try cache.shape(&shaper, 0, "AVTa", .{}, &scratch);
    try std.testing.expect(cache.get(type_key) != null);
    try expectSameRun(&scratch, &cache.get(avta_key).?);

    // "office" maps to the same slot as "Type".
    _ = try cache.shape(&shaper, 0, "office", .{}, &scratch);
    try std.testing.expect(cache.get(type_key) == null);
    try std.testing.expect(cache.get(avta_key) != null);
    try expectSameRun(&scratch, &cache.get(Cache.key("office", 0, .{})).?);
}

test "a new key evicts the slot; long runs are not cached" {
    const shaper: shaping.Shaper = .init(try Face.parse(shaping.test_font, 0));
    var fx: Fixture(1, 4) = .{};
    var cache = fx.cache();
    var cols: shaping.TestRun = .{};
    var scratch = cols.run();
    _ = try cache.shape(&shaper, 0, "Type", .{}, &scratch);
    try std.testing.expect(cache.get(Cache.key("Type", 0, .{})) != null);
    _ = try cache.shape(&shaper, 0, "AVTa", .{}, &scratch);
    try std.testing.expect(cache.get(Cache.key("Type", 0, .{})) == null);
    // Six glyphs do not fit a four-glyph slot: shaped, returned, not stored.
    const long = try cache.shape(&shaper, 0, "AVTavo", .{}, &scratch);
    try std.testing.expectEqual(6, long.len);
    try std.testing.expect(cache.get(Cache.key("AVTavo", 0, .{})) == null);
    try std.testing.expect(cache.get(Cache.key("AVTa", 0, .{})) != null);
    cache.clear();
    try std.testing.expect(cache.get(Cache.key("AVTa", 0, .{})) == null);
}
