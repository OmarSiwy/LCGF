//! The bundled bitmap font for the software renderer: DejaVu Sans Mono at 14 px (the examples'
//! atlas, src/example/font/, under its LICENSE.txt), repacked into `Mono`'s 16 x 16
//! byte-indexed grid, so the glyph quads `Mono.quads` makes sample it as they are. A shell
//! draws real text with it when the image is bound as its glyph texture (`lcgf_app` does this
//! for the software shells). Bytes outside printable ASCII show the question mark. Tier 0.

const lcgf_types = @import("../../core/types.zig");
const sw = @import("sw.zig");

const cell_w = 9;
const cell_h = 18;
const source_columns = 16;
const source: *const [source_columns * cell_w * 6 * cell_h]u8 = @embedFile("../../example/font/mono.a8");

pub const width = 16 * cell_w;
pub const height = 16 * cell_h;

const pixels: [width * height]u32 = blk: {
    @setEvalBranchQuota(20 * width * height);
    var out: [width * height]u32 = undefined;
    for (0..256) |b| {
        const index = (if (b >= 32 and b <= 126) b else '?') - 32;
        const sx = (index % source_columns) * cell_w;
        const sy = (index / source_columns) * cell_h;
        const dx = (b % 16) * cell_w;
        const dy = (b / 16) * cell_h;
        for (0..cell_h) |y| for (0..cell_w) |x| {
            const a = source[(sy + y) * source_columns * cell_w + sx + x];
            out[(dy + y) * width + dx + x] = lcgf_types.Color.rgba(255, 255, 255, a).bitsOf();
        };
    }
    break :blk out;
};

pub const image: sw.Image = .{ .pixels = &pixels, .width = width, .height = height };
