//! The measure / wrap protocol: how text extents reach layout. Data, not callbacks.
//!
//! The core never calls into a font. There is no `measure(node)` hook, no shaper interface and
//! no re-measure loop that layout drives. Text is a side list (`Texts`), and a font is anything
//! that reads its columns and writes others back, at two points the caller sequences:
//!
//! 1. Measure. After the tree is built and before layout, the caller fills `Texts.w` and
//!    `Texts.h` for every run, from `start`/`bytes` (the run's bytes in `Strings`), `px` and
//!    `font`. This is the single-line extent.
//! 2. Wrap. After widths are resolved, layout writes `Texts.avail` (the width it gave each run).
//!    For runs whose `wrap` is 1.0 the caller may then rewrite `w` and `h`; layout reads them for
//!    the vertical axis. Runs that do not wrap keep their measured extent.
//!
//! Why data: a callback per run is an indirect call per row, hides the loop from SIMD, and hands
//! control flow to the framework (Muratori, *Designing and Evaluating Reusable Components*:
//! flow control stays with the caller). Columns in and columns out let one font measure every
//! run in one vector loop, let a real shaper run on another thread or cache by string, and let
//! a test write the numbers by hand. Which font a run uses is a column (`font`), not a type, so
//! several fonts are several passes over the same rows, each masked by `font`.
//!
//! `Mono` below is the protocol for a fixed-advance font and the reference for plugging in a
//! real shaper. Ported from prototype/ui.zig ("fonts").

const std = @import("std");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");
const Texts = @import("../core/texts.zig").Texts;
const Strings = @import("../core/strings.zig").Strings;

const W = simd.lanes;

/// A fixed-advance font: every byte is `advance` ems wide, every line `line` ems tall.
pub const Mono = struct {
    /// Advance per byte, in ems.
    advance: f32 = 0.6,
    /// Line height, in ems.
    line: f32 = 1.25,

    /// SIMD. Single-line extent of every run. Reads `bytes`, `px`; writes `w`, `h`.
    /// Rows past `tx.len` up to the padding are written too; they are never read.
    pub fn measure(font: Mono, tx: *Texts) void {
        const c = &tx.c;
        const n = simd.padded(tx.len);
        var i: usize = 0;
        while (i < n) : (i += W) {
            const px = simd.loadF(c.px, i);
            const count: simd.F = @floatFromInt(simd.loadU(c.bytes, i));
            simd.storeF(c.w, i, count * px * simd.f(font.advance));
            simd.storeF(c.h, i, px * simd.f(font.line));
        }
    }

    /// SIMD. Re-flows runs flagged `wrap` into `avail` and rewrites `w`, `h`. Runs after
    /// `measure` and `layout.textAvail`. A run that does not wrap keeps `w` and gets one line.
    pub fn wrap(font: Mono, tx: *Texts) void {
        const c = &tx.c;
        const n = simd.padded(tx.len);
        const one = simd.f(1);
        var i: usize = 0;
        while (i < n) : (i += W) {
            const px = simd.loadF(c.px, i);
            // The floor keeps a zero-size font from dividing by zero.
            const adv = @max(px * simd.f(font.advance), simd.f(1e-6));
            const count: simd.F = @floatFromInt(simd.loadU(c.bytes, i));
            const avail = simd.loadF(c.avail, i);
            const wraps = simd.loadF(c.wrap, i) > simd.f(0);
            const per_line = @max(@floor(avail / adv + simd.f(0.5)), one);
            const lines = @max(@ceil(count / per_line), one);
            const w = simd.loadF(c.w, i);
            simd.storeF(c.w, i, @select(f32, wraps, @min(w, avail), w));
            simd.storeF(c.h, i, @select(f32, wraps, lines, one) * px * simd.f(font.line));
        }
    }
};

/// Remembers measured extents across frames, keyed by a hash of the run's bytes, its font and
/// its size, so an expensive shaper measures only text it has not seen. Font-agnostic: it sits
/// on the measure step of the protocol, around whatever fills `w` and `h`.
///
/// Per frame: `lookup` fills `w`, `h` of every hit and lists the misses; the caller measures the
/// misses; `store` records them. Direct-mapped, one entry per slot: a new key evicts the old one.
/// Tier 0: the table is carved from the caller's buffer and never grows.
pub const Cache = struct {
    /// Slots - 1; the slot count is a power of two.
    mask: u32,
    c: Columns,

    pub const Columns = struct {
        /// 0 marks an empty slot; `key` never returns 0.
        key: []u64,
        w: []f32,
        h: []f32,
    };

    /// Carves a table of `slots` entries (a power of two), all empty. With a counting carver this
    /// sizes the buffer instead.
    pub fn init(carver: *mem.Carver, slots: u32) Cache {
        std.debug.assert(std.math.isPowerOfTwo(slots));
        return .{ .mask = slots - 1, .c = carver.columns(Columns, slots) };
    }

    /// Forgets every entry, e.g. after a font is reloaded.
    pub fn clear(cache: *Cache) void {
        @memset(cache.c.key, 0);
    }

    /// The key of a run: Wyhash of its bytes, seeded with font and size. Two different runs share a
    /// key with probability about 2^-63; the cache accepts that instead of storing the bytes.
    pub fn key(bytes: []const u8, font: u16, px: f32) u64 {
        const seed = (@as(u64, font) << 32) | @as(u32, @bitCast(px));
        return std.hash.Wyhash.hash(seed, bytes) | 1;
    }

    /// Writes `w`, `h` of every run of `tx` found in the cache and appends the rows of the others
    /// to `misses` (at least `tx.len` long). Returns the number of misses. Hashing reads each run's
    /// bytes, so this is a scalar loop; hits are selected, not branched on.
    pub fn lookup(cache: *const Cache, tx: *Texts, strings: *const Strings, misses: []u32) u32 {
        std.debug.assert(misses.len >= tx.len);
        const c = &tx.c;
        var n: u32 = 0;
        for (0..tx.len) |k| {
            const want = key(strings.get(.{ .start = c.start[k], .bytes = c.bytes[k] }), c.font[k], c.px[k]);
            const slot = want & cache.mask;
            const hit = cache.c.key[slot] == want;
            c.w[k] = simd.selF(hit, cache.c.w[slot], c.w[k]);
            c.h[k] = simd.selF(hit, cache.c.h[slot], c.h[k]);
            // Write always, advance by 0 or 1.
            misses[n] = @intCast(k);
            n += @intFromBool(!hit);
        }
        return n;
    }

    /// Records the measured `w`, `h` of the runs listed in `rows` (the misses, once measured).
    pub fn store(cache: *Cache, tx: *const Texts, strings: *const Strings, rows: []const u32) void {
        const c = &tx.c;
        for (rows) |k| {
            const want = key(strings.get(.{ .start = c.start[k], .bytes = c.bytes[k] }), c.font[k], c.px[k]);
            const slot = want & cache.mask;
            cache.c.key[slot] = want;
            cache.c.w[slot] = c.w[k];
            cache.c.h[slot] = c.h[k];
        }
    }
};

const testing = std.testing;

fn Fixture(comptime cap: u32) type {
    return struct {
        buf: [bytes]u8 align(mem.column_align) = undefined,

        const bytes = blk: {
            var counter: mem.Carver = .{ .buf = null };
            _ = Texts.init(&counter, cap);
            break :blk counter.off;
        };
        fn texts(fx: *@This()) Texts {
            var carver: mem.Carver = .{ .buf = &fx.buf };
            return Texts.init(&carver, cap);
        }
    };
}

test "the protocol is columns: a caller can measure by hand" {
    var fx: Fixture(4) = .{};
    var tx = fx.texts();
    const k = tx.push(0, .{ .start = 0, .bytes = 3 }, &.{ .px = 10, .wrap = true });
    // Inputs a font reads, outputs it writes: plain f32 columns, no hook to register.
    try testing.expectEqual(0, tx.c.w[k]);
    try testing.expectEqual(0, tx.c.h[k]);
    tx.c.w[k] = 18;
    tx.c.h[k] = 12;
    tx.c.avail[k] = 10;
    try testing.expectEqual(1, tx.c.wrap[k]);
    try testing.expectEqual(18, tx.c.w[k]);
}

test "Mono.measure: bytes * px * advance wide, px * line tall, for every run" {
    var fx: Fixture(20) = .{};
    var tx = fx.texts();
    // More runs than lanes, so the loop takes several steps at every lane count.
    for (0..19) |k| _ = tx.push(0, .{ .bytes = @intCast(k) }, &.{ .px = 10 });
    _ = tx.push(0, .{ .bytes = 24 }, &.{ .px = 20 });
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    font.measure(&tx);
    for (0..19) |k| {
        try testing.expectEqual(@as(f32, @floatFromInt(k)) * 5, tx.c.w[k]);
        try testing.expectEqual(12, tx.c.h[k]);
    }
    try testing.expectEqual(240, tx.c.w[19]);
    try testing.expectEqual(24, tx.c.h[19]);
}

test "Mono.wrap: wrapping runs re-flow into avail, others keep one line" {
    var fx: Fixture(20) = .{};
    var tx = fx.texts();
    // The prototype's paragraph: 24 bytes * 5 px = 120 px into 100 px is two lines.
    for (0..10) |_| _ = tx.push(0, .{ .bytes = 24 }, &.{ .px = 10, .wrap = true });
    for (0..10) |_| _ = tx.push(0, .{ .bytes = 24 }, &.{ .px = 10 });
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    font.measure(&tx);
    for (0..20) |k| tx.c.avail[k] = 100;
    tx.c.avail[1] = 200; // fits on one line: w stays 120
    tx.c.avail[2] = 0; // no room: one byte per line, w clamps to 0
    font.wrap(&tx);
    try testing.expectEqual(100, tx.c.w[0]);
    try testing.expectEqual(24, tx.c.h[0]);
    try testing.expectEqual(120, tx.c.w[1]);
    try testing.expectEqual(12, tx.c.h[1]);
    try testing.expectEqual(0, tx.c.w[2]);
    try testing.expectEqual(24 * 12, tx.c.h[2]);
    for (3..10) |k| try testing.expectEqual(24, tx.c.h[k]);
    for (10..20) |k| {
        try testing.expectEqual(120, tx.c.w[k]);
        try testing.expectEqual(12, tx.c.h[k]);
    }
}

test "Cache: misses are measured once, hits come back without measuring" {
    var fx: Fixture(4) = .{};
    var tx = fx.texts();
    var str_buf: [64]u8 = undefined;
    var strings: Strings = .{ .buf = &str_buf };
    var cache_buf: [cache_bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &cache_buf };
    var cache: Cache = .init(&carver, 16);
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    var misses: [4]u32 = undefined;

    const frame = struct {
        fn build(t: *Texts, s: *Strings) void {
            t.reset();
            s.reset();
            _ = t.push(0, s.add("hello"), &.{ .px = 10 });
            _ = t.push(1, s.add("hello"), &.{ .px = 20 }); // same bytes, other size
            _ = t.push(2, s.add("hello"), &.{ .px = 10, .font = @fromBackingInt(1) }); // other font
            _ = t.push(3, s.add("hi"), &.{ .px = 10 });
        }
    };

    // Frame 1: everything misses; measure the misses (here Mono, standing in for a shaper).
    frame.build(&tx, &strings);
    var n = cache.lookup(&tx, &strings, &misses);
    try testing.expectEqual(4, n);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, misses[0..n]);
    font.measure(&tx);
    cache.store(&tx, &strings, misses[0..n]);

    // Frame 2: same runs, all hits, extents equal to measuring.
    frame.build(&tx, &strings);
    n = cache.lookup(&tx, &strings, &misses);
    try testing.expectEqual(0, n);
    try testing.expectEqualSlices(f32, &.{ 25, 50, 25, 10 }, tx.c.w[0..4]);
    try testing.expectEqualSlices(f32, &.{ 12, 24, 12, 12 }, tx.c.h[0..4]);

    // Different bytes miss; clear forgets everything.
    tx.reset();
    _ = tx.push(0, strings.add("hellp"), &.{ .px = 10 });
    try testing.expectEqual(1, cache.lookup(&tx, &strings, &misses));
    try testing.expectEqual(0, tx.c.w[0]);
    frame.build(&tx, &strings);
    cache.clear();
    try testing.expectEqual(4, cache.lookup(&tx, &strings, &misses));
}

test "Cache: key separates bytes, font and size, and is never the empty marker" {
    const a = Cache.key("abc", 0, 14);
    try testing.expect(a != 0);
    try testing.expect(a != Cache.key("abd", 0, 14));
    try testing.expect(a != Cache.key("abc", 1, 14));
    try testing.expect(a != Cache.key("abc", 0, 15));
    try testing.expectEqual(a, Cache.key("abc", 0, 14));
    try testing.expect(Cache.key("", 0, 0) != 0);
}

const cache_bytes = blk: {
    var counter: mem.Carver = .{ .buf = null };
    _ = Cache.init(&counter, 16);
    break :blk counter.off;
};
