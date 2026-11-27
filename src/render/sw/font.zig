//! The bundled bitmap font for the software renderer: DejaVu Sans Mono at 14 px (the examples'
//! atlas, src/example/font/, under its LICENSE.txt), repacked into `Mono`'s 16 x 16
//! byte-indexed grid, so the glyph quads `Mono.quads` makes sample it as they are. A shell
//! draws real text with it when the image is bound as its glyph texture (`lcgf_app` does this
//! for the software shells). A byte is a cell: printable ASCII, then Windows-1252's characters
//! at their bytes and the infinity sign at 0x81 (`Mono.encode` writes UTF-8 text in these
//! bytes); a control byte, or one of the few with no character, is blank, so a tab or a newline
//! in a line of text is a space. Tier 0.

const sw = @import("sw.zig");

const cell_w = 9;
const cell_h = 18;
const source_columns = 16;
/// Rows of sixteen cells in the source, from the space on: bytes 32 to 255.
const source_rows = 14;
const source: *const [source_columns * cell_w * source_rows * cell_h]u8 = @embedFile("../../example/font/mono.a8");

pub const width = 16 * cell_w;
pub const height = 16 * cell_h;

/// Coverage, one byte a texel (`sw.Image.alpha8`): a quarter of the bytes of RGBA.
const alpha: [width * height]u8 = blk: {
    @setEvalBranchQuota(20 * width * height);
    var out: [width * height]u8 = undefined;
    for (0..256) |b| {
        // A control byte shows the space's cell, which is blank.
        const index = (if (b >= 32) b else ' ') - 32;
        const sx = (index % source_columns) * cell_w;
        const sy = (index / source_columns) * cell_h;
        const dx = (b % 16) * cell_w;
        const dy = (b / 16) * cell_h;
        for (0..cell_h) |y| for (0..cell_w) |x| {
            out[(dy + y) * width + dx + x] = source[(sy + y) * source_columns * cell_w + sx + x];
        };
    }
    break :blk out;
};

pub const image: sw.Image = .{ .alpha8 = &alpha, .width = width, .height = height };
