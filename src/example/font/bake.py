"""Bake the example font from DejaVu Sans Mono 2.37. Requires Pillow and fontTools."""
from pathlib import Path
import sys

from PIL import Image, ImageDraw, ImageFont
from fontTools.ttLib import TTFont

source = Path(sys.argv[1])
out = Path(__file__).parent
font = ImageFont.truetype(str(source), 14)
# Nearest-sampled cells at the examples' native 14px UI size.
# Mono measures one byte as 0.6 em and one line as 1.25 em.
atlas = Image.new("L", (16 * 9, 6 * 18))
pen = ImageDraw.Draw(atlas)
for code in range(32, 127):
    col, row = (code - 32) % 16, (code - 32) // 16
    pen.text((col * 9 + 4.5, row * 18 + 14), chr(code), font=font, anchor="ms", fill=255)
(out / "mono.a8").write_bytes(atlas.tobytes())

with TTFont(source) as face:
    names = face["name"]
    notice = names.getDebugName(0).strip() + "\n\n" + names.getDebugName(13).strip()
    (out / "LICENSE.txt").write_text("\n".join(line.rstrip() for line in notice.splitlines()) + "\n")
