//! Image tests over the files in testdata/: every colour type and bit depth PNG defines,
//! plain and Adam7, with tRNS, in files compressed by Python's zlib (testdata/make.py). Each
//! `name.png` is checked against `name.rgba`, the premultiplied pixels make.py computed from
//! its source samples, so the decoder is compared with the image's source and not with
//! another decoder. The rest follows an image from file to texture: embedded at comptime,
//! decoded on a background thread, packed into the atlas and given a mip chain.

const std = @import("std");
const png = @import("png.zig");
const embed = @import("embed.zig");
const image_jobs = @import("image_jobs.zig");
const image_atlas = @import("image_atlas.zig");
const mipmaps = @import("image_mipmaps.zig");

const testing = std.testing;

const names = .{ "icon16", "rgba16_adam7", "rgb8", "rgb16_trns", "gray1", "gray2_adam7", "gray4", "gray8_trns", "gray16_adam7", "ga8", "ga16", "pal1", "pal2", "pal4_adam7_trns", "pal8" };

test "every test image decodes to its source pixels" {
    var pixels: [4096]u8 = undefined;
    var scratch: [4096]u8 = undefined;
    inline for (names) |name| {
        const file = @embedFile("testdata/" ++ name ++ ".png");
        const want = @embedFile("testdata/" ++ name ++ ".rgba");
        const i = png.decode(file, &pixels, &scratch) catch |e| {
            std.debug.print("{s}: {s}\n", .{ name, @errorName(e) });
            return e;
        };
        try testing.expectEqual(want.len, i.pixelBytes());
        testing.expectEqualSlices(u8, want, pixels[0..want.len]) catch |e| {
            std.debug.print("{s}: pixels differ\n", .{name});
            return e;
        };
    }
}

test "the test set covers every colour type, depth and interlacing" {
    var seen: [7][17]bool = @splat(@splat(false));
    var interlaced = false;
    var keyed = false;
    inline for (names) |name| {
        const i = try png.info(@embedFile("testdata/" ++ name ++ ".png"));
        seen[@backingInt(i.color)][i.depth] = true;
        interlaced = interlaced or i.interlaced;
        keyed = keyed or (i.trns.len > 0 and i.color != .palette);
    }
    for ([_]u8{ 1, 2, 4, 8, 16 }) |d| try testing.expect(seen[0][d]);
    for ([_]u8{ 1, 2, 4, 8 }) |d| try testing.expect(seen[3][d]);
    for ([_]u8{ 2, 4, 6 }) |c| for ([_]u8{ 8, 16 }) |d| try testing.expect(seen[c][d]);
    try testing.expect(interlaced and keyed);
}

test "embedding at comptime gives the same pixels" {
    const icon = comptime embed.embed(@embedFile("testdata/pal4_adam7_trns.png"));
    try testing.expectEqualSlices(u8, @embedFile("testdata/pal4_adam7_trns.rgba"), icon.pixels);
}

test "from file to texture: background decode, atlas, mipmaps" {
    const gpa = testing.allocator;
    const io = testing.io;
    // Decode three images off this thread.
    const files = [_][]const u8{ @embedFile("testdata/icon16.png"), @embedFile("testdata/ga8.png"), @embedFile("testdata/pal2.png") };
    var jobs: [files.len]image_jobs.Job = undefined;
    var futures: [files.len]std.Io.Future(void) = undefined;
    var wake: std.Io.Event = .unset;
    for (&jobs, files) |*job, f| {
        const i = try png.info(f);
        job.* = .{ .file = f, .pixels = try gpa.alloc(u8, i.pixelBytes()), .scratch = try gpa.alloc(u8, i.scratchBytes()), .wake = &wake };
    }
    defer for (jobs) |job| {
        gpa.free(job.pixels);
        gpa.free(job.scratch);
    };
    for (&futures, &jobs) |*fut, *job| fut.* = image_jobs.start(io, job) catch |e| switch (e) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    for (&jobs, &futures) |*job, *fut| {
        try job.done.wait(io);
        fut.await(io);
    }

    // Pack them into one 64 x 32 atlas; each rectangle holds its image.
    var tex: [64 * 32 * 4]u8 = undefined;
    var sx: [64]u32 = undefined;
    var sy: [64]u32 = undefined;
    var sw: [64]u32 = undefined;
    var atlas: image_atlas.Atlas = .init(64, 32, &tex, .{ .x = &sx, .y = &sy, .w = &sw }, 16);
    for (jobs) |job| {
        const i = try job.result;
        const r = atlas.add(i.w, i.h, job.pixels).?;
        for (0..i.h) |y| try testing.expectEqualSlices(
            u8,
            job.pixels[y * i.w * 4 ..][0 .. i.w * 4],
            tex[((r.y + y) * 64 + r.x) * 4 ..][0 .. i.w * 4],
        );
        const uv = atlas.uv(r);
        try testing.expect(uv[0] < uv[2] and uv[1] < uv[3] and uv[2] <= 1 and uv[3] <= 1);
    }
    try testing.expect(atlas.takeDirty() != null);

    // The icon's mip chain ends in one texel: the average of the image, within rounding.
    const icon = try jobs[0].result;
    var chain: [mipmaps.chainBytes(16, 16)]u8 = undefined;
    @memcpy(chain[0..icon.pixelBytes()], jobs[0].pixels);
    mipmaps.generate(16, 16, &chain);
    const last = chain[mipmaps.offset(16, 16, mipmaps.levels(16, 16) - 1)..][0..4];
    for (0..4) |c| {
        var sum: u32 = 0;
        for (0..256) |p| sum += jobs[0].pixels[p * 4 + c];
        const mean = sum / 256;
        try testing.expect(@abs(@as(i32, last[c]) - @as(i32, @intCast(mean))) <= 2);
    }
}
