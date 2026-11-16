"""Compares the images `zig build paths-golden` drew against the references next to this file.

    python3 src/draw/testdata/paths/check.py DUMP OUT_DIR [--tol N]

DUMP is the dumper's output: per image a u8 name length, the name, u32 w, u32 h (little-endian)
and w * h RGBA bytes. Each image is written as OUT_DIR/NAME.png and compared with NAME.png here
by tools/golden/golden.py. Exit 1 when any image does not match, or a reference has no image.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "..", "tools", "golden"))
from golden import compare, write_png  # noqa: E402

# Tolerance in levels of 255 (golden.py's --tol). The two sides sample alike; what remains is
# how far paths.zig's chords lie from the curve (paths_golden.zig flattens to 1/1024 px) and
# rounding.
TOL = 4


def main(argv):
    dump, out = argv[0], argv[1]
    tol = int(argv[argv.index("--tol") + 1]) if "--tol" in argv else TOL
    os.makedirs(out, exist_ok=True)
    data = open(dump, "rb").read()
    at, drawn = 0, set()
    ok = True
    while at < len(data):
        n = data[at]
        name = data[at + 1:at + 1 + n].decode()
        w, h = struct.unpack("<II", data[at + 1 + n:at + 9 + n])
        at += 9 + n
        png = os.path.join(out, name + ".png")
        write_png(png, w, h, data[at:at + w * h * 4])
        at += w * h * 4
        drawn.add(name)
        ok &= compare(png, os.path.join(HERE, name + ".png"), tol)
    for ref in sorted(f[:-4] for f in os.listdir(HERE) if f.endswith(".png")):
        if ref not in drawn:
            print(f"FAIL {ref}.png: no image drawn")
            ok = False
    print(f"{len(drawn)} images, {'all match' if ok else 'MISMATCH'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
