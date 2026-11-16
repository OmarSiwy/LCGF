//! Mipmap chains for images a back end samples with a mipmapped sampler (trilinear filtering of
//! an image drawn smaller than its size). Generated on the CPU, because the GPU APIs differ:
//! wgpu and Vulkan have no one-call mipmap generation, GL ES does, the software renderer
//! samples level 0 only. A back end that samples mips asks for the chain and uploads each
//! level; one that does not skips this and keeps the 4/3 memory.
//!
//! Each level halves the one above (rounding down, at least 1), and each texel is the 2 x 2
//! box average of the texels above it, on premultiplied RGBA8 (png.zig's output), which is
//! what keeps transparent texels from darkening their neighbours. An odd last column or row
//! is dropped from the average, as GPU box filters do. Levels are stored one after another.

const std = @import("std");

/// Number of levels down to 1 x 1, level 0 included.
pub fn levels(w: u32, h: u32) u32 {
    std.debug.assert(w > 0 and h > 0);
    return @as(u32, 32) - @clz(@max(w, h));
}

/// Width and height of level `l`.
pub fn size(w: u32, h: u32, l: u32) [2]u32 {
    return .{ @max(1, w >> @intCast(l)), @max(1, h >> @intCast(l)) };
}

/// Byte offset of level `l` in a chain.
pub fn offset(w: u32, h: u32, l: u32) usize {
    var at: usize = 0;
    for (0..l) |k| {
        const s = size(w, h, @intCast(k));
        at += @as(usize, s[0]) * s[1] * 4;
    }
    return at;
}

/// Bytes of the whole chain: about 4/3 of level 0.
pub fn chainBytes(w: u32, h: u32) usize {
    return offset(w, h, levels(w, h));
}

/// Fills levels 1 and down of `chain` (`chainBytes(w, h)`), whose first `w * h * 4` bytes
/// hold level 0.
pub fn generate(w: u32, h: u32, chain: []u8) void {
    std.debug.assert(chain.len >= chainBytes(w, h));
    const V = @Vector(4, u16);
    for (1..levels(w, h)) |l| {
        const above = size(w, h, @intCast(l - 1));
        const here = size(w, h, @intCast(l));
        const src = chain[offset(w, h, @intCast(l - 1))..];
        const dst = chain[offset(w, h, @intCast(l))..];
        // A side of 1 above stays 1: both taps read the same texel.
        const dx: usize = @intFromBool(above[0] > 1);
        const dy: usize = @intFromBool(above[1] > 1);
        for (0..here[1]) |y| for (0..here[0]) |x| {
            const r0 = (y * (1 + dy)) * above[0];
            const r1 = r0 + dy * above[0];
            const c0 = x * (1 + dx);
            const c1 = c0 + dx;
            const t: [4]V = .{
                src[(r0 + c0) * 4 ..][0..4].*,
                src[(r0 + c1) * 4 ..][0..4].*,
                src[(r1 + c0) * 4 ..][0..4].*,
                src[(r1 + c1) * 4 ..][0..4].*,
            };
            const avg = (t[0] + t[1] + t[2] + t[3] + @as(V, @splat(2))) >> @splat(2);
            dst[(y * here[0] + x) * 4 ..][0..4].* = @as(@Vector(4, u8), @intCast(avg));
        };
    }
}

const testing = std.testing;

test "level sizes and offsets" {
    try testing.expectEqual(1, levels(1, 1));
    try testing.expectEqual(5, levels(16, 3));
    try testing.expectEqual([2]u32{ 4, 1 }, size(16, 3, 2));
    try testing.expectEqual([2]u32{ 1, 1 }, size(16, 3, 4));
    // 16x3 + 8x1 + 4x1 + 2x1 + 1x1 texels.
    try testing.expectEqual((48 + 8 + 4 + 2 + 1) * 4, chainBytes(16, 3));
    try testing.expectEqual(48 * 4, offset(16, 3, 1));
}

test "box average of premultiplied texels, odd sizes" {
    // 3 x 2: the odd column is dropped from level 1 (1 x 1).
    var chain: [chainBytes(3, 2)]u8 = undefined;
    const l0 = [6][4]u8{ .{ 100, 0, 0, 100 }, .{ 0, 0, 0, 0 }, .{ 9, 9, 9, 9 }, .{ 100, 0, 0, 100 }, .{ 0, 0, 0, 0 }, .{ 9, 9, 9, 9 } };
    @memcpy(chain[0..24], std.mem.asBytes(&l0));
    generate(3, 2, &chain);
    // Two opaque-red texels and two clear ones: half-transparent red, not dark red.
    try testing.expectEqualSlices(u8, &.{ 50, 0, 0, 50 }, chain[24..28]);

    // A 1-wide column halves only vertically.
    var col: [chainBytes(1, 4)]u8 = undefined;
    @memcpy(col[0..16], &[_]u8{ 0, 0, 0, 0, 4, 4, 4, 4, 8, 8, 8, 8, 255, 255, 255, 255 });
    generate(1, 4, &col);
    try testing.expectEqualSlices(u8, &.{ 2, 2, 2, 2, 132, 132, 132, 132, 67, 67, 67, 67 }, col[16..28]);
}
