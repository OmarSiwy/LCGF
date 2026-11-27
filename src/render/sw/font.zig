//! The bundled bitmap font for the software renderer: DejaVu Sans Mono at 14 px (the examples'
//! atlas, src/example/font/, under its LICENSE.txt), repacked into `Mono`'s 16 x 16
//! byte-indexed grid, so the glyph quads `Mono.quads` makes sample it as they are. A shell
//! draws real text with it when the image is bound as its glyph texture (`lcgf_app` does this
//! for the software shells). A byte is a cell: printable ASCII, then Windows-1252's characters
//! at their bytes and the infinity sign at 0x81 (`Mono.encode` writes UTF-8 text in these
//! bytes); a control byte, or one of the few with no character, is blank, so a tab or a newline
//! in a line of text is a space. Tier 0.
//!
//! Contents: `width`, `height`, `image`, `images`, `texture`,
//! `glyphs(d, quads, first, count) iface.Glyphs`.

const sw = @import("sw.zig");
const iface = @import("../iface.zig");
const draw_list = @import("../../draw/draw_list.zig");
const DrawList = draw_list.DrawList;
const Quad = draw_list.Quad;
const Mono = @import("../../text/protocol.zig").Mono;
const Texture = @import("../../core/types.zig").Texture;

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

/// The images of a host that brings none: the white texture, then the font as `texture`.
pub const images = [_]sw.Image{ .white, image };
/// The font's texture in `images`.
pub const texture: Texture = @fromBackingInt(1);

/// The glyph quads of `d`'s text runs in this font (`Mono.quads`), written into `quads`, with
/// each run's `first` and `count` (at least `d.run_len` rows each), sampling `texture`. A host
/// whose images put the font elsewhere sets the result's `texture`. Glyphs past `quads.len`
/// are dropped, as `Mono.quads` drops them.
pub fn glyphs(d: *const DrawList, quads: []Quad, first: []u32, count: []u32) iface.Glyphs {
    const n = (Mono{}).quads(d, quads, .{ .first = first, .count = count });
    return .{ .quads = quads[0..n], .first = first, .count = count, .texture = texture };
}

test "glyphs: a quad per byte of a run, sampling the font" {
    const std = @import("std");
    var runs = [_]draw_list.TextRun{.{
        .rect = .{ 0, 0, 100, 20 },
        .clip = .{ 0, 0, 100, 20 },
        .start = 0,
        .bytes = 2,
        .px = 10,
        .color = 0xffffffff,
        .font = 0,
    }};
    var d: DrawList = undefined;
    d.runs = &runs;
    d.run_len = 1;
    d.strings = "AB";
    var quads: [4]Quad = undefined;
    var first: [1]u32 = undefined;
    var count: [1]u32 = undefined;
    const g = glyphs(&d, &quads, &first, &count);
    try std.testing.expectEqual(2, g.quads.len);
    try std.testing.expectEqual([2]u32{ 0, 2 }, g.span(0));
    try std.testing.expectEqual(image.alpha8.ptr, images[@backingInt(g.texture)].alpha8.ptr);
}
