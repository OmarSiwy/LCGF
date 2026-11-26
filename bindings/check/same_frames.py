"""Compares two dumps (bindings/check/dump.zig's format) of examples/markup's page: the Zig
spec frontend's (the Zig widgets) and the seam's (the reference widgets C++ and Rust run). Every
draw list, focus and wake must be byte-identical, and every event but a slider's: a Zig
slider reports its event when it is released, the seam's on each change while it is held.

    same_frames.py <zig.bin> <seam.bin> <slider slot>..."""
import struct, sys

QUAD, RUN, CUSTOM = 136, 96, 96


def frames(path):
    data, i, out = open(path, "rb").read(), 0, []
    while i < len(data):
        start = i
        for size in (QUAD, RUN, 1):
            (n,) = struct.unpack_from("<I", data, i)
            i += 4 + n * size
        (n,) = struct.unpack_from("<I", data, i)
        i += 4 + 16 * n
        (n,) = struct.unpack_from("<I", data, i)
        i += 4 + CUSTOM * n + 12
        out.append(data[start:i])
    return out


a, b = frames(sys.argv[1]), frames(sys.argv[2])
sliders = {int(s) for s in sys.argv[3:]}
if len(a) != len(b):
    sys.exit(f"{len(a)} frames against {len(b)}")
for k, (x, y) in enumerate(zip(a, b)):
    (wx,), (wy,) = struct.unpack_from("<I", x, len(x) - 12), struct.unpack_from("<I", y, len(y) - 12)
    if x[:-12] != y[:-12] or x[-8:] != y[-8:] or (wx != wy and not ({wx, wy} & sliders)):
        sys.exit(f"frame {k} differs: events {wx} and {wy}")
