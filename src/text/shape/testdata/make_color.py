"""Original COLRv0/CPAL, sbix PNG and SVG font fixtures; requires fontTools.

All drawings are original test rectangles. Each output keeps one color format,
so profile dispatch and decoder paths can be checked independently.
"""
from pathlib import Path
import struct
import zlib

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable
from fontTools.colorLib.builder import buildCOLR, buildCPAL
from fontTools.ttLib.tables.sbixGlyph import Glyph
from fontTools.ttLib.tables.sbixStrike import Strike
from fontTools.ttLib.tables.S_V_G_ import SVGDocument


def base():
    builder = FontBuilder(1000, isTTF=True)
    order = [".notdef", "space", "A", "left", "right"]
    builder.setupGlyphOrder(order)
    builder.setupCharacterMap({32: "space", 65: "A"})
    glyphs = {}
    for name in order:
        pen = TTGlyphPen(None)
        if name != "space":
            left, right = (50, 250) if name == "left" else (250, 450) if name == "right" else (50, 450)
            pen.moveTo((left, 0))
            pen.lineTo((right, 0))
            pen.lineTo((right, 700))
            pen.lineTo((left, 700))
            pen.closePath()
        glyphs[name] = pen.glyph()
    builder.setupGlyf(glyphs)
    builder.setupHorizontalMetrics({name: (500, 250 if name == "right" else 50) for name in order})
    builder.setupHorizontalHeader(ascent=800, descent=-200)
    builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    builder.setupNameTable({"familyName": "LCGF Color Fixture", "styleName": "Regular", "uniqueFontIdentifier": "LCGFColorFixture", "fullName": "LCGF Color Fixture", "psName": "LCGFColorFixture"})
    builder.setupPost()
    builder.setupMaxp()
    return builder.font


font = base()
font["COLR"] = buildCOLR({"A": [("left", 0), ("right", 1)]}, version=0, glyphMap=font.getReverseGlyphMap())
font["CPAL"] = buildCPAL([[(1, 0, 0, 1), (0, 0, 1, 1)], [(0, 1, 0, 1), (1, 1, 0, 0.5)]])
font.save(Path(__file__).with_name("color-layers.ttf"))


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\0\xff\x80\0\xff")) + chunk(b"IEND", b"")
font = base()
sbix = newTable("sbix")
strike = Strike(ppem=16, resolution=72)
strike.glyphs["A"] = Glyph(glyphName="A", graphicType="png ", imageData=png)
sbix.strikes[16] = strike
font["sbix"] = sbix
font.save(Path(__file__).with_name("color-png.ttf"))

font = base()
svg = newTable("SVG ")
svg.docList = [SVGDocument('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -800 500 1000"><path id="glyph2" d="M50 0H450V-700H50Z" fill="#ff8000"/></svg>', 2, 2)]
font["SVG "] = svg
font.save(Path(__file__).with_name("color-svg.ttf"))
