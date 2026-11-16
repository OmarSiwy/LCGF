# shell: web
# all: no
# The web shell (src/shell/web/) on its platform: its unit tests (zig build test runs web.zig's,
# among them the example's input replay through the shell's calls), then the shell example
# (index.html, shell.wasm) in headless Chromium, driven by real DOM input through DevTools:
# the replay, keys, wheel, touch, cursors, clipboard, IME, devicePixelRatio 2, timers and wake
# on the 2D canvas, and the replay again with WebGPU (test_shell.py).
zig build test
zig build web
python3 src/shell/web/test_shell.py zig-out/web
