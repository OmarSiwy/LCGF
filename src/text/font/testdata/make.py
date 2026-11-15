"""Rebuilds the test fonts from Liberation Sans 2.1.5 (SIL OFL 1.1, see OFL.txt).

    PYTHONPATH=<fonttools site-packages> python3 make.py <dir with LiberationSans-*.ttf>

Subsets to a few glyphs (with the legacy kern table, GPOS kern and a composite, eacute), drops
hinting, and renames the family: the OFL reserves the name "Liberation" for unmodified fonts.
GPOS is rebuilt from its own pairs plus one class pair, so it has a PairPos format 1 and a
format 2 subtable.
"""
import sys
from fontTools import subset
from fontTools.feaLib.builder import addOpenTypeFeaturesFromString
from fontTools.ttLib import TTFont, TTCollection

TEXT = " AVTaeové"


def make(src, family, style):
    opts = subset.Options()
    opts.legacy_kern = True
    opts.layout_features = ["kern"]
    opts.hinting = False
    opts.drop_tables += ["GSUB", "GDEF", "gasp", "DSIG"]
    opts.name_IDs = [0, 1, 2, 4, 6, 13, 14]
    font = TTFont(src)
    sub = subset.Subsetter(opts)
    sub.populate(text=TEXT)
    sub.subset(font)
    pairs = []
    for lookup in font["GPOS"].table.LookupList.Lookup:
        for st in lookup.SubTable:
            for first, ps in zip(st.Coverage.glyphs, st.PairSet):
                for r in ps.PairValueRecord:
                    pairs.append(f"pos {first} {r.SecondGlyph} {r.Value1.XAdvance};")
    del font["GPOS"]
    fea = "languagesystem DFLT dflt;\nfeature kern {\n" + "\n".join(pairs)
    addOpenTypeFeaturesFromString(font, fea + "\npos [o e eacute] v -50;\n} kern;\n")
    names = font["name"]
    full = f"{family} {style}"
    for rec in list(names.names):
        if rec.nameID == 1:
            names.setName(family, 1, rec.platformID, rec.platEncID, rec.langID)
        elif rec.nameID == 4:
            names.setName(full, 4, rec.platformID, rec.platEncID, rec.langID)
        elif rec.nameID == 6:
            names.setName(full.replace(" ", "-"), 6, rec.platformID, rec.platEncID, rec.langID)
    return font


d = sys.argv[1]
regular = make(f"{d}/LiberationSans-Regular.ttf", "LcgrTest Sans", "Regular")
regular.save("test.ttf")
bold = make(f"{d}/LiberationSans-Bold.ttf", "LcgrTest Sans", "Bold")
coll = TTCollection()
coll.fonts = [TTFont("test.ttf"), bold]
coll.save("test.ttc")
