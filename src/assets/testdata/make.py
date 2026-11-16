"""Writes the PNG test images of src/assets (run from this directory: python3 make.py).

Python's zlib at level 9 compresses them, so the tests decode a second deflate encoder's
output, not only std's. Every image is filtered row by row with all five filter types.

For each `name.png` it also writes `name.rgba`: the pixels a decoder must produce, as
premultiplied RGBA8 rows, computed here from the source samples (16-bit samples rounded to 8,
low bit depths scaled with rounding, premultiplied with rounding). The Zig tests compare
against these, so a file is checked against its source, not against another decode.
"""
import struct, zlib

ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))


def pack_row(samples, depth):
    if depth == 16:
        return b"".join(struct.pack(">H", s) for s in samples)
    if depth == 8:
        return bytes(samples)
    out, acc, n = bytearray(), 0, 0
    for s in samples:
        acc = (acc << depth) | s
        n += depth
        if n == 8:
            out.append(acc)
            acc, n = 0, 0
    if n:
        out.append(acc << (8 - n))
    return bytes(out)


def filter_rows(rows, bpp, first_filter):
    out, prev = b"", None
    for k, line in enumerate(rows):
        prev = prev or bytes(len(line))
        f = (first_filter + k) % 5
        enc = bytearray()
        for i, c in enumerate(line):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            u = prev[i - bpp] if i >= bpp else 0
            p = a + b - u
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - u)
            paeth = a if pa <= pb and pa <= pc else (b if pb <= pc else u)
            enc.append((c - [0, a, b, (a + b) // 2, paeth][f]) % 256)
        out += bytes([f]) + enc
        prev = line
    return out


def to8(v, depth):
    m = (1 << depth) - 1
    return (v * 255 + m // 2) // m


def premul(r, g, b, a):
    return bytes([(r * a + 127) // 255, (g * a + 127) // 255, (b * a + 127) // 255, a])


def write(name, w, h, depth, color, sample, interlace=False, plte=None, trns=None):
    """`sample(x, y)` gives the pixel's samples at the file's bit depth."""
    ch = CHANNELS[color]
    bpp = max(1, ch * depth // 8)
    passes = ADAM7 if interlace else [(0, 0, 1, 1)]
    raw = b""
    for n, (x0, y0, dx, dy) in enumerate(passes):
        xs, ys = range(x0, w, dx), range(y0, h, dy)
        if not xs or not ys:
            continue
        rows = [pack_row([s for x in xs for s in sample(x, y)], depth) for y in ys]
        raw += filter_rows(rows, bpp, n)
    ihdr = struct.pack(">IIBBBBB", w, h, depth, color, 0, 0, int(interlace))
    body = chunk(b"IHDR", ihdr)
    if plte:
        body += chunk(b"PLTE", b"".join(bytes(e) for e in plte))
    if trns is not None:
        body += chunk(b"tRNS", trns)
    z = zlib.compress(raw, 9)
    # Image data split over two IDAT chunks.
    body += chunk(b"IDAT", z[: len(z) // 2]) + chunk(b"IDAT", z[len(z) // 2 :]) + chunk(b"IEND", b"")
    open(name + ".png", "wb").write(b"\x89PNG\r\n\x1a\n" + body)

    key = struct.unpack(">" + "H" * (len(trns) // 2), trns) if trns is not None and color in (0, 2) else None
    out = bytearray()
    for y in range(h):
        for x in range(w):
            s = sample(x, y)
            if color == 3:
                r, g, b = plte[s[0]] if s[0] < len(plte) else (0, 0, 0)
                a = (trns[s[0]] if trns is not None and s[0] < len(trns) else 255) if s[0] < len(plte) else 0
                out += premul(r, g, b, a)
                continue
            v = [to8(c, depth) for c in s]
            if color == 0:
                out += premul(v[0], v[0], v[0], 0 if key and tuple(s) == key else 255)
            elif color == 4:
                out += premul(v[0], v[0], v[0], v[1])
            elif color == 2:
                out += premul(*v, 0 if key and tuple(s) == key else 255)
            else:
                out += premul(*v)
    open(name + ".rgba", "wb").write(bytes(out))


def icon(x, y):
    # A gradient with a checker of half-transparent cells.
    return (x * 255 // 15, y * 255 // 15, (x ^ y) * 16 % 256, 255 if (x // 4 + y // 4) % 2 == 0 else 128)


pal = [((i * 37) % 256, (i * 91) % 256, (i * 13) % 256) for i in range(200)]

write("icon16", 16, 16, 8, 6, icon)
write("rgba16_adam7", 11, 9, 16, 6, lambda x, y: (x * 6000, y * 7000, 65535 - x * y * 600, 30000 + x * 3000), True)
write("rgb8", 7, 5, 8, 2, lambda x, y: (x * 36, y * 50, 255 - x * y))
write("rgb16_trns", 6, 6, 16, 2, lambda x, y: (x * 9000, y * 9000, 1234), trns=struct.pack(">HHH", 9000, 18000, 1234))
write("gray1", 13, 7, 1, 0, lambda x, y: ((x + y) % 2,))
write("gray2_adam7", 10, 10, 2, 0, lambda x, y: ((x * y) % 4,), True)
write("gray4", 9, 4, 4, 0, lambda x, y: ((x + 3 * y) % 16,))
write("gray8_trns", 8, 8, 8, 0, lambda x, y: ((x * 32 + y) % 256,), trns=struct.pack(">H", 65))
write("gray16_adam7", 9, 7, 16, 0, lambda x, y: (x * 7000 + y * 100,), True)
write("ga8", 5, 5, 8, 4, lambda x, y: (x * 60, y * 60))
write("ga16", 4, 3, 16, 4, lambda x, y: (x * 20000, 65535 - y * 30000))
write("pal1", 12, 3, 1, 3, lambda x, y: ((x // 2 + y) % 2,), plte=pal[:2])
write("pal2", 7, 7, 2, 3, lambda x, y: ((x + y) % 4,), plte=pal[:3], trns=bytes([0, 200]))
write("pal4_adam7_trns", 13, 11, 4, 3, lambda x, y: ((x * 3 + y) % 16,), True, plte=pal[:14], trns=bytes([10, 20, 30]))
write("pal8", 16, 2, 8, 3, lambda x, y: ((x * 16 + y * 7) % 256,), plte=pal)
