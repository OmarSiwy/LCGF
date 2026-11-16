"""Rebuilds the reference glyph images (ref.bin) with FreeType's smooth rasteriser.

    nix-shell -p "python3.withPackages(ps:[ps.freetype-py])" --run "python3 make.py"

FreeType is the independent reference: unhinted outlines of src/text/font/testdata/test.ttf,
8-bit coverage, at several sizes and horizontal subpixel offsets. Little-endian layout:

    u32 count, then per glyph: u32 codepoint, u16 px, u16 offset (x shift in 1/64 px),
    i16 left, i16 top (pixels right of / above the pen), u16 w, u16 h, then w*h coverage bytes.
"""
import os
import struct
import freetype

HERE = os.path.dirname(os.path.abspath(__file__))
FONT = os.path.join(HERE, "..", "..", "font", "testdata", "test.ttf")
TEXT = "AVTaeové"
SIZES = [9, 13, 16, 24, 40]
OFFSETS = [0, 16, 32, 48]  # 0, 1/4, 1/2, 3/4 px


def main():
    face = freetype.Face(FONT)
    out = []
    for px in SIZES:
        face.set_pixel_sizes(0, px)
        for off in OFFSETS:
            face.set_transform(freetype.Matrix(0x10000, 0, 0, 0x10000), freetype.Vector(off, 0))
            for ch in TEXT:
                face.load_char(ch, freetype.FT_LOAD_NO_HINTING | freetype.FT_LOAD_NO_BITMAP | freetype.FT_LOAD_RENDER)
                g = face.glyph
                bm = g.bitmap
                rows = bytes(b for r in range(bm.rows) for b in bm.buffer[r * bm.pitch : r * bm.pitch + bm.width])
                out.append(struct.pack("<IHHhhHH", ord(ch), px, off, g.bitmap_left, g.bitmap_top, bm.width, bm.rows) + rows)
    with open(os.path.join(HERE, "ref.bin"), "wb") as f:
        f.write(struct.pack("<I", len(out)) + b"".join(out))


main()
