//! Fuzzes the font parser: mutated copies of the test fonts driven through every entry point.
//! A font is untrusted input, so any bytes must end in a value or an error, never a crash,
//! an out-of-bounds read or a hang.
//!
//!   zig build font-fuzz -Doptimize=ReleaseSafe -- [seconds] [seed] [first]
//!
//! Iteration `i` draws from a PRNG seeded with `seed + i`, so a crash prints the command that
//! reruns that one iteration. Mutation beats random bytes here: a random file almost never gets
//! past the table directory, a mutated one reaches cmap, glyf, kern and GPOS with bad offsets.
//! Not exported from src/lcgf.zig: it has a `main` and does I/O, which tier 0 may not. Its
//! `exercise` and `mutate` are tier 0, and opentype.zig runs them in `zig build test`.

const std = @import("std");
const opentype = @import("opentype.zig");

const seeds = [_][]const u8{ @embedFile("testdata/test.ttf"), @embedFile("testdata/test.ttc") };
const max_seed = @max(seeds[0].len, seeds[1].len);

/// Offsets and lengths a damaged font tends to carry.
const interesting = [_]u32{ 0, 1, 2, 0x7f, 0x80, 0xff, 0x7fff, 0x8000, 0xffff, 0x1_0000, 0x7fff_ffff, 0xffff_ffff };

/// A copy of one test font with a few random edits: bit flips, random bytes, 16- and 32-bit
/// values written at random offsets, truncation.
pub fn mutate(r: std.Random, buf: *[max_seed]u8) []const u8 {
    const seed = seeds[r.uintLessThan(usize, seeds.len)];
    @memcpy(buf[0..seed.len], seed);
    var n = seed.len;
    for (0..r.intRangeAtMost(u32, 1, 16)) |_| {
        if (n < 4) break;
        const at = r.uintLessThan(usize, n - 3);
        const v: u32 = if (r.boolean()) interesting[r.uintLessThan(usize, interesting.len)] else r.int(u32);
        switch (r.uintLessThan(u8, 5)) {
            0 => buf[at] ^= @as(u8, 1) << r.int(u3),
            1 => buf[at] = @truncate(v),
            2 => std.mem.writeInt(u16, buf[at..][0..2], @truncate(v), .big),
            3 => std.mem.writeInt(u32, buf[at..][0..4], v, .big),
            else => n = r.uintAtMost(usize, n),
        }
    }
    return buf[0..n];
}

var xs: [4096]f32 = undefined;
var ys: [4096]f32 = undefined;
var ons: [4096]bool = undefined;
var ends: [512]u32 = undefined;

/// Every entry point of the parser over `data`. Errors are expected; only crashes count.
pub fn exercise(data: []const u8) void {
    const count = opentype.faceCount(data) catch return;
    for (0..@min(count, 4)) |i| {
        const offset = opentype.faceOffset(data, @intCast(i)) catch continue;
        const face = opentype.Face.parse(data, offset) catch continue;
        for (0..0x300) |cp| _ = face.cmap.glyph(@intCast(cp));
        for ([_]u32{ 0xfffd, 0xffff, 0x1_0000, 0x1f600, 0x10_ffff, 0xffff_ffff }) |cp| _ = face.cmap.glyph(cp);
        const glyphs = @min(@as(u32, face.glyph_count) + 2, 64);
        for (0..glyphs) |g| {
            const glyph: opentype.Glyph = @intCast(g);
            _ = face.hMetrics(glyph);
            var out: opentype.Outline = .{ .x = &xs, .y = &ys, .on = &ons, .ends = &ends };
            if (face.outline(glyph, &out)) {
                std.debug.assert(out.points <= xs.len and out.contours <= ends.len);
                for (ends[0..out.contours]) |e| std.debug.assert(e < out.points);
            } else |_| {
                std.debug.assert(out.points == 0 and out.contours == 0);
            }
            for (0..@min(glyphs, 16)) |right| _ = face.kerning(glyph, @intCast(right));
        }
        var out: opentype.Outline = .{ .x = &xs, .y = &ys, .on = &ons, .ends = &ends };
        face.outline(0xffff, &out) catch {};
        _ = face.kerning(0xffff, 0xffff);
    }
    _ = opentype.findFace(data, .{ .bold = true }) catch {};
}

var current: struct { seed: u64 = 0, iteration: u64 = 0 } = .{};

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    std.debug.print("font-fuzz: crash at seed {d} iteration {d}; reproduce with: zig build font-fuzz -- 0 {d} {d}\n", .{
        current.seed, current.iteration, current.seed, current.iteration,
    });
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const seconds = try std.fmt.parseInt(u64, args.next() orelse "60", 10);
    current.seed = try std.fmt.parseInt(u64, args.next() orelse "1", 10);
    current.iteration = try std.fmt.parseInt(u64, args.next() orelse "0", 10);

    var buf: [max_seed]u8 = undefined;
    const t0 = std.Io.Timestamp.now(io, .awake);
    var runs: u64 = 0;
    var ns: u64 = 0;
    while (runs == 0 or ns < seconds * std.time.ns_per_s) : (current.iteration += 1) {
        var prng: std.Random.DefaultPrng = .init(current.seed +% current.iteration);
        exercise(mutate(prng.random(), &buf));
        runs += 1;
        ns = @intCast(t0.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds());
    }

    var out_buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    try out.interface.print("font-fuzz: {d} iterations in {d} s, seed {d}, no crash\n", .{ runs, ns / std.time.ns_per_s, current.seed });
    try out.interface.flush();
}
