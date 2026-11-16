# shell: golden
# all: no
# The GL ES back end (src/render/gles/) on Mesa llvmpipe: its tests run on a real GL ES driver
# through the platform's EGL (libglvnd dispatching to Mesa, surfaceless, in this shell), and
# gles-play draws the render conformance scenes, each compared with its golden image.
zig build gles gles-play --summary all
out=zig-out/gles; rm -rf "$out"
zig-out/bin/gles-play "$out"
for s in rects clip; do
    python3 tools/golden/golden.py "$out/$s.png" "src/render/conformance/$s.png"
done
