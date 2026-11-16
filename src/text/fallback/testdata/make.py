"""Rebuilds the mixed-script sample for the fallback chain: latin.ttf, armenian.ttf, georgian.ttf
and mixed.pgm.

    nix-shell -p "python3.withPackages(ps:[ps.fonttools ps.uharfbuzz ps.freetype-py])" \
        --run "python3 make.py <dir with NotoSans.ttf, NotoSansArmenian.ttf, NotoSansGeorgian.ttf>"

Each font is Noto (SIL OFL 1.1, see OFL.txt) at its default instance, subset to the characters
of TEXT it has, with the layout features the built-in shaper implements (kern, liga, mark,
mkmk), renamed (the OFL reserves "Noto"). None covers the whole sample: Latin and Greek are in
latin.ttf only, Armenian letters in armenian.ttf only, Georgian in georgian.ttf only.

mixed.pgm is the reference picture. Each character takes the first font of CHAIN that has it,
except that a run keeps its font while that font has the character (so spaces and punctuation
stay in the run around them); each run of one font is shaped by HarfBuzz and its glyphs are
rasterised by FreeType (unhinted) at PX pixels per em at their pen position, the pen carried
from run to run in pixels, composited by maximum coverage (the method of shape/testdata/deva.py).
"""
import os
import sys
import freetype
import uharfbuzz as hb
from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

TEXT = "Hi, Բարեւ! გამარჯობა αβγ"
CHAIN = [("latin.ttf", "NotoSans.ttf"), ("armenian.ttf", "NotoSansArmenian.ttf"), ("georgian.ttf", "NotoSansGeorgian.ttf")]
PX = 24
W, H, BASELINE = 320, 36, 26


def make(src, out):
    font = TTFont(src)
    if "fvar" in font:
        font = instancer.instantiateVariableFont(font, {a.axisTag: a.defaultValue for a in font["fvar"].axes})
    have = font.getBestCmap()
    opts = subset.Options()
    opts.layout_features = ["kern", "liga", "mark", "mkmk"]
    opts.hinting = False
    opts.drop_tables += ["STAT", "MVAR", "HVAR", "gasp", "prep"]
    opts.name_IDs = [0, 1, 2, 4, 6, 13, 14]
    sub = subset.Subsetter(opts)
    sub.populate(text="".join(c for c in TEXT if ord(c) in have))
    sub.subset(font)
    for rec in list(font["name"].names):
        if rec.nameID in (1, 4, 6):
            s = rec.toUnicode().replace("Noto Sans", "LcgrFallback Sans").replace("NotoSans", "LcgrFallbackSans")
            font["name"].setName(s, rec.nameID, rec.platformID, rec.platEncID, rec.langID)
    font.save(out)


def runs():
    cmaps = [TTFont(out).getBestCmap() for out, _ in CHAIN]
    cur, start, out = None, 0, []
    for i, ch in enumerate(TEXT):
        if cur is None or ord(ch) not in cmaps[cur]:
            pick = next(k for k, m in enumerate(cmaps) if ord(ch) in m)
            if cur is not None and pick != cur:
                out.append((start, i, cur))
                start = i
            cur = pick
    out.append((start, len(TEXT), cur))
    return out


def main(srcdir):
    for out, src in CHAIN:
        make(os.path.join(srcdir, src), out)
    img = bytearray(W * H)
    pen = 2.0
    for start, end, k in runs():
        path = CHAIN[k][0]
        hbfont = hb.Font(hb.Face(hb.Blob.from_file_path(path)))
        buf = hb.Buffer()
        buf.add_str(TEXT[start:end])
        buf.guess_segment_properties()
        hb.shape(hbfont, buf, {})
        face = freetype.Face(path)
        face.set_pixel_sizes(0, PX)
        scale = PX / TTFont(path)["head"].unitsPerEm
        for i, p in zip(buf.glyph_infos, buf.glyph_positions):
            x = pen + p.x_offset * scale
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
            pen += p.x_advance * scale
        print("run", TEXT[start:end].encode("utf-8"), "font", path, "pen", pen)
    with open("mixed.pgm", "wb") as f:
        f.write(b"P5\n%d %d\n255\n" % (W, H) + bytes(img))


main(sys.argv[1])
