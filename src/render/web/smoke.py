#!/usr/bin/env python3
"""Browser smoke test of the web back end (ci/jobs/web.sh): demo.html, the page a person would
open, in headless Chromium twice.

    python3 src/render/web/smoke.py DIR OUT

With WebGPU (SwiftShader): every scene runs 30 animation frames through WebGPU onto the page's
canvas without a WebGPU error. Without WebGPU (no adapter): the page falls back to the 2D canvas,
and a screenshot of the canvas, which is what the page shows, matches each scene's golden image
at 0 bad pixels. Screenshots are written to OUT/<backend>/<scene>.png.

The WebGPU run's pixels are not checked: headless Chromium here cannot back a WebGPU canvas
(its swap chain needs a shared image factory it does not have) and shows nothing, so the WebGPU
drawing itself is checked off screen by test_webgpu.html.
"""
import base64
import json
import sys
from pathlib import Path

import browser
import golden  # tools/golden, on sys.path through browser

SCENES = ["rects", "clip", "text", "custom"]  # src/render/conformance.zig order


def run(server, out, webgpu):
    b = browser.Browser(webgpu=webgpu)
    failed = 0
    try:
        for i, name in enumerate(SCENES):
            page = b.open(f"{server.url}demo.html?scene={i}&frames=30")
            r = page.result()
            want = "webgpu" if webgpu else "canvas2d"
            ok = r.get("ok") and r.get("backend") == want and r.get("frames") == 30
            line = {"scene": name, **r}
            if not webgpu:
                shot = page.send("Page.captureScreenshot", {"format": "png", "clip": {"x": 0, "y": 0, "width": 160, "height": 120, "scale": 1}})
                path = out / want / f"{name}.png"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(base64.b64decode(shot["data"]))
                ok = golden.compare(str(path), str(Path("src/render/conformance") / f"{name}.png"), 2, 0) and ok
            print(json.dumps(line))
            failed += not ok
    finally:
        b.close()
    return failed


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    server = browser.Server(argv[1])
    try:
        failed = run(server, Path(argv[2]), True) + run(server, Path(argv[2]), False)
    finally:
        server.close()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
