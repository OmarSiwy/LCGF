"""Rebuilds the span faces of lcgf_app's styled-text tests (src/app/replay.zig): bold.ttf,
oblique.ttf and mono.ttf.

    nix-shell -p "python3.withPackages(ps:[ps.fonttools])" --run \\
        "python3 spans.py <DejaVuSans-Bold.ttf> <DejaVuSans-Oblique.ttf> <DejaVuSansMono.ttf>"

DejaVu Sans Bold, Oblique and Mono 2.37 (the licence of LICENSE.txt), each subset to the
letters of the paragraph the test draws, as symbols.ttf is (make.py): no hinting, no layout
tables, renamed as the Vera licence asks of modified fonts.
"""
import os
import sys
from fontTools import subset
from fontTools.ttLib import TTFont

CHARS = "plainboditccde "
OUT = ["bold.ttf", "oblique.ttf", "mono.ttf"]

for src, out in zip(sys.argv[1:4], OUT):
    font = TTFont(src)
    opts = subset.Options()
    opts.layout_features = []
    opts.hinting = False
    opts.drop_tables += ["GSUB", "GPOS", "GDEF", "kern", "gasp", "prep", "fpgm", "cvt ", "MATH"]
    opts.name_IDs = [0, 1, 2, 4, 6]  # the licence (13, 14) is LICENSE.txt's
    opts.notdef_outline = True
    sub = subset.Subsetter(opts)
    sub.populate(text=CHARS)
    sub.subset(font)
    for rec in list(font["name"].names):
        if rec.nameID in (1, 4, 6):
            s = rec.toUnicode().replace("DejaVu Sans", "LcgfSpans Sans").replace("DejaVuSans", "LcgfSpansSans")
            font["name"].setName(s, rec.nameID, rec.platformID, rec.platEncID, rec.langID)
    font.save(os.path.join(os.path.dirname(os.path.abspath(__file__)), out))
