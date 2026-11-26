# shell: golden
# all: no
# The GL ES back end (src/render/gles/) on Mesa llvmpipe: its tests run on a real GL ES driver
# through the platform's EGL (libglvnd dispatching to Mesa, surfaceless, in this shell), and
# gles-play draws the render conformance scenes with the instanced GL ES 3 renderer and the
# GL ES 2 path, each compared with its golden image. `custom` is drawn between the UI's draws,
# through lcgf_render.gpu on GL ES 3 (src/render/gpu/gradient.zig) and by the host's own program
# on GL ES 2 (custom.zig).
golden_build gles gles-play --summary all
for mode in es3 es2; do
    out=zig-out/gles/$mode; rm -rf "$out"
    zig-out/bin/gles-play "$out" "$mode"
    for s in rects clip text custom; do
        python3 tools/golden/golden.py "$out/$s.png" "src/render/conformance/$s.png"
    done
    if [ "$mode" = es3 ]; then python3 tools/golden/golden.py "$out/canvas.png" tools/golden/ref/draw/canvas.png; fi
done
