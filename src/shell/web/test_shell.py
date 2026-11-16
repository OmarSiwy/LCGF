#!/usr/bin/env python3
"""The web shell in a real browser (ci/jobs/shell-web.sh): index.html, the shell example, in
headless Chromium at 800 x 600.

    python3 src/shell/web/test_shell.py DIR

DIR is zig-out/web. Each check prints one line; exit status 1 if any failed.
"""
import base64
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "render" / "web"))
import browser  # noqa: E402
import golden  # noqa: E402  (tools/golden, on sys.path through browser)

failed = 0


def check(name, ok, detail=""):
    global failed
    failed += not ok
    print(f"{'ok  ' if ok else 'FAIL'} {name}{': ' + str(detail) if detail else ''}")


def state(page):
    """builds, resets, layers, exposure * 1000, panel colour, polls (main.zig)."""
    return page.eval("[0,1,2,3,4,5].map(i => window.lcgr.ui.exports.lcgr_example_state(i) >>> 0)")


def settle(page):
    """Waits until the page asks for no more frames (idle), then returns the frame count."""
    page.eval("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")
    for _ in range(100):
        before = page.eval("window.lcgr.page.frames")
        page.eval("new Promise(r => setTimeout(r, 100))")
        if page.eval("window.lcgr.page.frames") == before:
            return before
    raise browser.Error("the page never went idle")


def pixel(page, x, y):
    shot = page.send("Page.captureScreenshot", {"format": "png", "clip": {"x": x, "y": y, "width": 1, "height": 1, "scale": 1}})
    path = Path("zig-out/web-shell-pixel.png")
    path.write_bytes(base64.b64decode(shot["data"]))
    return golden.read_png(path)[2][:4]


def rgba(word):
    return bytes([word & 0xFF, (word >> 8) & 0xFF, (word >> 16) & 0xFF, word >> 24])


def attach(page):
    """C0474: the example runs on the canvas from animation frames, and goes idle."""
    page.wait("window.lcgr && window.lcgr.ui.exports.lcgr_example_state(0) > 0")
    frames = settle(page)
    builds, _, _, _, panel, polls = state(page)
    check("attach: frames ran and the example was built", frames > 0 and builds > 0, f"{frames} frames, {builds} builds, {polls} polls")
    check("attach: the sidebar shows the theme's panel colour", pixel(page, 80, 590) == rgba(panel), list(pixel(page, 80, 590)))
    check("attach: the custom viewport is left to the host (black)", pixel(page, 400, 300) == bytes([0, 0, 0, 255]))
    page.eval("new Promise(r => setTimeout(r, 500))")
    check("attach: idle, no animation frames", page.eval("window.lcgr.page.frames") == frames)


def main(argv):
    server = browser.Server(argv[1])
    b = browser.Browser()
    try:
        page = b.open(server.url + "index.html")
        page.metrics(800, 600)
        for test in (attach,):
            try:
                test(page)
            except browser.Error as e:
                check(test.__name__, False, e)
        errors = page.errors()
        check("no uncaught errors", not errors, errors)
    finally:
        b.close()
        server.close()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
