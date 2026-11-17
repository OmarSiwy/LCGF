"""Rebuilds the shaping test font (shape.ttf) and HarfBuzz's output for it (hb.txt).

    nix-shell -p "python3.withPackages(ps:[ps.fonttools ps.uharfbuzz])" \
        --run "python3 make.py <NotoSans.ttf>"

shape.ttf is Noto Sans (SIL OFL 1.1, see OFL.txt) at its default instance (wght 400, wdth 100),
subset to the characters of CASES with the layout features the built-in shaper implements:
kern, liga (GSUB), mark and mkmk (GPOS), and GDEF. Renamed: the OFL reserves "Noto".

hb.txt holds, per case and feature set, HarfBuzz's glyphs in font units, one case per line:

    features<TAB>text as hex code points<TAB>gid,cluster,x_advance,x_offset,y_offset;...

Clusters are byte offsets into the UTF-8 text.
"""
import sys
import uharfbuzz as hb
from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

CASES = [
    "AVTavo",
    "Type",
    "office fluff fi",
    "éàọ",
    "é́",
    "Táffi",
]
# Feature sets, as the shaper's commits add them: kerning only, then ligatures, then marks.
STAGES = {
    "kern": {"liga": False, "mark": False, "mkmk": False},
    "kern,liga": {"mark": False, "mkmk": False},
    "kern,liga,mark,mkmk": {},
}


def main(src):
    font = TTFont(src)
    font = instancer.instantiateVariableFont(font, {"wght": 400, "wdth": 100})
    opts = subset.Options()
    opts.layout_features = ["kern", "liga", "mark", "mkmk"]
    opts.hinting = False
    opts.drop_tables += ["STAT", "MVAR", "HVAR", "gasp", "prep"]
    opts.name_IDs = [0, 1, 2, 4, 6, 13, 14]
    sub = subset.Subsetter(opts)
    sub.populate(text="".join(CASES))
    sub.subset(font)
    for rec in list(font["name"].names):
        if rec.nameID in (1, 4, 6):
            s = rec.toUnicode().replace("Noto Sans", "LcgfShape Sans").replace("NotoSans", "LcgfShapeSans")
            font["name"].setName(s, rec.nameID, rec.platformID, rec.platEncID, rec.langID)
    font.save("shape.ttf")

    blob = hb.Blob.from_file_path("shape.ttf")
    face = hb.Face(blob)
    hbfont = hb.Font(face)
    lines = []
    for name, feats in STAGES.items():
        for text in CASES:
            buf = hb.Buffer()
            buf.add_str(text)
            buf.guess_segment_properties()
            buf.cluster_level = hb.BufferClusterLevel.MONOTONE_CHARACTERS
            hb.shape(hbfont, buf, feats)
            # uharfbuzz clusters count code points of add_str's UTF-32 input; convert to bytes.
            starts = []
            at = 0
            for ch in text:
                starts.append(at)
                at += len(ch.encode("utf-8"))
            glyphs = ";".join(
                f"{i.codepoint},{starts[i.cluster]},{p.x_advance},{p.x_offset},{p.y_offset}"
                for i, p in zip(buf.glyph_infos, buf.glyph_positions)
            )
            lines.append(f"{name}\t{' '.join(f'{ord(c):x}' for c in text)}\t{glyphs}")
    with open("hb.txt", "w") as f:
        f.write("\n".join(lines) + "\n")


main(sys.argv[1])
