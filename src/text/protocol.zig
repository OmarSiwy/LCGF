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
const draw_list = @import("../draw/draw_list.zig");
const DrawList = draw_list.DrawList;
const Quad = draw_list.Quad;

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

    /// SIMD. Re-flows runs flagged `wrap` into `avail` and rewrites their `w`, `h`. Runs after
    /// `measure` and `layout.textAvail`. A run that does not wrap keeps its measured `w` and `h`,
    /// so a font that serves only non-wrapping runs needs to run after `Mono` at measure only.
    pub fn wrap(font: Mono, tx: *Texts) void {
        const c = &tx.c;
        const n = simd.padded(tx.len);
        // Labels and controls commonly have no wrapping runs. One narrow-column
        // scan avoids divisions, rounding and writes across all the metric columns.
        // Read the padded rows as the pass below does: a stale wrapping flag there
        // can only disable this shortcut, never skip a live wrapping run.
        var any_wrap: simd.B = @splat(false);
        var at: usize = 0;
        while (at < n) : (at += W) any_wrap |= simd.loadF(c.wrap, at) > simd.f(0);
        if (!@reduce(.Or, any_wrap)) return;

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
            simd.storeF(c.h, i, @select(f32, wraps, lines * px * simd.f(font.line), simd.loadF(c.h, i)));
        }
    }

    /// Where glyph quads for run k landed in the output of `quads`.
    pub const Glyphs = struct { first: []u32, count: []u32 };

    /// Expands the draw list's text runs into glyph quads for a 16x16 byte-indexed atlas: byte b
    /// samples cell (b & 15, b >> 4). Bytes flow left to right and wrap at the run's width, the
    /// same way `wrap` counted lines. `glyphs` (at least `d.run_len` long) gets each run's slice
    /// of `out`. Returns the number of quads written; stops quietly when `out` is full (the last
    /// row is then overwritten in place, never past the end).
    pub fn quads(font: Mono, d: *const DrawList, out: []Quad, glyphs: Glyphs) u32 {
        return font.quadsFor(FullGrid, d, out, glyphs) catch unreachable;
    }

    /// The same metrics and geometry, with UVs from a static atlas subset.
    pub fn quadsFor(font: Mono, comptime Grid: type, d: *const DrawList, out: []Quad, glyphs: Glyphs) error{GlyphOutsideSubset}!u32 {
        std.debug.assert(out.len >= 1);
        var n: u32 = 0;
        for (0..d.run_len) |k| n = try font.appendRun(Grid, d, @intCast(k), out, glyphs, n);
        return n;
    }

    /// Expands only runs referenced by text commands. Run indices stay unchanged; a
    /// non-submitted run gets an empty span. Repeated commands share one expansion.
    /// The host still draws every submitted command in its original paint order.
    /// This avoids constructing geometry for offscreen runs retained in the side list.
    pub fn quadsForCommands(font: Mono, comptime Grid: type, d: *const DrawList, out: []Quad, glyphs: Glyphs) error{GlyphOutsideSubset}!u32 {
        std.debug.assert(out.len >= 1);
        std.debug.assert(glyphs.first.len >= d.run_len and glyphs.count.len >= d.run_len);
        @memset(glyphs.first[0..d.run_len], 0);
        @memset(glyphs.count[0..d.run_len], 0);
        var n: u32 = 0;
        for (0..d.cmd_len) |i| {
            if (d.cmd.kind[i] != @backingInt(DrawList.Kind.text)) continue;
            const k = d.cmd.first[i];
            // Empty/truncated repeated runs can be revisited, but emit no live quads.
            if (glyphs.count[k] != 0) continue;
            n = try font.appendRun(Grid, d, k, out, glyphs, n);
        }
        return n;
    }

    fn appendRun(font: Mono, comptime Grid: type, d: *const DrawList, k: u32, out: []Quad, glyphs: Glyphs, start: u32) error{GlyphOutsideSubset}!u32 {
        const r = d.runs[k];
        const adv = @max(r.px * font.advance, 1e-6);
        const line = r.px * font.line;
        const per_line: u32 = @intFromFloat(@min(@max(@floor((r.rect[2] - r.rect[0]) / adv + 0.5), 1), 1e6));
        const last: u32 = @intCast(out.len - 1);
        var n = start;
        glyphs.first[k] = n;
        for (d.strings[r.start..][0..r.bytes], 0..) |byte, j| {
            const col: f32 = @floatFromInt(j % per_line);
            const row: f32 = @floatFromInt(j / per_line);
            const x = r.rect[0] + col * adv;
            const y = r.rect[1] + row * line;
            out[n] = .{
                .rect = .{ x, y, x + adv, y + line },
                .clip = r.clip,
                .params = .{ 0, 0, 0, 0 },
                .uv = try Grid.uv(byte),
                .fill = r.color,
                .border_color = 0,
                .radii = @splat(0),
                .border = 0,
                .opacity = 1, // the run's colour already carries its opacity
            };
            // Write always, advance until the last row.
            n = @min(n + 1, last);
        }
        glyphs.count[k] = n - start;
        return n;
    }
};

fn cellUv(index: u8, comptime columns: usize, comptime rows: usize) [4]f32 {
    const x: f32 = @floatFromInt(@as(usize, index) % columns);
    const y: f32 = @floatFromInt(@as(usize, index) / columns);
    const w: f32 = @floatFromInt(columns);
    const h: f32 = @floatFromInt(rows);
    return .{ x / w, y / h, (x + 1) / w, (y + 1) / h };
}

const FullGrid = struct {
    fn uv(byte: u8) error{}![4]f32 {
        return cellUv(byte, 16, 16);
    }
};

/// Pack only the byte cells referenced by a static vocabulary, using the same pixels and
/// glyph metrics as Mono's 16x16 atlas. Pass the resulting type to Mono.quadsFor.
pub fn StaticAtlas(comptime strings: []const []const u8) type {
    const table: struct { map: [256]u8, count: usize } = comptime blk: {
        var map: [256]u8 = @splat(255);
        var seen: std.bit_set.Static(256) = .empty;
        var n: usize = 0;
        var quota: usize = 10000;
        for (strings) |str| {
            quota += 20 * (str.len + 1);
            @setEvalBranchQuota(quota);
            for (str) |byte| {
                if (seen.isSet(byte)) continue;
                seen.set(byte);
                map[byte] = @intCast(n);
                n += 1;
            }
        }
        break :blk .{ .map = map, .count = n };
    };
    return struct {
        const lookup = table.map;
        pub const count = table.count;
        pub const columns = @min(count, 16);
        pub const rows = (count + 15) / 16;

        pub fn uv(byte: u8) error{GlyphOutsideSubset}![4]f32 {
            if (count == 0) return error.GlyphOutsideSubset;
            const index = lookup[byte];
            if (count < 256 and index == 255) return error.GlyphOutsideSubset;
            return cellUv(index, columns, rows);
        }

        /// Copy each referenced cell's scanlines from the full source atlas at compile time.
        /// The caller embeds the returned pixels directly. Unoccupied trailing cells are zero.
        pub fn pixels(comptime Pixel: type, comptime cell: [2]usize, comptime full: []const Pixel) [columns * rows * cell[0] * cell[1]]Pixel {
            return comptime blk: {
                if (cell[0] == 0 or cell[1] == 0 or full.len != 256 * cell[0] * cell[1])
                    @compileError("expected a 16x16 atlas of equally sized nonempty glyph cells");
                const len = columns * rows * cell[0] * cell[1];
                @setEvalBranchQuota(4000 + 20 * len);
                var out: [len]Pixel = @splat(0);
                if (count > 0) for (table.map, 0..) |slot, byte| {
                    if (count < 256 and slot == 255) continue;
                    for (0..cell[1]) |line| {
                        const src = ((byte / 16 * cell[1] + line) * 16 + byte % 16) * cell[0];
                        const dst = ((@as(usize, slot) / columns * cell[1] + line) * columns + @as(usize, slot) % columns) * cell[0];
                        @memcpy(out[dst..][0..cell[0]], full[src..][0..cell[0]]);
                    }
                };
                break :blk out;
            };
        }
    };
}

/// Remembers measured extents across frames, keyed by a hash of the run's bytes, its font and
/// its size, so an expensive shaper measures only text it has not seen. Font-agnostic: it sits
/// on the measure step of the protocol, around whatever fills `w` and `h`.
///
/// Per frame: `lookup` fills `w`, `h` of every hit and lists the misses; the caller measures the
/// misses; `store` records them. Direct-mapped, one entry per slot: a new key evicts the old one.
/// Tier 0: the table is carved from the caller's buffer and never grows.
pub const Cache = struct {
    /// Slots - 1. Index from bit 1 because generated keys reserve bit 0 for the empty marker.
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
            const slot: usize = @intCast((want >> 1) & cache.mask); // mask < slot count, so it fits a 32-bit usize
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
            const slot: usize = @intCast((want >> 1) & cache.mask); // mask < slot count, so it fits a 32-bit usize
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

test "Mono.wrap: a run that does not wrap keeps the extent another font measured" {
    var fx: Fixture(4) = .{};
    var tx = fx.texts();
    _ = tx.push(0, .{ .bytes = 4 }, &.{ .px = 20, .font = @fromBackingInt(1) });
    _ = tx.push(0, .{ .bytes = 24 }, &.{ .px = 10, .wrap = true });
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    font.measure(&tx);
    // A second font measures run 0 after Mono: four 20 px squares.
    tx.c.w[0] = 80;
    tx.c.h[0] = 20;
    tx.c.avail[0] = 100;
    tx.c.avail[1] = 100;
    font.wrap(&tx);
    try testing.expectEqual(80, tx.c.w[0]);
    try testing.expectEqual(20, tx.c.h[0]);
    try testing.expectEqual(100, tx.c.w[1]);
    try testing.expectEqual(24, tx.c.h[1]);
}

test "Mono.wrap: no wrapping flags preserve foreign metrics and a later final run still wraps" {
    const runs = 2 * W + 1;
    var fx: Fixture(runs) = .{};
    var tx = fx.texts();
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    for (0..runs) |k| {
        _ = tx.push(0, .{ .bytes = 24 }, &.{ .px = 10 });
        tx.c.w[k] = @floatFromInt(k + 80);
        tx.c.h[k] = @floatFromInt(k + 20);
        tx.c.avail[k] = 100;
    }
    // Non-positive and unordered flags all mean "keep the extent" under the
    // protocol's > 0 predicate. Do not reinterpret them as a truthy bit pattern.
    tx.c.wrap[0] = -1;
    tx.c.wrap[1] = std.math.nan(f32);
    tx.c.w[0] = -0.0;
    tx.c.h[0] = std.math.inf(f32);
    font.wrap(&tx);
    try testing.expectEqual(@as(u32, 0x8000_0000), @as(u32, @bitCast(tx.c.w[0])));
    try testing.expectEqual(std.math.inf(f32), tx.c.h[0]);
    for (1..runs) |k| {
        try testing.expectEqual(@as(f32, @floatFromInt(k + 80)), tx.c.w[k]);
        try testing.expectEqual(@as(f32, @floatFromInt(k + 20)), tx.c.h[k]);
    }

    // No cached summary: a direct column write between calls must be observed,
    // including the single valid lane of a trailing partial vector.
    tx.c.wrap[runs - 1] = 1;
    tx.c.w[runs - 1] = 120;
    tx.c.h[runs - 1] = 12;
    font.wrap(&tx);
    try testing.expectEqual(@as(f32, 100), tx.c.w[runs - 1]);
    try testing.expectEqual(@as(f32, 24), tx.c.h[runs - 1]);
    for (1..runs - 1) |k| {
        try testing.expectEqual(@as(f32, @floatFromInt(k + 80)), tx.c.w[k]);
        try testing.expectEqual(@as(f32, @floatFromInt(k + 20)), tx.c.h[k]);
    }
}

test "Mono.wrap: stale padding after a shorter frame cannot change live nonwrapping extents" {
    var fx: Fixture(2 * W) = .{};
    var tx = fx.texts();
    const font: Mono = .{};
    for (0..2 * W) |_| _ = tx.push(0, .{ .bytes = 24 }, &.{ .wrap = true });
    font.measure(&tx);
    tx.reset();
    _ = tx.push(0, .{ .bytes = 4 }, &.{});
    tx.c.w[0] = 81;
    tx.c.h[0] = 21;
    tx.c.avail[0] = 30;
    font.wrap(&tx);
    try testing.expectEqual(@as(f32, 81), tx.c.w[0]);
    try testing.expectEqual(@as(f32, 21), tx.c.h[0]);
    tx.reset();
    font.wrap(&tx); // An empty list has no columns to read, including stale padding.
    try testing.expectEqual(@as(f32, 81), tx.c.w[0]);
    try testing.expectEqual(@as(f32, 21), tx.c.h[0]);
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

test "Cache: both slots hold measured extents and a collision replaces only one" {
    var fx: Fixture(3) = .{};
    var tx = fx.texts();
    var buf: [32]u8 = undefined;
    var strings: Strings = .{ .buf = &buf };
    for ([_][]const u8{ "Type", "AVTa", "hello" }, 0..) |s, i|
        _ = tx.push(@intCast(i), strings.add(s), &.{ .px = 10 });
    var cache_buf: [cache_bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &cache_buf };
    var cache = Cache.init(&carver, 2);
    var misses: [3]u32 = undefined;
    tx.c.w[0..3].* = .{ 15, 19, 25 };
    tx.c.h[0..3].* = .{ 10, 11, 12 };
    cache.store(&tx, &strings, &.{ 0, 1 });
    @memset(tx.c.w[0..2], 0);
    @memset(tx.c.h[0..2], 0);
    try testing.expectEqual(1, cache.lookup(&tx, &strings, &misses));
    try testing.expectEqual(2, misses[0]);
    try testing.expectEqualSlices(f32, &.{ 15, 19 }, tx.c.w[0..2]);
    try testing.expectEqualSlices(f32, &.{ 10, 11 }, tx.c.h[0..2]);

    // "hello" maps to the same slot as "Type".
    cache.store(&tx, &strings, misses[0..1]);
    try testing.expectEqual(1, cache.lookup(&tx, &strings, &misses));
    try testing.expectEqual(0, misses[0]);
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

fn testList(runs: []draw_list.TextRun, strings: []const u8) DrawList {
    return .{
        .quads = &.{},
        .runs = runs,
        .run_len = @intCast(runs.len),
        .customs = &.{},
        .strings = strings,
        .cmd = .{ .kind = &.{}, .first = &.{}, .count = &.{}, .key = &.{} },
        .op = .{ .kind = &.{}, .key = &.{}, .ref = &.{} },
    };
}

test "Mono.quads: one quad per byte, wrapped at the run width, uv from the byte's atlas cell" {
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    // Advance 5 px; run 0 is 10 px wide (2 glyphs per line), run 1 is wide enough for one line.
    var runs = [_]draw_list.TextRun{
        .{ .rect = .{ 100, 50, 110, 80 }, .clip = .{ 0, 0, 800, 600 }, .start = 0, .bytes = 3, .px = 10, .color = 0xff00ff00, .font = 0 },
        .{ .rect = .{ 0, 0, 100, 12 }, .clip = .{ 1, 2, 3, 4 }, .start = 3, .bytes = 2, .px = 10, .color = 0xffffffff, .font = 0 },
    };
    var d = testList(&runs, "AB\x00\xff!");
    var out: [8]Quad = undefined;
    var first: [2]u32 = undefined;
    var count: [2]u32 = undefined;
    const n = font.quads(&d, &out, .{ .first = &first, .count = &count });
    try testing.expectEqual(5, n);
    try testing.expectEqualSlices(u32, &.{ 0, 3 }, &first);
    try testing.expectEqualSlices(u32, &.{ 3, 2 }, &count);
    // "AB" on line 0, NUL wraps to line 1.
    try testing.expectEqual([4]f32{ 100, 50, 105, 62 }, out[0].rect);
    try testing.expectEqual([4]f32{ 105, 50, 110, 62 }, out[1].rect);
    try testing.expectEqual([4]f32{ 100, 62, 105, 74 }, out[2].rect);
    // 'A' = 0x41: column 1, row 4.
    try testing.expectEqual([4]f32{ 1.0 / 16.0, 4.0 / 16.0, 2.0 / 16.0, 5.0 / 16.0 }, out[0].uv);
    try testing.expectEqual([4]f32{ 0, 0, 1.0 / 16.0, 1.0 / 16.0 }, out[2].uv);
    try testing.expectEqual([4]f32{ 15.0 / 16.0, 15.0 / 16.0, 1, 1 }, out[3].uv);
    try testing.expectEqual([4]f32{ 5, 0, 10, 12 }, out[4].rect);
    for (out[0..3]) |q| {
        try testing.expectEqual(0xff00ff00, q.fill);
        try testing.expectEqual([4]f32{ 0, 0, 800, 600 }, q.clip);
        try testing.expectEqual(0, q.border_color);
    }
    try testing.expectEqual([4]f32{ 1, 2, 3, 4 }, out[4].clip);
}

test "Mono.quads: a full output stops at its last row, a zero-width run gets one glyph per line" {
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    var runs = [_]draw_list.TextRun{
        .{ .rect = .{ 0, 0, 0, 0 }, .clip = .{ 0, 0, 1, 1 }, .start = 0, .bytes = 5, .px = 10, .color = 1, .font = 0 },
    };
    var d = testList(&runs, "hello");
    var out: [3]Quad = undefined;
    var first: [1]u32 = undefined;
    var count: [1]u32 = undefined;
    const n = font.quads(&d, &out, .{ .first = &first, .count = &count });
    try testing.expectEqual(2, n);
    try testing.expectEqual(2, count[0]);
    // Rows 0 and 1 hold 'h' and 'e'; the last row was overwritten until 'o', on line 4.
    try testing.expectEqual([4]f32{ 0, 12, 5, 24 }, out[1].rect);
    try testing.expectEqual([4]f32{ 0, 48, 5, 60 }, out[2].rect);
}

const cache_bytes = blk: {
    var counter: mem.Carver = .{ .buf = null };
    _ = Cache.init(&counter, 16);
    break :blk counter.off;
};

test "StaticAtlas: subset pixels and glyph UVs select the same cells as the full atlas" {
    const Subset = StaticAtlas(&.{ "ABA", "ZA", "\xff" });
    const full = comptime blk: {
        var out: [256 * 4]u16 = undefined;
        for (&out, 0..) |*px, i| px.* = @intCast(i);
        break :blk out;
    };
    const packed_pixels = Subset.pixels(u16, .{ 2, 2 }, &full);
    try testing.expectEqual(4, Subset.count);
    try testing.expectEqual(16, packed_pixels.len);
    var run = [_]draw_list.TextRun{.{ .rect = .{ 0, 0, 40, 12 }, .clip = .{ 0, 0, 40, 12 }, .start = 0, .bytes = 4, .px = 10, .color = 0xffffffff, .font = 0 }};
    var d = testList(&run, "BZA\xff");
    var out: [5]Quad = undefined;
    var first: [1]u32 = undefined;
    var count: [1]u32 = undefined;
    try testing.expectEqual(4, try (Mono{}).quadsFor(Subset, &d, &out, .{ .first = &first, .count = &count }));
    for (d.strings, out[0..4]) |byte, q| {
        const dst: usize = @intFromFloat(q.uv[0] * 8);
        const src = (@as(usize, byte / 16) * 32 + byte % 16) * 2;
        for (0..2) |line|
            try testing.expectEqualSlices(u16, full[src + line * 32 ..][0..2], packed_pixels[dst + line * 8 ..][0..2]);
    }
    d.strings = "XXXX";
    try testing.expectError(error.GlyphOutsideSubset, (Mono{}).quadsFor(Subset, &d, &out, .{ .first = &first, .count = &count }));
    try testing.expectError(error.GlyphOutsideSubset, StaticAtlas(&.{}).uv('a'));
}

test "Mono command expansion skips unsubmitted runs and shares repeated text commands" {
    const Subset = StaticAtlas(&.{"ABC"});
    const r: draw_list.TextRun = .{ .rect = .{ 1.25, 2, 80, 24 }, .clip = .{ 0, 0, 80, 32 }, .start = 0, .bytes = 2, .px = 11, .color = 0x9f234567, .font = 0 };
    var runs = [_]draw_list.TextRun{ r, r, r };
    runs[1].start = 2;
    runs[1].bytes = 3;
    runs[2].start = 5;
    runs[2].bytes = 1;
    var d = testList(&runs, "ABXXXC");
    var kinds = [_]u8{ @backingInt(DrawList.Kind.text), @backingInt(DrawList.Kind.quads), @backingInt(DrawList.Kind.text), @backingInt(DrawList.Kind.text) };
    var refs = [_]u32{ 2, 0, 0, 2 };
    var counts = [_]u32{ 1, 0, 1, 1 };
    var keys = [_]u32{ 0, 0, 0, 0 };
    d.cmd = .{ .kind = &kinds, .first = &refs, .count = &counts, .key = &keys };
    d.cmd_len = kinds.len;
    var visible: [7]Quad = undefined;
    var all: [7]Quad = undefined;
    var first: [3]u32 = undefined;
    var count: [3]u32 = undefined;
    var all_first: [3]u32 = undefined;
    var all_count: [3]u32 = undefined;
    const mono: Mono = .{};
    try testing.expectEqual(3, try mono.quadsForCommands(Subset, &d, &visible, .{ .first = &first, .count = &count }));
    try testing.expectEqualSlices(u32, &.{ 2, 0, 1 }, &count);
    try testing.expectEqual(0, first[1]);
    try testing.expectError(error.GlyphOutsideSubset, mono.quadsFor(Subset, &d, &all, .{ .first = &all_first, .count = &all_count }));
    d.strings = "ABABCC";
    _ = try mono.quadsFor(Subset, &d, &all, .{ .first = &all_first, .count = &all_count });
    for ([_]u32{ 0, 2 }) |k| {
        const actual = visible[first[k]..][0..count[k]];
        const expected = all[all_first[k]..][0..all_count[k]];
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected), std.mem.sliceAsBytes(actual));
    }
    d.cmd_len = 0;
    try testing.expectEqual(0, try mono.quadsForCommands(Subset, &d, &visible, .{ .first = &first, .count = &count }));
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, &count);
}
