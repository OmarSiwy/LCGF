//! Fuzzes the PNG decoder: mutated copies of the test images through `info`, `decode` and the
//! mipmap generator. A file is untrusted input, so any bytes must end in an image or an error,
//! never a crash, an out-of-bounds access or a hang.
//!
//!   zig build png-fuzz -Doptimize=ReleaseSafe -- [seconds] [seed] [first]
//!
//! Iteration `i` draws from a PRNG seeded with `seed + i`, so a crash prints the command that
//! reruns that one iteration. Mutations land past the signature, and most of the time every
//! chunk CRC is recomputed afterwards: random edits almost always break a CRC, and a decoder
//! that stops at the CRC check never gets its inflate, filters or bit unpacking exercised.
//! Not exported from src/lcgf.zig: it has a `main` and does I/O. Its `exercise` and `mutate`
//! do neither, and png.zig runs them in `zig build test`.

const std = @import("std");
const png = @import("png.zig");
const mipmaps = @import("image_mipmaps.zig");

const seeds = blk: {
    const names = .{ "icon16", "rgba16_adam7", "rgb8", "rgb16_trns", "gray1", "gray2_adam7", "gray4", "gray8_trns", "gray16_adam7", "ga8", "ga16", "pal1", "pal2", "pal4_adam7_trns", "pal8" };
    var files: [names.len][]const u8 = undefined;
    for (names, 0..) |n, k| files[k] = @embedFile("testdata/" ++ n ++ ".png");
    break :blk files;
};
pub const max_seed = blk: {
    var m: usize = 0;
    for (seeds) |s| m = @max(m, s.len);
    break :blk m;
};

/// Values a damaged header or chunk length tends to carry.
const interesting = [_]u32{ 0, 1, 2, 3, 4, 6, 7, 8, 13, 16, 0xff, 0x100, 0x4000, 0x4001, 0xffff, 0x7fff_ffff, 0x8000_0000, 0xffff_ffff };

/// A copy of one test image with a few random edits: bit flips, random bytes, small
/// increments, 32-bit values (lengths, sizes), truncation. CRCs are recomputed 7 times in 8.
pub fn mutate(r: std.Random, buf: *[max_seed]u8) []u8 {
    const seed = seeds[r.uintLessThan(usize, seeds.len)];
    @memcpy(buf[0..seed.len], seed);
    var n = seed.len;
    for (0..r.intRangeAtMost(u32, 1, 4)) |_| {
        if (n < 13) break;
        // Past the signature: a broken signature only tests one compare.
        const at = 8 + r.uintLessThan(usize, n - 12);
        switch (r.uintLessThan(u8, 8)) {
            0 => buf[at] ^= @as(u8, 1) << r.int(u3),
            1, 2 => buf[at] = r.int(u8),
            3, 4 => buf[at] +%= 1,
            5 => std.mem.writeInt(u32, buf[at..][0..4], interesting[r.uintLessThan(usize, interesting.len)], .big),
            6 => buf[at] -%= 1,
            else => n = r.intRangeAtMost(usize, 9, n),
        }
    }
    if (r.uintLessThan(u8, 8) != 0) png.fixCrcs(buf[0..n]);
    return buf[0..n];
}

var pixels: [1 << 16]u8 = undefined;
var scratch: [1 << 16]u8 = undefined;
var chain: [1 << 17]u8 = undefined;

/// Every entry point over `data`. Errors are expected; only crashes count. Returns whether
/// the image decoded.
pub fn exercise(data: []const u8) bool {
    const i = png.info(data) catch return false;
    std.debug.assert(i.w > 0 and i.h > 0 and i.w <= png.max_side and i.h <= png.max_side);
    // A header may claim up to max_side squared; only small claims are decoded here.
    if (i.pixelBytes() > pixels.len or i.scratchBytes() > scratch.len) return false;
    const got = png.decode(data, &pixels, &scratch) catch return false;
    std.debug.assert(got.w == i.w and got.h == i.h);
    // Premultiplied: no channel exceeds alpha.
    var k: usize = 0;
    while (k < i.pixelBytes()) : (k += 4)
        std.debug.assert(pixels[k] <= pixels[k + 3] and pixels[k + 1] <= pixels[k + 3] and pixels[k + 2] <= pixels[k + 3]);
    if (mipmaps.chainBytes(i.w, i.h) <= chain.len) {
        @memcpy(chain[0..i.pixelBytes()], pixels[0..i.pixelBytes()]);
        mipmaps.generate(i.w, i.h, &chain);
    }
    return true;
}

var current: struct { seed: u64 = 0, iteration: u64 = 0 } = .{};

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    std.debug.print("png-fuzz: crash at seed {d} iteration {d}; reproduce with: zig build png-fuzz -- 0 {d} {d}\n", .{
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
    var decoded: u64 = 0;
    var ns: u64 = 0;
    while (runs == 0 or ns < seconds * std.time.ns_per_s) : (current.iteration += 1) {
        var prng: std.Random.DefaultPrng = .init(current.seed +% current.iteration);
        decoded += @intFromBool(exercise(mutate(prng.random(), &buf)));
        runs += 1;
        ns = @intCast(t0.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds());
    }

    var out_buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    try out.interface.print("png-fuzz: {d} iterations in {d} s ({d} decoded), seed {d}, no crash\n", .{ runs, ns / std.time.ns_per_s, decoded, current.seed });
    try out.interface.flush();
}
