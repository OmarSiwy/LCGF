"""Rebuilds symbols.ttf, the fallback face of the text service's tests (src/app/text.zig).

    nix-shell -p "python3.withPackages(ps:[ps.fonttools])" --run "python3 make.py <DejaVuSans.ttf>"

DejaVu Sans 2.37 (Bitstream Vera licence with DejaVu's changes in the public domain, the
licence of src/example/font/LICENSE.txt), subset to the two characters the repository's main
test face (src/text/layout/testdata/layout.ttf, Noto Sans) lacks: the infinity sign and the
middle dot. No hinting, no layout tables: the built-in shaper reads cmap and hmtx only here.
Renamed, as the Vera licence asks of modified fonts.
"""
import os
import sys
from fontTools import subset
from fontTools.ttLib import TTFont

CHARS = "∞·"

font = TTFont(sys.argv[1])
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
        s = rec.toUnicode().replace("DejaVu Sans", "LcgfSymbols Sans").replace("DejaVuSans", "LcgfSymbolsSans")
        font["name"].setName(s, rec.nameID, rec.platformID, rec.platEncID, rec.langID)
font.save(os.path.join(os.path.dirname(os.path.abspath(__file__)), "symbols.ttf"))
