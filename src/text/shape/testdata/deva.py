"""Rebuilds the complex-script sample for the HarfBuzz adapter: deva.ttf, deva-hb.txt, deva.pgm.

    nix-shell -p "python3.withPackages(ps:[ps.fonttools ps.uharfbuzz ps.freetype-py ps.skia-pathops])" \
        --run "python3 deva.py <NotoSansDevanagari.ttf>"

deva.ttf is Noto Sans Devanagari (SIL OFL 1.1, see OFL.txt) at its default instance, subset to
TEXT with all its layout features, renamed (the OFL reserves "Noto"). deva-hb.txt is HarfBuzz's
output for TEXT (one line, the hb.txt format of make.py). deva.pgm is the reference picture:
those glyphs rasterised by FreeType (unhinted) at PX pixels per em, each at its HarfBuzz pen
position (fractional x as a FreeType transform delta), composited by maximum coverage.
"""
import struct
import sys
import freetype
import uharfbuzz as hb
from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools.ttLib.removeOverlaps import removeOverlaps

TEXT = "हिन्दी नमस्ते"  # हिन्दी नमस्ते
PX = 32
W, H, BASELINE = 224, 48, 36


def main(src):
    font = TTFont(src)
    if "fvar" in font:
        font = instancer.instantiateVariableFont(font, {a.axisTag: a.defaultValue for a in font["fvar"].axes})
    opts = subset.Options()
    opts.layout_features = ["*"]
    opts.hinting = False
    opts.drop_tables += ["STAT", "MVAR", "HVAR", "gasp", "prep"]
    opts.name_IDs = [0, 1, 2, 4, 6, 13, 14]
    sub = subset.Subsetter(opts)
    sub.populate(text=TEXT)
    sub.subset(font)
    for rec in list(font["name"].names):
        if rec.nameID in (1, 4, 6):
            s = rec.toUnicode().replace("Noto Sans", "LcgrDeva Sans").replace("NotoSans", "LcgrDevaSans")
            font["name"].setName(s, rec.nameID, rec.platformID, rec.platEncID, rec.langID)
    # Instancing leaves overlapping contours (flagged OVERLAP_SIMPLE). FreeType renders those
    # oversampled; src/text/raster/ sums coverage and over-covers where overlapping edges share
    # a pixel. Merging the overlaps here keeps the comparison to the rasterisers' common case.
    removeOverlaps(font)
    font.save("deva.ttf")
    upem = font["head"].unitsPerEm

    hbfont = hb.Font(hb.Face(hb.Blob.from_file_path("deva.ttf")))
    buf = hb.Buffer()
    buf.add_str(TEXT)
    buf.guess_segment_properties()
    buf.cluster_level = hb.BufferClusterLevel.MONOTONE_CHARACTERS
    hb.shape(hbfont, buf, {})
    starts, at = [], 0
    for ch in TEXT:
        starts.append(at)
        at += len(ch.encode("utf-8"))
    infos, poss = buf.glyph_infos, buf.glyph_positions
    glyphs = ";".join(f"{i.codepoint},{starts[i.cluster]},{p.x_advance},{p.x_offset},{p.y_offset}" for i, p in zip(infos, poss))
    with open("deva-hb.txt", "w") as f:
        f.write(f"all\t{' '.join(f'{ord(c):x}' for c in TEXT)}\t{glyphs}\n")

    face = freetype.Face("deva.ttf")
    face.set_pixel_sizes(0, PX)
    img = bytearray(W * H)
    pen = 0
    scale = PX / upem
    for i, p in zip(infos, poss):
        x = 2 + (pen + p.x_offset) * scale
        y = BASELINE - p.y_offset * scale
        xi, yi = int(x // 1), int(y // 1)
        face.set_transform(freetype.Matrix(0x10000, 0, 0, 0x10000), freetype.Vector(round((x - xi) * 64), round((yi - y) * 64)))
        face.load_glyph(i.codepoint, freetype.FT_LOAD_NO_HINTING | freetype.FT_LOAD_NO_BITMAP | freetype.FT_LOAD_RENDER)
        g = face.glyph
        bm = g.bitmap
        for r in range(bm.rows):
            for c in range(bm.width):
                px, py = xi + g.bitmap_left + c, yi - g.bitmap_top + r
                if 0 <= px < W and 0 <= py < H:
                    img[py * W + px] = max(img[py * W + px], bm.buffer[r * bm.pitch + c])
        pen += p.x_advance
    with open("deva.pgm", "wb") as f:
        f.write(b"P5\n%d %d\n255\n" % (W, H) + bytes(img))
    print("glyphs", len(infos), "width px", pen * scale)


main(sys.argv[1])
