# shell: web
# all: no
# The web back end (src/render/web/) in a real browser: `zig build web` builds the wasm32
# examples into zig-out/web/ with their JavaScript, and browser.py opens each test page in
# headless Chromium (WebGPU on SwiftShader) and fails on any page that does not report ok.
# Pages that draw the render conformance scenes read them back; each image is compared with its
# golden at 0 bad pixels.
zig build web
out=zig-out/web-out; rm -rf "$out"
pages="test_glue test_webgpu"
python3 src/render/web/browser.py --out "$out" zig-out/web $(for p in $pages; do echo "$p.html"; done)
for p in $pages; do
    [ -d "$out/$p" ] || continue
    for ref in src/render/conformance/*.png; do
        python3 tools/golden/golden.py "$out/$p/$(basename "$ref")" "$ref"
    done
done
