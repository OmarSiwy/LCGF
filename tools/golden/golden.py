#!/usr/bin/env python3
"""Golden-image check: compare a rendered PNG against a checked-in reference.

    python3 tools/golden/golden.py actual.png reference.png [--tol 2] [--max-bad 0]
    python3 tools/golden/golden.py --self-test

Tolerance: a pixel is bad when any of its R, G, B, A channels differs from the reference by more
than --tol (default 2, the same bound as prototype/render.py). The images match when they have
the same size and at most --max-bad pixels are bad (default 0). Exit 0 on match, 1 on mismatch.

Standard library only (zlib). Reads 8-bit RGB or RGBA, non-interlaced PNGs, every filter type;
writes RGBA with filter 0.
"""
import struct
import sys
import tempfile
import zlib
from pathlib import Path

SIG = b"\x89PNG\r\n\x1a\n"


def write_png(path, w, h, rgba):
    """Write w*h*4 bytes of RGBA as a PNG."""
    assert len(rgba) == w * h * 4
    raw = b"".join(b"\x00" + rgba[y * w * 4:(y + 1) * w * 4] for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    Path(path).write_bytes(SIG + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def read_png(path):
    """Return (w, h, rgba bytes)."""
    data = Path(path).read_bytes()
    if data[:8] != SIG:
        raise ValueError(f"{path}: not a PNG")
    pos, idat, hdr = 8, [], None
    while pos < len(data):
        n, t = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if t == b"IHDR":
            hdr = struct.unpack(">IIBBBBB", body)
        elif t == b"IDAT":
            idat.append(body)
        elif t == b"IEND":
            break
    w, h, depth, color, _, _, interlace = hdr
    if depth != 8 or color not in (2, 6) or interlace:
        raise ValueError(f"{path}: only 8-bit RGB/RGBA non-interlaced PNGs are supported")
    bpp = 4 if color == 6 else 3
    stride = w * bpp
    raw = zlib.decompress(b"".join(idat))
    out = bytearray(h * stride)
    prev = bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out[y * stride:(y + 1) * stride] = line
        prev = line
    if bpp == 3:
        rgb, out = out, bytearray(w * h * 4)
        for i in range(w * h):
            out[i * 4:i * 4 + 3] = rgb[i * 3:i * 3 + 3]
            out[i * 4 + 3] = 255
    return w, h, bytes(out)


def compare(actual, reference, tol=2, max_bad=0):
    """Compare two PNG files. Print a one-line verdict; return True when they match."""
    aw, ah, a = read_png(actual)
    rw, rh, r = read_png(reference)
    if (aw, ah) != (rw, rh):
        print(f"FAIL {actual}: size {aw}x{ah}, reference {reference} is {rw}x{rh}")
        return False
    bad, first, worst = 0, None, 0
    for i in range(0, len(a), 4):
        d = max(abs(a[i + k] - r[i + k]) for k in range(4))
        if d > tol:
            bad += 1
            worst = max(worst, d)
            if first is None:
                first = (i // 4 % aw, i // 4 // aw, tuple(a[i:i + 4]), tuple(r[i:i + 4]))
    ok = bad <= max_bad
    msg = f"{'ok  ' if ok else 'FAIL'} {actual} vs {reference}: {bad} of {aw * ah} pixels off by more than {tol} (allowed {max_bad})"
    if first:
        msg += f"; worst {worst}, first at {first[:2]} got {first[2]} want {first[3]}"
    print(msg)
    return ok


def self_test():
    w, h = 7, 5
    img = bytearray((x * 37 + y * 11 + k * 5) & 255 for y in range(h) for x in range(w) for k in range(4))
    with tempfile.TemporaryDirectory() as d:
        ref, same, near, off, small = (f"{d}/{n}.png" for n in ("ref", "same", "near", "off", "small"))
        write_png(ref, w, h, bytes(img))
        assert read_png(ref) == (w, h, bytes(img))
        write_png(same, w, h, bytes(img))
        near_img = bytearray(img)
        near_img[0] ^= 1                        # within tolerance
        write_png(near, w, h, bytes(near_img))
        off_img = bytearray(img)
        off_img[(2 * w + 3) * 4 + 1] ^= 0x40    # one pixel, green channel, off by 64
        write_png(off, w, h, bytes(off_img))
        write_png(small, w - 1, h, bytes(img[:(w - 1) * h * 4]))
        assert compare(same, ref)
        assert compare(near, ref)
        assert not compare(off, ref), "a 64-level difference must fail"
        assert main([off, ref]) == 1, "a mismatch must exit non-zero"
        assert compare(off, ref, max_bad=1)
        assert not compare(small, ref), "a size difference must fail"
        # Every filter type and RGB input decode to the same pixels.
        stride = w * 3
        rgb = bytes(b for i in range(w * h) for b in img[i * 4:i * 4 + 3])
        raw, prev = b"", bytes(stride)
        for y in range(h):
            f, line = y % 5, rgb[y * stride:(y + 1) * stride]
            enc = bytearray(stride)
            for i in range(stride):
                a = line[i - 3] if i >= 3 else 0
                b, c = prev[i], prev[i - 3] if i >= 3 else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = [0, a, b, (a + b) // 2, a if pa <= pb and pa <= pc else b if pb <= pc else c][f]
                enc[i] = (line[i] - pred) & 255
            raw += bytes([f]) + enc
            prev = line
        hdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
        chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
        Path(f"{d}/rgb.png").write_bytes(SIG + chunk(b"IHDR", hdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
        opaque = bytes(255 if i % 4 == 3 else v for i, v in enumerate(img))
        assert read_png(f"{d}/rgb.png") == (w, h, opaque)
    print("golden self-test ok")


def main(argv):
    if argv == ["--self-test"]:
        self_test()
        return 0
    args, opts = [], {"--tol": 2, "--max-bad": 0}
    it = iter(argv)
    for a in it:
        if a in opts:
            opts[a] = int(next(it))
        else:
            args.append(a)
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    return 0 if compare(args[0], args[1], opts["--tol"], opts["--max-bad"]) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
