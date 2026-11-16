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


def frame(page):
    """Waits until the animation frame the last event asked for has run."""
    page.eval("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")


def mouse(page, kind, x, y, pressed=False, **extra):
    page.send("Input.dispatchMouseEvent", {"type": kind, "x": x, "y": y, "button": "left" if kind != "mouseMoved" else "none",
                                           "buttons": int(pressed), "clickCount": 1 if kind != "mouseMoved" else 0, **extra})


def replay(page):
    """C0475: src/shell/testdata/example.replay played as real DOM mouse events; the example
    ends where the headless shell's replay ends."""
    recording = (Path(__file__).resolve().parents[1] / "testdata" / "example.replay").read_text()
    frames = [[l.split() for l in block.splitlines() if l.strip() and not l.startswith("#")] for block in recording.split("frame\n")[1:]]
    pointer, left = (-1, -1), False
    for lines in frames:
        for words in lines:
            if words[0] == "pointer":
                pointer = (float(words[1]), float(words[2]))
                mouse(page, "mouseMoved", *pointer, left)
            elif words[0] == "buttons":
                down = "left" in words
                if down != left:
                    left = down
                    mouse(page, "mousePressed" if down else "mouseReleased", *pointer, down)
        frame(page)
    settle(page)
    builds, resets, layers, exposure, _, _ = state(page)
    check("replay: one reset, four layers, exposure 3, as headless", (resets, layers, round(exposure / 10)) == (1, 4, 300), f"resets {resets}, layers {layers}, exposure {exposure / 1000}, {builds} builds")


def seen(page):
    """presses, releases, last code, last mods, text length, wheel y, scroll y (x1000),
    contacts, contact x (x1000), keys held; and the text typed (main.zig `lcgr_seen`)."""
    v = page.eval("[...Array(10).keys()].map(i => window.lcgr.ui.exports.lcgr_seen(i))")
    text = bytes(page.eval(f"[...Array({v[4]}).keys()].map(i => window.lcgr.ui.exports.lcgr_seen(100 + i))")).decode()
    return v, text


def keys(page):
    """C0475: key events carry USB HID codes and modifiers; printable keys are typed text."""
    mouse(page, "mousePressed", 400, 300, True)  # focus the canvas
    mouse(page, "mouseReleased", 400, 300)
    for kind in ("keyDown", "keyUp"):
        page.send("Input.dispatchKeyEvent", {"type": kind, "key": "a", "code": "KeyA", "text": "a" if kind == "keyDown" else "", "windowsVirtualKeyCode": 65})
    page.send("Input.dispatchKeyEvent", {"type": "rawKeyDown", "key": "Control", "code": "ControlLeft", "modifiers": 2, "windowsVirtualKeyCode": 17})
    page.send("Input.dispatchKeyEvent", {"type": "rawKeyDown", "key": "c", "code": "KeyC", "modifiers": 2, "windowsVirtualKeyCode": 67})
    frame(page)
    v, text = seen(page)
    check("keys: KeyA is HID 0x04, typed as \"a\"; Ctrl+C is 0x06 with ctrl, not typed", text == "a" and v[2] == 0x06 and v[3] == 2 and v[0] >= 3,
          f"text {text!r}, last code {v[2]:#x}, mods {v[3]}, presses {v[0]}")
    check("keys: Control and C held", v[9] == 2, f"{v[9]} held")
    page.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": "c", "code": "KeyC", "modifiers": 2, "windowsVirtualKeyCode": 67})
    page.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Control", "code": "ControlLeft", "windowsVirtualKeyCode": 17})
    frame(page)
    check("keys: released", seen(page)[0][9] == 0)


def wheel(page):
    """C0475: a mouse wheel notch (Chromium: 100 px down) scrolls up by -100 px in the core's sign."""
    before = seen(page)[0][6]
    mouse(page, "mouseWheel", 400, 300, deltaX=0, deltaY=100)
    frame(page)
    after = seen(page)[0][6]
    check("wheel: deltaY 100 px is scroll -100", after - before == -100_000, (after - before) / 1000)


def touch(page):
    """C0475: a finger is a contact while down, gone after it lifts; the mouse pointer is untouched."""
    page.send("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [{"x": 300, "y": 200, "id": 1}]})
    frame(page)
    v = seen(page)[0]
    check("touch: one contact at x 300", v[7] == 1 and v[8] == 300_000, f"{v[7]} contacts, x {v[8] / 1000}")
    page.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})
    frame(page)  # reported once more with down = false; the shell asks for the next frame
    frame(page)
    check("touch: lifted", seen(page)[0][7] == 0)


def main(argv):
    server = browser.Server(argv[1])
    b = browser.Browser()
    try:
        # Each group on a fresh page, so the replay starts from the example's first frame.
        for tests in ((attach,), (replay, keys, wheel, touch)):
            page = b.open(server.url + "index.html")
            page.metrics(800, 600)
            for test in tests:
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
