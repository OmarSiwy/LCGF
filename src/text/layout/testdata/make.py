"""Rebuilds the text layout test font (layout.ttf) and the golden pictures (*.pgm).

    nix-shell -p "python3.withPackages(ps:[ps.fonttools ps.uharfbuzz ps.freetype-py])" \
        --run "python3 make.py <NotoSans.ttf>"

layout.ttf is Noto Sans (SIL OFL 1.1, see OFL.txt) at its default instance (wght 400, wdth 100),
subset to printable ASCII plus a few letters and the ellipsis, with the layout features the
built-in shaper implements (kern, liga, mark, mkmk, GDEF). Renamed: the OFL reserves "Noto".

Each picture is one scene of SCENES laid out here, independently of src/text/layout/: HarfBuzz
shapes the text, the greedy rules below break, align and truncate it, FreeType rasterises every
glyph (unhinted) at its pen position and the glyphs are composited by maximum coverage. The Zig
tests lay the same scene out with the built-in shaper and src/text/layout/, rasterise with
src/text/raster/, and compare (golden.zig).

The rules, as text layout implements them:
- Break opportunities are after a run of spaces, and after a newline (mandatory). A line takes
  whole words while the width of its ink (trailing spaces hang) fits the box, 1/64 px slack.
  A word wider than the box on its own is broken between clusters.
- Each line starts at (box - ink width) * align (0 start, 0.5 centre, 1 end). Justified lines
  (all but the last and those ended by a newline) share the free width equally among their
  inner spaces.
- Lines stack from the top: each is as tall as the tallest span on it (ascender - descender +
  line gap) and its baseline is the tallest ascender below its top. Baselines snap to whole
  pixels (round half up), x stays fractional.
"""
import math
import os
import sys

import freetype
import uharfbuzz as hb
from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

HERE = os.path.dirname(os.path.abspath(__file__))
FONT = os.path.join(HERE, "layout.ttf")
CHARS = "".join(chr(c) for c in range(0x20, 0x7F)) + "éàüß…́"
SLACK = 1 / 64

# name: text, px, box (x, y, width), picture (w, h), align, justify, max_lines, spans
# (byte start, px) after the first, which starts at 0 with `px`.
PARA = "Lines of a paragraph can sit at the start, the centre or the end of the box, or fill it."
SCENES = {
    "wrap": dict(text="Type office fluff into a lovely file, then copy every line of it.", px=20, box=(4, 2, 200), size=(208, 88)),
    "center": dict(text=PARA, px=18, box=(4, 2, 200), size=(208, 104), align=0.5),
    "end": dict(text=PARA, px=18, box=(4, 2, 200), size=(208, 104), align=1),
    "justify": dict(text=PARA, px=18, box=(4, 2, 200), size=(208, 104), justify=True),
    "narrow": dict(text="Pneumonoultramicroscopic words\nbreak hard.", px=16, box=(3, 1, 90), size=(96, 92)),
}


def subset_font(src):
    font = TTFont(src)
    if "fvar" in font:
        font = instancer.instantiateVariableFont(font, {"wght": 400, "wdth": 100})
    opts = subset.Options()
    opts.layout_features = ["kern", "liga", "mark", "mkmk"]
    opts.hinting = False
    opts.drop_tables += ["STAT", "MVAR", "HVAR", "gasp", "prep"]
    opts.name_IDs = [0, 1, 2, 4, 6, 13, 14]
    opts.notdef_outline = True
    sub = subset.Subsetter(opts)
    sub.populate(text=CHARS)
    sub.subset(font)
    for rec in list(font["name"].names):
        if rec.nameID in (1, 4, 6):
            s = rec.toUnicode().replace("Noto Sans", "LcgrLayout Sans").replace("NotoSans", "LcgrLayoutSans")
            font["name"].setName(s, rec.nameID, rec.platformID, rec.platEncID, rec.langID)
    font.save(FONT)


class Glyph:
    def __init__(self, gid, cluster, advance, x_offset, y_offset, px):
        self.gid, self.cluster, self.advance, self.x_offset, self.y_offset, self.px = gid, cluster, advance, x_offset, y_offset, px


def shape(hbfont, upem, text, spans):
    """HarfBuzz glyphs of each span, advances in px, clusters as byte offsets into text."""
    raw = text.encode("utf-8")
    out = []
    for i, (start, px) in enumerate(spans):
        end = spans[i + 1][0] if i + 1 < len(spans) else len(raw)
        part = raw[start:end].decode("utf-8")
        buf = hb.Buffer()
        buf.add_str(part)
        buf.guess_segment_properties()
        buf.cluster_level = hb.BufferClusterLevel.MONOTONE_CHARACTERS
        hb.shape(hbfont, buf, {})
        starts, at = [], start
        for ch in part:
            starts.append(at)
            at += len(ch.encode("utf-8"))
        s = px / upem
        for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
            out.append(Glyph(info.codepoint, starts[info.cluster], pos.x_advance * s, pos.x_offset * s, pos.y_offset * s, px))
    return out


def opportunities(raw):
    """Byte offsets after which a line may (or, for a newline, must) end; the end of text last."""
    ops = []
    for i, b in enumerate(raw):
        nxt = raw[i + 1] if i + 1 < len(raw) else None
        if b == 0x0A:
            ops.append((i + 1, True))
        elif b == 0x20 and nxt is not None and nxt != 0x20:
            ops.append((i + 1, False))
    if not ops or ops[-1][0] != len(raw):
        ops.append((len(raw), True))
    return ops


def is_space(raw, g):
    return raw[g.cluster] in (0x20, 0x0A)


def break_lines(glyphs, raw, width):
    """Lines as dicts: first, end (glyphs), ink (glyph after the last inked one), hard."""
    lines = []
    first, gi = 0, 0
    limit = width + SLACK
    for pos, mandatory in opportunities(raw):
        seg = gi
        while gi < len(glyphs) and glyphs[gi].cluster < pos:
            gi += 1
        inked = any(not is_space(raw, g) for g in glyphs[seg:gi])
        if inked and seg > first and ink_of(glyphs, raw, first, gi) > limit:
            lines.append(dict(first=first, end=seg, hard=False))
            first = seg
        if inked and ink_of(glyphs, raw, first, gi) > limit:
            # A word wider than the box: break between its clusters.
            k = first
            while k < gi:
                nk = k
                while nk < gi and glyphs[nk].cluster == glyphs[k].cluster:
                    nk += 1
                if not is_space(raw, glyphs[k]) and k > first and ink_of(glyphs, raw, first, nk) > limit:
                    lines.append(dict(first=first, end=k, hard=False))
                    first = k
                k = nk
        if mandatory:
            lines.append(dict(first=first, end=gi, hard=True))
            first = gi
    if not lines or raw.endswith(b"\n"):
        lines.append(dict(first=len(glyphs), end=len(glyphs), hard=True))
    for ln in lines:
        ink = ln["first"]
        for k in range(ln["first"], ln["end"]):
            if not is_space(raw, glyphs[k]):
                ink = k + 1
        ln["ink"] = ink
        ln["width"] = sum(g.advance for g in glyphs[ln["first"]:ink])
    return lines


def ink_of(glyphs, raw, first, end):
    """Width from glyph `first` to the end of the last non-space glyph before `end`."""
    w, ink = 0.0, 0.0
    for g in glyphs[first:end]:
        w += g.advance
        if not is_space(raw, g):
            ink = w
    return ink


def render(scene, face, hbfont, upem, asc, desc, gap):
    text = scene["text"]
    raw = text.encode("utf-8")
    px = scene["px"]
    spans = [(0, px)] + scene.get("spans", [])
    bx, by, bw = scene["box"]
    W, H = scene["size"]
    glyphs = shape(hbfont, upem, text, spans)
    lines = break_lines(glyphs, raw, bw)
    img = bytearray(W * H)
    top = by
    for ln in lines:
        on = glyphs[ln["first"]:ln["end"]] or [Glyph(0, 0, 0, 0, 0, px)]
        tall = max(g.px for g in on) / upem
        base = top + asc * tall
        ink = glyphs[ln["first"]:ln["ink"]]
        spaces = sum(1 for g in ink if is_space(raw, g))
        justified = scene.get("justify", False) and not ln["hard"] and spaces > 0
        extra = (bw - ln["width"]) / spaces if justified else 0
        x = bx + (0 if justified else (bw - ln["width"]) * scene.get("align", 0))
        y = math.floor(base + 0.5)
        for g in ink:
            draw(img, W, H, face, g, x, y)
            x += g.advance + (extra if is_space(raw, g) else 0)
        top += (asc - desc + gap) * tall
    return img


def draw(img, W, H, face, g, pen, base):
    assert g.y_offset == 0, "the scenes keep glyphs on the baseline"
    face.set_pixel_sizes(0, int(g.px))
    x = pen + g.x_offset
    xi = math.floor(x)
    face.set_transform(freetype.Matrix(0x10000, 0, 0, 0x10000), freetype.Vector(round((x - xi) * 64), 0))
    face.load_glyph(g.gid, freetype.FT_LOAD_NO_HINTING | freetype.FT_LOAD_NO_BITMAP | freetype.FT_LOAD_RENDER)
    bm = face.glyph.bitmap
    for r in range(bm.rows):
        for c in range(bm.width):
            px, py = xi + face.glyph.bitmap_left + c, base - face.glyph.bitmap_top + r
            if 0 <= px < W and 0 <= py < H:
                img[py * W + px] = max(img[py * W + px], bm.buffer[r * bm.pitch + c])


def main(src):
    subset_font(src)
    upem = TTFont(FONT)["head"].unitsPerEm
    hhea = TTFont(FONT)["hhea"]
    hbfont = hb.Font(hb.Face(hb.Blob.from_file_path(FONT)))
    face = freetype.Face(FONT)
    for name, scene in SCENES.items():
        img = render(scene, face, hbfont, upem, hhea.ascent, hhea.descent, hhea.lineGap)
        W, H = scene["size"]
        with open(os.path.join(HERE, name + ".pgm"), "wb") as f:
            f.write(b"P5\n%d %d\n255\n" % (W, H) + bytes(img))
        print(name, "ink pixels", sum(1 for v in img if v))


main(sys.argv[1])
