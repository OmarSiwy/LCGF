#!/usr/bin/env python3
"""Runs web test pages in headless Chromium and reports their results (ci/jobs/web.sh).

    python3 src/render/web/browser.py [--out OUT] DIR PAGE [PAGE...]

Serves DIR (zig-out/web) over HTTP on a free local port, opens each PAGE in a real headless
Chromium with WebGPU enabled (SwiftShader's Vulkan, so no GPU is needed), and awaits the page's
`window.lcgrTest`: a promise of `{ok, ...}`. Prints each result as one JSON line; exit status 1
if any page failed, threw, logged an uncaught error, or did not finish in time. A result's
`images` ({name: {w, h, rgba: base64}}) are written as OUT/<page>/<name>.png (with --out) and
left out of the printed line.

Talks to Chromium over the DevTools protocol on a pipe (--remote-debugging-pipe: NUL-separated
JSON on fds 3 and 4), so it needs only the standard library. Other tests import `Browser` to
drive input (`Page.send("Input.dispatchMouseEvent", ...)`) or read state (`Page.eval`).
"""
import base64
import functools
import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tools" / "golden"))
from golden import write_png  # noqa: E402

FLAGS = [
    "--headless=new", "--no-sandbox", "--no-first-run", "--disable-gpu-sandbox",
    "--enable-unsafe-webgpu", "--enable-features=Vulkan", "--force-device-scale-factor=1",
    "--window-size=800,600", "--hide-scrollbars", "--mute-audio",
]


class Error(Exception):
    pass


class Server:
    """DIR over HTTP on 127.0.0.1, in a thread."""

    def __init__(self, root):
        handler = functools.partial(Quiet, directory=root)
        handler.extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                                  ".wasm": "application/wasm", ".js": "text/javascript"}
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}/"

    def close(self):
        self.httpd.shutdown()


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


class Browser:
    def __init__(self, extra_flags=(), webgpu=True):
        """`webgpu=False` leaves out --enable-unsafe-webgpu: Linux Chromium then gives no adapter."""
        exe = shutil.which("chromium") or shutil.which("chromium-browser") or shutil.which("google-chrome")
        if not exe:
            raise Error("no chromium on PATH (nix develop .#web)")
        self.profile = tempfile.mkdtemp(prefix="lcgr-web-")
        to_chrome, self._w = os.pipe()
        self._r, from_chrome = os.pipe()

        def fds():
            os.dup2(to_chrome, 3)
            os.dup2(from_chrome, 4)

        self.proc = subprocess.Popen(
            [exe, *(f for f in FLAGS if webgpu or f != "--enable-unsafe-webgpu"), *extra_flags, "--remote-debugging-pipe", f"--user-data-dir={self.profile}", "about:blank"],
            pass_fds=(3, 4), preexec_fn=fds, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.close(to_chrome)
        os.close(from_chrome)
        self._out = os.fdopen(self._w, "wb")
        self._in = os.fdopen(self._r, "rb")
        self._buf = b""
        self._id = 0
        self.events = []  # protocol events received while waiting for replies

    def send(self, method, params=None, session=None, timeout=30):
        self._id += 1
        msg = {"id": self._id, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        self._out.write(json.dumps(msg).encode() + b"\0")
        self._out.flush()
        deadline = time.monotonic() + timeout
        while True:
            reply = self._read(deadline)
            if reply.get("id") == self._id:
                if "error" in reply:
                    raise Error(f"{method}: {reply['error']}")
                return reply.get("result", {})
            self.events.append(reply)

    def _read(self, deadline):
        while b"\0" not in self._buf:
            if time.monotonic() > deadline:
                raise Error("timed out waiting for Chromium")
            chunk = self._in.read1(1 << 16)
            if not chunk:
                raise Error("Chromium closed the pipe")
            self._buf += chunk
        msg, self._buf = self._buf.split(b"\0", 1)
        return json.loads(msg)

    def open(self, url):
        target = self.send("Target.createTarget", {"url": "about:blank"})["targetId"]
        session = self.send("Target.attachToTarget", {"targetId": target, "flatten": True})["sessionId"]
        page = Page(self, session)
        page.send("Runtime.enable")
        page.send("Page.enable")
        page.send("Page.navigate", {"url": url})
        return page

    def close(self):
        try:
            self.send("Browser.close", timeout=5)
        except Error:
            pass
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        shutil.rmtree(self.profile, ignore_errors=True)


class Page:
    def __init__(self, browser, session):
        self.browser = browser
        self.session = session

    def send(self, method, params=None, timeout=30):
        return self.browser.send(method, params, self.session, timeout)

    def eval(self, expr, timeout=30):
        """The value of `expr` (awaited if a promise), as JSON-compatible data."""
        r = self.send("Runtime.evaluate", {"expression": expr, "awaitPromise": True, "returnByValue": True}, timeout)
        if "exceptionDetails" in r:
            d = r["exceptionDetails"]
            raise Error(d.get("exception", {}).get("description") or d.get("text"))
        return r["result"].get("value")

    def wait(self, expr, timeout=30):
        """Polls until `expr` is truthy; returns its value."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            v = self.eval(expr)
            if v:
                return v
            time.sleep(0.05)
        raise Error(f"timed out waiting for {expr}")

    def errors(self):
        """Uncaught exceptions and console errors the page reported so far."""
        out = []
        for e in self.browser.events:
            if e.get("sessionId") != self.session:
                continue
            p = e.get("params", {})
            if e.get("method") == "Runtime.exceptionThrown":
                d = p["exceptionDetails"]
                out.append(d.get("exception", {}).get("description") or d.get("text"))
            elif e.get("method") == "Runtime.consoleAPICalled" and p.get("type") == "error":
                out.append(" ".join(str(a.get("value", a.get("description"))) for a in p.get("args", [])))
        return out

    def result(self, timeout=60):
        """Awaits `window.lcgrTest`; adds any uncaught errors to the result."""
        self.wait("window.lcgrTest !== undefined", timeout)
        r = self.eval("window.lcgrTest", timeout)
        errs = self.errors()
        if errs:
            r = {**(r or {}), "ok": False, "errors": errs}
        return r


def main(argv):
    out = None
    if len(argv) > 2 and argv[1] == "--out":
        out = Path(argv[2])
        argv = argv[:1] + argv[3:]
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    server = Server(argv[1])
    browser = Browser()
    failed = 0
    try:
        version = browser.send("Browser.getVersion")["product"]
        for name in argv[2:]:
            try:
                r = browser.open(server.url + name).result()
            except Error as e:
                r = {"ok": False, "errors": [str(e)]}
            images = r.pop("images", None) or {}
            for img, v in images.items():
                if out:
                    d = out / Path(name).stem
                    d.mkdir(parents=True, exist_ok=True)
                    write_png(d / f"{img}.png", v["w"], v["h"], base64.b64decode(v["rgba"]))
            print(json.dumps({"page": name, "browser": version, **r, "images": sorted(images)}))
            failed += not r.get("ok")
    finally:
        browser.close()
        server.close()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
