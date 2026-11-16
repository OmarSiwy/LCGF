# The software renderer (src/render/sw) against the GPU golden images: the render conformance
# and draw-feature scenes it draws so far, dumped from src/, drawn by sw-play and compared with
# tools/golden/golden.py. No GPU needed.
#
# Two draw-feature scenes allow a fixed number of bad pixels, all at exact ties of a
# discontinuous term of quad.wgsl, which the GPU decides by its interpolation rounding (either
# way, depending on position) and the software renderer by exact arithmetic:
#   images   2258: pixel centres exactly on a texel edge (u * 64 an integer) under nearest sampling
#   borders    29: pixel centres on a box diagonal, where `border_pattern` switches sides
zig build conformance-dump sw-play
out=zig-out/sw; rm -rf "$out"
zig-out/bin/conformance-dump "$out/conformance"
for n in rects custom clip text; do
    s=$out/conformance/$n
    zig-out/bin/sw-play "$s" "$s/sw.png"
    python3 tools/golden/golden.py "$s/sw.png" "src/render/conformance/$n.png"
done
for scene in corners borders images nine-slice; do
    ref=tools/drawgolden/ref/$scene.png
    case $scene in images) bad=2258 ;; borders) bad=29 ;; *) bad=0 ;; esac
    zig build draw-dump -- "$scene" "$PWD/$out/draw/$scene"
    zig-out/bin/sw-play "$out/draw/$scene" "$out/draw/$scene/sw.png" 0d0d0f
    python3 tools/golden/golden.py "$out/draw/$scene/sw.png" "$ref" --max-bad "$bad"
done
