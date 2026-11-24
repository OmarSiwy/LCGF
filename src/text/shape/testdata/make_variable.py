"""Build an original three-glyph variable-font fixture; requires fontTools only.

The A advance interpolates from 500 at wght=100 to 900 at wght=900, with an
equally interpolated rectangular outline. The glyph drawings are original test
geometry, not a subset of a third-party typeface. Run beside this script.
"""
from pathlib import Path
from tempfile import TemporaryDirectory

from fontTools.designspaceLib import DesignSpaceDocument, AxisDescriptor, SourceDescriptor
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.cffLib.CFFToCFF2 import convertCFFToCFF2
from fontTools.varLib import build


def master(path, advance, weight):
    builder = FontBuilder(1000, isTTF=True)
    builder.setupGlyphOrder([".notdef", "space", "A"])
    builder.setupCharacterMap({32: "space", 65: "A"})
    glyphs = {}
    for name in [".notdef", "space", "A"]:
        pen = TTGlyphPen(None)
        if name != "space":
            pen.moveTo((50, 0))
            pen.lineTo((advance - 50, 0))
            pen.lineTo((advance - 50, 700))
            pen.lineTo((50, 700))
            pen.closePath()
        glyphs[name] = pen.glyph()
    builder.setupGlyf(glyphs)
    builder.setupHorizontalMetrics({".notdef": (advance, 50), "space": (250, 0), "A": (advance, 50)})
    builder.setupHorizontalHeader(ascent=800, descent=-200)
    builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200, usWeightClass=weight)
    builder.setupNameTable({"familyName": "LCGF Variable Fixture", "styleName": "Regular", "uniqueFontIdentifier": "LCGFVariableFixture", "fullName": "LCGF Variable Fixture", "psName": "LCGFVariableFixture"})
    builder.setupPost()
    builder.setupMaxp()
    builder.save(path)


with TemporaryDirectory() as temp:
    directory = Path(temp)
    doc = DesignSpaceDocument()
    axis = AxisDescriptor()
    axis.name, axis.tag = "Weight", "wght"
    axis.minimum, axis.default, axis.maximum = 100, 100, 900
    doc.addAxis(axis)
    for weight, advance in [(100, 500), (900, 900)]:
        path = directory / f"master-{weight}.ttf"
        master(path, advance, weight)
        source = SourceDescriptor()
        source.path, source.name = str(path), f"master-{weight}"
        source.location = {"Weight": weight}
        source.copyInfo = source.copyLib = source.copyFeatures = weight == 100
        doc.addSource(source)
    font, _, _ = build(doc)
    font.save(Path(__file__).with_name("variable.ttf"))

# CFF/CFF2 fixtures exercise the cubic outline callback, which native glyf parsing cannot.
builder = FontBuilder(1000, isTTF=False)
builder.setupGlyphOrder([".notdef", "space", "A"])
builder.setupCharacterMap({32: "space", 65: "A"})
chars = {}
for name in [".notdef", "space", "A"]:
    pen = T2CharStringPen(500, None)
    if name != "space":
        pen.moveTo((50, 0))
        pen.lineTo((450, 0))
        pen.curveTo((450, 700), (50, 700), (50, 0))
        pen.closePath()
    chars[name] = pen.getCharString()
builder.setupHorizontalMetrics({name: (500, 50) for name in chars})
builder.setupHorizontalHeader(ascent=800, descent=-200)
builder.setupNameTable({"familyName": "LCGF CFF Fixture", "styleName": "Regular", "uniqueFontIdentifier": "LCGFCFFFixture", "fullName": "LCGF CFF Fixture", "psName": "LCGFCFFFixture"})
builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
builder.setupPost()
builder.setupCFF("LCGFCFFFixture", {"FullName": "LCGF CFF Fixture", "FamilyName": "LCGF CFF Fixture", "Weight": "Regular"}, chars, {})
builder.save(Path(__file__).with_name("cff.otf"))
convertCFFToCFF2(builder.font)
builder.save(Path(__file__).with_name("cff2.otf"))
