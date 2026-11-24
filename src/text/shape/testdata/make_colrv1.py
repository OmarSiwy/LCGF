"""Original bounded COLRv1 paint graph fixtures. Requires fontTools.

Only original rectangles/gradients are used. Each letter exercises a distinct real paint
graph: gradients, clipping/composite, affine transform, glyph reuse and foreground color.
"""
from pathlib import Path
from fontTools.colorLib.builder import buildCOLR, buildCPAL
from fontTools.ttLib.tables.otTables import PaintFormat as P, CompositeMode as C
from make_color import base

font = base()
order = font.getGlyphOrder()
for name in ["B", "C", "D", "E", "F", "G", "H"]:
    order.append(name)
    font["glyf"].glyphs[name] = font["glyf"]["A"]
    font["hmtx"].metrics[name] = (500, 50)
font.setGlyphOrder(order)
for cmap in font["cmap"].tables:
    if cmap.isUnicode():
        cmap.cmap.update({ord(name): name for name in ["B", "C", "D", "E", "F", "G", "H"]})

def solid(index=0, alpha=1):
    return dict(Format=P.PaintSolid, PaletteIndex=index, Alpha=alpha)
def glyph(name, paint):
    return dict(Format=P.PaintGlyph, Glyph=name, Paint=paint)
line = dict(Extend=0, ColorStop=[dict(StopOffset=0, PaletteIndex=0, Alpha=1), dict(StopOffset=1, PaletteIndex=1, Alpha=1)])
paints = {
    "A": dict(Format=P.PaintColrLayers, Layers=[glyph("left", dict(Format=P.PaintLinearGradient, ColorLine=line, x0=50, y0=0, x1=250, y1=0, x2=50, y2=700)), glyph("right", solid(1))]),
    "B": dict(Format=P.PaintComposite, SourcePaint=glyph("A", solid(0, .5)), CompositeMode=C.SRC_IN, BackdropPaint=glyph("left", solid(1))),
    "C": glyph("A", dict(Format=P.PaintRadialGradient, ColorLine=line, x0=250, y0=350, r0=0, x1=250, y1=350, r1=200)),
    "D": glyph("A", dict(Format=P.PaintSweepGradient, ColorLine=line, centerX=250, centerY=350, startAngle=0, endAngle=360)),
    "E": dict(Format=P.PaintTransform, Paint=glyph("left", solid()), Transform=dict(xx=1, yx=0, xy=0, yy=1, dx=100, dy=0)),
    "F": dict(Format=P.PaintColrGlyph, Glyph="A"),
    "G": glyph("A", solid(0xFFFF, .5)),
    "H": glyph("A", dict(Format=P.PaintLinearGradient, ColorLine=line, x0=0, y0=0, x1=0, y1=0, x2=0, y2=700)),
}
font["COLR"] = buildCOLR(paints, version=1, glyphMap=font.getReverseGlyphMap(), clipBoxes={name: (0, 0, 500, 800) for name in paints})
font["CPAL"] = buildCPAL([[(1, 0, 0, 1), (0, 0, 1, 1)], [(0, 1, 0, 1), (1, 1, 0, .5)]])
font.save(Path(__file__).with_name("color-paint.ttf"))
