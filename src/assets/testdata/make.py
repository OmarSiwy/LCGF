"""Writes the PNG test images of src/assets (run from this directory: python3 make.py).

Python's zlib at level 9 compresses them, so the tests decode a stream from a second deflate
encoder, not only std's. Pixel (x, y) of every image is defined by `pixel` below; the Zig tests
compute the same function, so each file is checked against its source, not against a decode.
"""
import struct, zlib

def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))

def pixel(x, y):
    # Straight RGBA: a gradient with a checker of half-transparent cells.
    return (x * 255 // 15, y * 255 // 15, (x ^ y) * 16 % 256, 255 if (x // 4 + y // 4) % 2 == 0 else 128)

def write(name, w, h, filt):
    raw = b""
    for y in range(h):
        line = b"".join(bytes(pixel(x, y)) for x in range(w))
        prev = b"".join(bytes(pixel(x, y - 1)) for x in range(w)) if y else bytes(len(line))
        f = filt(y)
        out = bytearray()
        for i, c in enumerate(line):
            a = line[i - 4] if i >= 4 else 0
            b = prev[i]
            u = prev[i - 4] if i >= 4 else 0
            p = a + b - u
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - u)
            paeth = a if pa <= pb and pa <= pc else (b if pb <= pc else u)
            out.append((c - [0, a, b, (a + b) // 2, paeth][f]) % 256)
        raw += bytes([f]) + out
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(name, "wb").write(data)

write("icon16.png", 16, 16, lambda y: y % 5)
