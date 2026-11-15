"""Rebuilds the reference images of the path scenes (scenes.txt) as PNGs next to this file.

    python3 src/draw/testdata/paths/make.py

An independent reference for src/draw/paths.zig, written from the definitions rather than from
that code: curves are evaluated at 1024 steps (chords within 1e-4 px of the curve), and coverage
is the sampling paths.zig specifies, done directly: 16 sample lines per pixel row at y + (k + 0.5)
/ 16, on each line the exact x extent of the inside under the fill rule, averaged. Shapes are
composited in order over an opaque background, colour c with alpha a at coverage v:
out = c * a * v + out * (1 - a * v), per channel, in 0..255, rounded once at the end.

Standard library only; slow (pure Python), so CI compares against the checked-in PNGs instead of
running this.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "..", "tools", "golden"))
from golden import write_png  # noqa: E402

SUB = 16
STEPS = 1024
BG = (16, 16, 20)


def parse(text):
    """[(name, w, h, [shape])]; a shape is a dict with its kind and polygons or strokes."""
    scenes = []
    for line in text.splitlines():
        t = line.split("#")[0].split()
        if not t:
            continue
        op, a = t[0], t[1:]
        if op == "scene":
            scenes.append((a[0], int(a[1]), int(a[2]), []))
        elif op == "fill":
            scenes[-1][3].append({"kind": "fill", "rule": a[0], "color": bytes.fromhex(a[1]), "path": []})
        else:
            scenes[-1][3][-1]["path"].append((op, [float(v) for v in a]))
    return scenes


def contours(path):
    """Path verbs to polylines [(points, closed)], curves evaluated at STEPS steps."""
    out, cur, start = [], None, (0.0, 0.0)
    for op, v in path:
        if op == "M":
            cur = [(v[0], v[1])]
            start = cur[0]
            out.append([cur, False])
            continue
        if cur is None or out[-1][1]:  # drawing after a close continues from the start
            cur = [start]
            out.append([cur, False])
        p0 = cur[-1]
        if op == "L":
            cur.append((v[0], v[1]))
        elif op == "Q":
            for k in range(1, STEPS + 1):
                t = k / STEPS
                s = 1 - t
                cur.append((s * s * p0[0] + 2 * s * t * v[0] + t * t * v[2], s * s * p0[1] + 2 * s * t * v[1] + t * t * v[3]))
        elif op == "C":
            for k in range(1, STEPS + 1):
                t = k / STEPS
                s = 1 - t
                b = (s * s * s, 3 * s * s * t, 3 * s * t * t, t * t * t)
                cur.append((b[0] * p0[0] + b[1] * v[0] + b[2] * v[2] + b[3] * v[4],
                            b[0] * p0[1] + b[1] * v[1] + b[2] * v[3] + b[3] * v[5]))
        elif op == "Z":
            out[-1][1] = True
    return [(c, closed) for c, closed in out]


def fill_spans(polys, rule):
    """A function from a sample line's y to its inside spans [(x0, x1)]."""
    edges = []
    for pts, _ in polys:
        for i in range(len(pts)):
            edges.append((pts[i], pts[(i + 1) % len(pts)]))

    def spans(y):
        xs = []
        for (x0, y0), (x1, y1) in edges:
            if (y0 <= y) != (y1 <= y):
                xs.append((x0 + (y - y0) * (x1 - x0) / (y1 - y0), 1 if y1 > y0 else -1))
        xs.sort()
        out, wind, start = [], 0, None
        for x, d in xs:
            was = wind != 0 if rule == "nonzero" else wind % 2 == 1
            wind += d
            now = wind != 0 if rule == "nonzero" else wind % 2 == 1
            if now and not was:
                start = x
            elif was and not now:
                out.append((start, x))
        return out
    return spans


def coverage(w, h, spans):
    """Coverage in 0..1 per pixel, row-major."""
    cov = [0.0] * (w * h)
    for row in range(h):
        for s in range(SUB):
            for a, b in spans(row + (s + 0.5) / SUB):
                a, b = max(a, 0.0), min(b, float(w))
                if a >= b:
                    continue
                for c in range(int(a), min(int(b) + 1, w)):
                    cov[row * w + c] += (min(b, c + 1) - max(a, c)) / SUB
    return cov


def render(w, h, shapes):
    img = [list(BG) for _ in range(w * h)]
    for sh in shapes:
        spans = fill_spans(contours(sh["path"]), sh["rule"])
        col = sh["color"]
        for i, v in enumerate(coverage(w, h, spans)):
            a = col[3] / 255 * min(v, 1.0)
            img[i] = [col[k] * a + img[i][k] * (1 - a) for k in range(3)]
    return bytes(b for px in img for b in (round(px[0]), round(px[1]), round(px[2]), 255))


def main():
    with open(os.path.join(HERE, "scenes.txt")) as f:
        scenes = parse(f.read())
    for name, w, h, shapes in scenes:
        write_png(os.path.join(HERE, name + ".png"), w, h, render(w, h, shapes))
        print("wrote", name + ".png")


if __name__ == "__main__":
    main()
