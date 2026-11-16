"""TinyVG test icons for the golden images: each is described once below, then encoded to a .tvg
file by `encode` (written from the TinyVG 1.0 specification) and turned into reference shapes by
`shapes` (from the same description, never from the bytes), so the Zig decoder is checked
against an encoder and a renderer it shares no code with.

Arcs follow the reference SDK's renderer (github.com/TinyVG/sdk, src/lib/rendering.zig,
renderCircle and renderEllipse), which DVUI draws TinyVG icons with; `arc_points` evaluates them
densely. Gradients draw in their first colour, line widths are at least 1 px, lines have round
caps and joins, fills are even-odd and rectangles their union, as src/draw/tinyvg.zig documents.
"""
import math
import struct

# A path is a list of segments (start, [instruction]); instructions:
#   ("L", x, y) ("H", x) ("V", y) ("C", c0x, c0y, c1x, c1y, x, y) ("Q", cx, cy, x, y)
#   ("A", large, sweep, r, x, y) ("E", large, sweep, rx, ry, rotation, x, y) ("Z",)
# An instruction may end with ("w", width): a line width change (encoded, not drawn).
# A style is ("flat", index) or ("linear" | "radial", (x0, y0), (x1, y1), index0, index1).
ICONS = {
    # 16-bit units with 4 fraction bits, RGBA 8888: every command.
    "icon_all": dict(size=(24, 24), scale=4, range=0, encoding=0, colors=[
        (255, 255, 255, 255), (255, 128, 64, 255), (96, 192, 255, 200), (64, 255, 128, 255),
        (255, 64, 96, 255), (40, 40, 48, 255), (255, 208, 64, 255)], cmds=[
        ("fill_polygon", ("flat", 1), [(4, 1.5), (6.375, 8.75), (0.5, 4.25), (7.5, 4.25), (1.625, 8.75)]),
        ("fill_rects", ("flat", 2), [(9, 1, 5, 3.5), (11.25, 2.5, 3.5, 5)]),
        ("fill_path", ("linear", (16, 1), (23, 9), 3, 4), [
            ((16, 1), [("L", 23, 1), ("V", 8.5), ("A", 0, 1, 5, 16, 8.5), ("Z",)]),
            ((18, 3), [("H", 21), ("Q", 21, 6, 18, 6), ("Z",)])]),
        ("draw_lines", ("flat", 0), 0.75, [((1, 11), (7, 12)), ((1, 13.5), (7, 13.5)), ((2, 15), (2, 15.25))]),
        ("draw_line_loop", ("flat", 3), 1.25, [(9.5, 11), (14, 11.5), (12, 15.5)]),
        ("draw_line_strip", ("flat", 6), 0.25, [(16, 15), (18, 11), (20, 15), (22.5, 11)]),
        ("draw_line_path", ("flat", 4), 1.5, [
            ((1.5, 22.5), [("C", 2, 17, 6, 22, 7, 17.5), ("E", 1, 0, 3, 2, 30, 4, 21, ("w", 3))])]),
        ("outline_polygon", ("flat", 5), ("flat", 0), 0.5, [(9, 18), (14.5, 17.5), (13, 22.5), (9.5, 22)]),
        ("outline_rects", ("flat", 1), ("flat", 3), 1, [(16.5, 17.5, 2.5, 2.5), (20, 19.5, 2.5, 3)]),
        ("text_hint", (12, 12), 0, 2, "hi", [(0, 1), (1, 2)]),
        ("outline_path", ("radial", (12, 12), (14, 12), 6, 1), ("flat", 2), 0.75, [
            ((9.5, 6), [("A", 1, 0, 2, 12.5, 6), ("A", 0, 1, 2.5, 9.5, 6), ("Z",)])]),
    ]),
    # 8-bit units with 2 fraction bits, RGB 565.
    "icon_565": dict(size=(16, 16), scale=2, range=1, encoding=1, colors=[
        (31, 63, 31), (31, 20, 4), (4, 40, 31)], cmds=[
        ("fill_path", ("flat", 1), [((2, 2), [("L", 14, 2), ("L", 14, 14), ("L", 2, 14), ("Z",)]),
                                    ((5, 5), [("A", 0, 0, 4, 11, 5), ("A", 1, 0, 4, 5, 5)])]),
        ("draw_line_strip", ("flat", 2), 1.5, [(1, 15), (8, 8.5), (15, 15)]),
        ("outline_polygon", ("flat", 0), ("flat", 2), 0.25, [(6.5, 6.5), (9.5, 6.5), (8, 10.25)]),
    ]),
    # 32-bit units with 8 fraction bits, RGBA F32 (one channel out of range, clamped).
    "icon_f32": dict(size=(16, 16), scale=8, range=2, encoding=2, colors=[
        (1.0, 0.75, 0.25, 1.0), (0.2, 0.9, 1.5, 0.6)], cmds=[
        ("fill_polygon", ("flat", 0), [(8, 1), (15, 8), (8, 15), (1, 8)]),
        ("draw_line_path", ("flat", 1), 2, [((3, 8), [("E", 0, 1, 5, 2.5, -20, 13, 8), ("E", 0, 1, 5, 2.5, -20, 3, 8)])]),
    ]),
}

COMMANDS = {"fill_polygon": 1, "fill_rects": 2, "fill_path": 3, "draw_lines": 4, "draw_line_loop": 5,
            "draw_line_strip": 6, "draw_line_path": 7, "outline_polygon": 8, "outline_rects": 9,
            "outline_path": 10, "text_hint": 11}
STYLES = {"flat": 0, "linear": 1, "radial": 2}
INSTR = {"L": 0, "H": 1, "V": 2, "C": 3, "A": 4, "E": 5, "Z": 6, "Q": 7}


def varuint(v):
    out = b""
    while v >= 0x80:
        out += bytes([0x80 | (v & 0x7F)])
        v >>= 7
    return out + bytes([v])


def encode(icon):
    bits, nbytes = icon["scale"], {0: 2, 1: 1, 2: 4}[icon["range"]]
    fmt = {1: "<b", 2: "<h", 4: "<i"}[nbytes]

    def unit(v):
        q = v * (1 << bits)
        assert q == int(q), f"{v} is not a multiple of 2^-{bits}"
        return struct.pack(fmt, int(q))

    def point(p):
        return unit(p[0]) + unit(p[1])

    def style(s):
        if s[0] == "flat":
            return varuint(s[1])
        return point(s[1]) + point(s[2]) + varuint(s[3]) + varuint(s[4])

    def path(segs):
        out = b"".join(varuint(len(instrs) - 1) for _, instrs in segs)
        for start, instrs in segs:
            out += point(start)
            for ins in instrs:
                width = ins[-1][1] if isinstance(ins[-1], tuple) else None
                args = ins[1:-1] if width is not None else ins[1:]
                out += bytes([INSTR[ins[0]] | (0x10 if width is not None else 0)])
                if width is not None:
                    out += unit(width)
                if ins[0] in "AE":
                    out += bytes([args[0] | (args[1] << 1)])
                    args = args[2:]
                out += b"".join(unit(v) for v in args)
        return out

    w, h = icon["size"]
    out = bytes([0x72, 0x56, 1, bits | (icon["encoding"] << 4) | (icon["range"] << 6)])
    out += struct.pack("<" + {1: "B", 2: "H", 4: "I"}[nbytes] * 2, w, h)
    out += varuint(len(icon["colors"]))
    for c in icon["colors"]:
        if icon["encoding"] == 0:
            out += bytes(c)
        elif icon["encoding"] == 1:
            out += struct.pack("<H", c[0] | (c[1] << 5) | (c[2] << 11))
        else:
            out += struct.pack("<4f", *c)
    for cmd in icon["cmds"]:
        op = cmd[0]
        if op == "text_hint":
            _, center, rot, height, text, glyphs = cmd
            out += bytes([11]) + point(center) + unit(rot) + unit(height)
            out += varuint(len(text)) + text.encode() + varuint(len(glyphs))
            out += b"".join(unit(a) + unit(b) for a, b in glyphs)
            continue
        if op.startswith("outline"):
            _, fill, line, width, items = cmd
            out += bytes([COMMANDS[op] | (STYLES[fill[0]] << 6)])
            out += bytes([(len(items) - 1) | (STYLES[line[0]] << 6)])
            out += style(fill) + style(line) + unit(width)
        elif op.startswith("fill"):
            _, fill, items = cmd
            out += bytes([COMMANDS[op] | (STYLES[fill[0]] << 6)]) + varuint(len(items) - 1) + style(fill)
        else:
            _, line, width, items = cmd
            out += bytes([COMMANDS[op] | (STYLES[line[0]] << 6)]) + varuint(len(items) - 1) + style(line) + unit(width)
        if op.endswith("path"):
            out += path(items)
        elif op.endswith("rects"):
            out += b"".join(unit(x) + unit(y) + unit(rw) + unit(rh) for x, y, rw, rh in items)
        elif op == "draw_lines":
            out += b"".join(point(a) + point(b) for a, b in items)
        else:
            out += b"".join(point(p) for p in items)
    return out + b"\x00"


def color(icon, index):
    c = icon["colors"][index]
    if icon["encoding"] == 0:
        return bytes(c)
    if icon["encoding"] == 1:
        e = lambda v, m: (v * 255 + m // 2) // m  # noqa: E731
        return bytes([e(c[0], 31), e(c[1], 63), e(c[2], 31), 255])
    return bytes(round(min(max(v, 0.0), 1.0) * 255) for v in c)


def rot(a, p):
    return (p[0] * math.cos(a) - p[1] * math.sin(a), p[0] * math.sin(a) + p[1] * math.cos(a))


def circle_points(p0, p1, r, large, left, steps=1024):
    """renderCircle of the SDK, at `steps` points: the arc from p0 to p1, p1 included."""
    left_side = (left and large) or (not left and not large)
    delta = ((p1[0] - p0[0]) / 2, (p1[1] - p0[1]) / 2)
    mid = (p0[0] + delta[0], p0[1] + delta[1])
    rv = (-delta[1], delta[0]) if left_side else (delta[1], -delta[0])
    len2 = rv[0] ** 2 + rv[1] ** 2
    if len2 - 0.03 > r * r or r < 0:
        r = math.sqrt(len2)
    k = math.sqrt(max(0.0, r * r / len2 - 1))
    center = (mid[0] + rv[0] * k, mid[1] + rv[1] * k)
    angle = math.asin(min(max(math.sqrt(len2) / r, -1.0), 1.0)) * 2
    arc = 2 * math.pi - angle if large else angle
    pos = (p0[0] - center[0], p0[1] - center[1])
    out = []
    for i in range(1, steps):
        q = rot(i * (-arc if left else arc) / steps, pos)
        out.append((q[0] + center[0], q[1] + center[1]))
    return out + [p1]


def arc_points(p0, p1, rx, ry, rotation, large, left):
    """renderEllipse of the SDK: to a circle, renderCircle, and back."""
    if abs(p0[0] - p1[0]) < 1e-5 and abs(p0[1] - p1[1]) < 1e-5:
        return []
    radius_min = math.hypot(p1[0] - p0[0], p1[1] - p0[1]) / 2
    radius_lim = math.hypot(rx, ry)
    up = radius_min / radius_lim if radius_lim < radius_min else 1.0
    ratio = rx / ry
    a = math.radians(-rotation)
    c, s = math.cos(a), math.sin(a)
    to = lambda p: ((c * p[0] - s * p[1]) / up, (s * p[0] + c * p[1]) / up * ratio)  # noqa: E731
    back = lambda p: ((c * p[0] + s * p[1] / ratio) * up, (-s * p[0] + c * p[1] / ratio) * up)  # noqa: E731
    return [back(q) for q in circle_points(to(p0), to(p1), rx * up, large, left)]


def shapes(name, ox, oy, scale):
    """The icon as the shapes of make.py: fills and round strokes in px."""
    icon = ICONS[name]
    px = lambda p: (p[0] * scale + ox, p[1] * scale + oy)  # noqa: E731

    def poly(pts, close):
        ops = [("M", list(px(pts[0])))] + [("L", list(px(p))) for p in pts[1:]]
        return ops + ([("Z", [])] if close else [])

    def path(segs):
        ops = []
        for start, instrs in segs:
            cur = start
            ops.append(("M", list(px(cur))))
            for ins in instrs:
                args = [v for v in ins[1:] if not isinstance(v, tuple)]
                k = ins[0]
                if k == "L":
                    cur = (args[0], args[1])
                elif k == "H":
                    cur = (args[0], cur[1])
                elif k == "V":
                    cur = (cur[0], args[0])
                if k in "LHV":
                    ops.append(("L", list(px(cur))))
                elif k == "C":
                    ops.append(("C", [v for p in zip(args[0::2], args[1::2]) for v in px(p)]))
                    cur = (args[4], args[5])
                elif k == "Q":
                    ops.append(("Q", [v for p in zip(args[0::2], args[1::2]) for v in px(p)]))
                    cur = (args[2], args[3])
                elif k in "AE":
                    if k == "A":
                        large, left, rx, to = args[0], args[1], args[2], (args[3], args[4])
                        ry, rotation = rx, 0
                    else:
                        large, left, rx, ry, rotation, to = args[0], args[1], args[2], args[3], args[4], (args[5], args[6])
                    for p in arc_points(px(cur), px(to), rx * scale, ry * scale, rotation, bool(large), bool(left)):
                        ops.append(("L", list(p)))
                    cur = to
                elif k == "Z":
                    ops.append(("Z", []))
                    cur = start
        return ops

    def stroke(col, width, ops):
        return {"kind": "stroke", "width": max(width * scale, 1.0), "join": "round", "cap": "round",
                "limit": 4.0, "color": color(icon, col[3] if col[0] != "flat" else col[1]), "path": ops}

    def fill(col, rule, ops):
        return {"kind": "fill", "rule": rule, "color": color(icon, col[3] if col[0] != "flat" else col[1]), "path": ops}

    def rect_ops(rects):
        return [op for x, y, w, h in rects for op in poly([(x, y), (x + w, y), (x + w, y + h), (x, y + h)], True)]

    out = []
    for cmd in icon["cmds"]:
        op = cmd[0]
        if op == "fill_polygon":
            out.append(fill(cmd[1], "even_odd", poly(cmd[2], True)))
        elif op == "fill_rects":
            out.append(fill(cmd[1], "nonzero", rect_ops(cmd[2])))
        elif op == "fill_path":
            out.append(fill(cmd[1], "even_odd", path(cmd[2])))
        elif op == "draw_lines":
            out.append(stroke(cmd[1], cmd[2], [o for a, b in cmd[3] for o in poly([a, b], False)]))
        elif op in ("draw_line_loop", "draw_line_strip"):
            out.append(stroke(cmd[1], cmd[2], poly(cmd[3], op == "draw_line_loop")))
        elif op == "draw_line_path":
            out.append(stroke(cmd[1], cmd[2], path(cmd[3])))
        elif op.startswith("outline"):
            _, f, line, width, items = cmd
            ops = poly(items, True) if op == "outline_polygon" else rect_ops(items) if op == "outline_rects" else path(items)
            out.append(fill(f, "nonzero" if op == "outline_rects" else "even_odd", ops))
            out.append(stroke(line, width, ops))
    return out
