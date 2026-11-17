//! A fixed-cell bitmap font for the byte-indexed Mono text path. Only the
//! requested glyphs and the fallback (the first source glyph) live in flash.
const std = @import("std");
const sw = @import("../render/sw/sw.zig");
const draw_list = @import("../draw/draw_list.zig");
const Mono = @import("../text/protocol.zig").Mono;

pub fn Subset(comptime width: u8, comptime height: u8, comptime alphabet: []const u8, comptime rows: []const [height]u8, comptime keep: []const u8) type {
    comptime std.debug.assert(width > 0 and width <= 8 and height > 0 and alphabet.len > 0 and rows.len == alphabet.len);
    const codes = comptime blk: {
        var out: []const u8 = alphabet[0..1];
        for (keep) |ch| {
            if (std.mem.indexOfScalar(u8, alphabet, ch) == null) @compileError("missing glyph in requested font subset");
            if (std.mem.indexOfScalar(u8, out, ch) == null) out = out ++ .{ch};
        }
        break :blk out;
    };
    return struct {
        pub const cell_width = width;
        pub const cell_height = height;
        pub const glyphs = codes;
        pub const bitmap: [codes.len][height]u8 = blk: {
            var data: [codes.len][height]u8 = undefined;
            for (codes, 0..) |ch, i| data[i] = rows[std.mem.indexOfScalar(u8, alphabet, ch).?];
            break :blk data;
        };
        pub const Pixels = [codes.len * width * height]u32;

        pub fn index(ch: u8) usize {
            return std.mem.indexOfScalar(u8, codes, ch) orelse 0;
        }

        /// Expand the selected bitmaps once, into the software renderer's texture format.
        pub fn image(pixels: *Pixels) sw.Image {
            for (bitmap, 0..) |glyph, g| for (glyph, 0..) |row, y| {
                for (0..width) |x| {
                    const bit = (row >> @intCast(width - 1 - x)) & 1;
                    pixels[y * codes.len * width + g * width + x] = 0 -% @as(u32, bit);
                }
            };
            return .{ .pixels = pixels, .width = codes.len * width, .height = height };
        }

        /// Give Mono's positioned quads their cells in the tightly packed atlas.
        pub fn remap(draw: *const draw_list.DrawList, quads: []draw_list.Quad, spans: Mono.Glyphs) void {
            const unit = 1.0 / @as(f32, @floatFromInt(codes.len));
            for (draw.runs[0..draw.run_len], 0..) |run, k| {
                const span = quads[spans.first[k]..][0..spans.count[k]];
                for (span, draw.strings[run.start..][0..span.len]) |*q, ch| {
                    const cell: f32 = @floatFromInt(index(ch));
                    q.uv = .{ cell * unit, 0, (cell + 1) * unit, 1 };
                }
            }
        }
    };
}

test "embedded font keeps only requested unique bitmaps and expands the correct cells" {
    const Small = Subset(2, 2, "?AB", &.{ .{ 3, 1 }, .{ 2, 3 }, .{ 1, 2 } }, "BB");
    try std.testing.expectEqualStrings("?B", Small.glyphs);
    try std.testing.expectEqual(4, @sizeOf(@TypeOf(Small.bitmap)));
    try std.testing.expectEqual(Small.index('?'), Small.index('A'));
    var pixels: Small.Pixels = undefined;
    const atlas = Small.image(&pixels);
    try std.testing.expectEqualSlices(u32, &.{ 0xffffffff, 0xffffffff, 0, 0xffffffff, 0, 0xffffffff, 0xffffffff, 0 }, atlas.pixels);
}
