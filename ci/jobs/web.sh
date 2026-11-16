# shell: web
# all: no
# The web back end (src/render/web/) in a real browser: `zig build web` builds the wasm32
# examples into zig-out/web/ with their JavaScript, and browser.py opens each test page in
# headless Chromium (WebGPU on SwiftShader) and fails on any page that does not report ok.
zig build web
python3 src/render/web/browser.py zig-out/web test_glue.html
