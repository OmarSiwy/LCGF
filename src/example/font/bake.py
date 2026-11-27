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
# One cell per byte from 32 to 255: printable ASCII, then Windows-1252's characters at their
# bytes, with the infinity sign in 0x81, which that code page leaves unassigned. A byte with no
# character (127 and four more) is a blank cell. `Mono.encode` writes text in these bytes.
EXTRA = {0x81: "\u221e"}
atlas = Image.new("L", (16 * 9, 14 * 18))
# The ASCII rows drawn as they always were, onto one image, so their texels do not change.
ascii_rows = Image.new("L", (16 * 9, 6 * 18))
pen = ImageDraw.Draw(ascii_rows)
for code in range(32, 127):
    col, row = (code - 32) % 16, (code - 32) // 16
    pen.text((col * 9 + 4.5, row * 18 + 14), chr(code), font=font, anchor="ms", fill=255)
atlas.paste(ascii_rows, (0, 0))
# The rest one cell at a time: an accent that reaches past its cell is cut, not left in the next.
for code in range(128, 256):
    char = EXTRA.get(code) or bytes([code]).decode("cp1252", errors="ignore")
    if not char or code == 0xA0:
        continue
    cell = Image.new("L", (9, 18))
    ImageDraw.Draw(cell).text((4.5, 14), char, font=font, anchor="ms", fill=255)
    atlas.paste(cell, (((code - 32) % 16) * 9, ((code - 32) // 16) * 18))
(out / "mono.a8").write_bytes(atlas.tobytes())

with TTFont(source) as face:
    names = face["name"]
    notice = names.getDebugName(0).strip() + "\n\n" + names.getDebugName(13).strip()
    (out / "LICENSE.txt").write_text("\n".join(line.rstrip() for line in notice.splitlines()) + "\n")
