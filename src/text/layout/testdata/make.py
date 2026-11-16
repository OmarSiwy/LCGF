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
- With max_lines, lines after the last are dropped; if any were, or the last line is wider
  than the box, its clusters are dropped from the end until its ink plus an ellipsis fits, and
  the ellipsis is drawn after the ink. The cut line is never justified. Text that does not wrap
  is broken at an infinite width.
- Lines stack from the top: a line's baseline is the largest ascender of the spans on it
  below its top, and below that the largest descender plus line gap (an empty line takes the
  span of the glyph before it). Each span is shaped on its own.
- With carets, a caret bar is drawn for every byte offset: on the last line starting at or
  before it, at the last stop at or before it. Stops are grapheme boundaries; a cluster of
  several graphemes (a ligature) shares its width (advances plus justification) equally. A
  line ending in a space or newline does not offer its end. The bar is one pixel wide, its
  coverage split between two columns, from the line's top for its height (rows round half up). Baselines snap to whole
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
FRAME_TITLE = "Text layout"
FRAME_PARA = "The measure and wrap protocol hands every run to the shaper and the line breaker."
FRAME_SIZE = (240, 140)
SCENES = {
    "wrap": dict(text="Type office fluff into a lovely file, then copy every line of it.", px=20, box=(4, 2, 200), size=(208, 88)),
    "center": dict(text=PARA, px=18, box=(4, 2, 200), size=(208, 104), align=0.5),
    "end": dict(text=PARA, px=18, box=(4, 2, 200), size=(208, 104), align=1),
    "justify": dict(text=PARA, px=18, box=(4, 2, 200), size=(208, 104), justify=True),
    "clamp": dict(text=PARA, px=18, box=(4, 2, 200), size=(208, 56), max_lines=2),
    "single": dict(text="Type office fluff into a lovely file", px=16, box=(4, 2, 150), size=(160, 28), wrap=False, max_lines=1),
    "rich": dict(text="Small words, BIG words and small again, all in one paragraph.", px=16, box=(4, 2, 200), size=(208, 124), spans=[(13, 28), (22, 16)]),
    "carets": dict(text="An office fluff\nflows on, justified to the end of the box.", px=18, box=(4, 2, 200), size=(208, 84), justify=True, carets=True),
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


def ellipsize(lines, glyphs, raw, width, max_lines, ell):
    """Drops lines past max_lines and cuts the last one to end in an ellipsis `ell` px wide."""
    if max_lines is None:
        return lines, 0
    dropped = len(lines) > max_lines
    lines = lines[:max_lines]
    ln = lines[-1]
    if not dropped and ln["width"] <= width + SLACK:
        return lines, 0
    first, end = ln["first"], ln["ink"]
    while end > first and ink_of(glyphs, raw, first, end) + ell > width + SLACK:
        c = glyphs[end - 1].cluster
        while end > first and glyphs[end - 1].cluster == c:
            end -= 1
    ink = first
    for k in range(first, end):
        if not is_space(raw, glyphs[k]):
            ink = k + 1
    ln.update(end=end, ink=ink, hard=True, width=sum(g.advance for g in glyphs[first:ink]) + ell)
    return lines, ell


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
    lines = break_lines(glyphs, raw, bw if scene.get("wrap", True) else math.inf)
    (ell,) = shape(hbfont, upem, "\u2026", [(0, px)])
    lines, ell_w = ellipsize(lines, glyphs, raw, bw, scene.get("max_lines"), ell.advance)
    img = bytearray(W * H)
    top = by
    placed = []
    for ln in lines:
        on = glyphs[ln["first"]:ln["end"]] or glyphs[max(ln["first"] - 1, 0):ln["first"]] or [Glyph(0, 0, 0, 0, 0, px)]
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
        if ln is lines[-1] and ell_w:
            draw(img, W, H, face, ell, x, y)
        lx = bx + (0 if justified else (bw - ln["width"]) * scene.get("align", 0))
        height = (asc - desc + gap) * tall
        placed.append((ln, lx, extra, top, height))
        top += height
    if scene.get("carets"):
        for i in range(len(raw) + 1):
            x, t, h = caret(placed, glyphs, raw, i)
            bar(img, W, H, x, t, h)
    return img


def render_frame(face, hbfont, upem, asc, desc, gap):
    """The frame scene of golden.zig expectFrame: a column (pad 8, gap 6) holding a 22 px
    title that does not wrap and a 200 px wide box with a 16 px paragraph that does. Node
    rects are positions rounded to whole pixels, as layout.finalize does."""
    W, H = FRAME_SIZE
    img = bytearray(W * H)
    title_h = (asc - desc + gap) * 22 / upem
    runs = [(FRAME_TITLE, 22, math.inf, 8, 8), (FRAME_PARA, 16, 200, 8, math.floor(8 + title_h + 6 + 0.5))]
    for text, px, width, x0, y0 in runs:
        raw = text.encode("utf-8")
        glyphs = shape(hbfont, upem, text, [(0, px)])
        top = y0
        for ln in break_lines(glyphs, raw, width):
            y = math.floor(top + asc * px / upem + 0.5)
            x = x0
            for g in glyphs[ln["first"]:ln["ink"]]:
                draw(img, W, H, face, g, x, y)
                x += g.advance
            top += (asc - desc + gap) * px / upem
    return img


def caret(placed, glyphs, raw, index):
    """Caret x, line top and height for byte offset `index`."""
    def start(ln):
        return glyphs[ln["first"]].cluster if ln["first"] < len(glyphs) else len(raw)

    def byte_at(i):
        return glyphs[i].cluster if i < len(glyphs) else len(raw)

    k = max(sum(1 for p in placed if start(p[0]) <= index), 1) - 1
    ln, lx, extra, top, height = placed[k]
    stops = []
    x, i = lx, ln["first"]
    while i < ln["end"]:
        cs = glyphs[i].cluster
        cw = 0
        while i < ln["end"] and glyphs[i].cluster == cs:
            cw += glyphs[i].advance + (extra if is_space(raw, glyphs[i]) else 0)
            i += 1
        ce = byte_at(i)
        chars = raw[cs:ce].decode("utf-8")  # ASCII scenes: one grapheme per character
        off = cs
        for j, ch in enumerate(chars):
            stops.append((off, x + cw * j / len(chars)))
            off += len(ch.encode("utf-8"))
        x += cw
    if k == len(placed) - 1 or ln["end"] == ln["ink"]:
        stops.append((byte_at(ln["end"]), x))
    best = lx
    for off, sx in stops:
        if off > index:
            break
        best = sx
    return best, top, height


def bar(img, W, H, x, top, height):
    col = math.floor(x)
    f = x - col
    cov = [round(255 * (1 - f)), round(255 * f)]
    for r in range(math.floor(top + 0.5), min(math.floor(top + height + 0.5), H)):
        for d in range(2):
            c = col + d
            if 0 <= c < W:
                img[r * W + c] = max(img[r * W + c], cov[d])


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
    img = render_frame(face, hbfont, upem, hhea.ascent, hhea.descent, hhea.lineGap)
    with open(os.path.join(HERE, "frame.pgm"), "wb") as f:
        f.write(b"P5\n%d %d\n255\n" % FRAME_SIZE + bytes(img))
    print("frame ink pixels", sum(1 for v in img if v))


main(sys.argv[1])
