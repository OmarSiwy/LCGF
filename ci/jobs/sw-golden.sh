# The software renderer (src/render/sw) against the GPU golden images: every render conformance
# scene and every draw-feature scene, dumped from src/, drawn by sw-play and compared with
# tools/golden/golden.py at 0 bad pixels. No GPU needed. quad.wgsl makes its discrete decisions
# (nearest texel, border side, dash period) from pixel centres and per-instance data only, so
# ties fall the same way on every GPU and here.
zig build conformance-dump sw-play
out=zig-out/sw; rm -rf "$out"
zig-out/bin/conformance-dump "$out/conformance"
for s in "$out"/conformance/*/; do
    n=$(basename "$s")
    zig-out/bin/sw-play "$s" "$s/sw.png"
    python3 tools/golden/golden.py "$s/sw.png" "src/render/conformance/$n.png"
done
for ref in tools/golden/ref/draw/*.png; do
    scene=$(basename "$ref" .png)
    zig build draw-dump -- "$scene" "$PWD/$out/draw/$scene"
    zig-out/bin/sw-play "$out/draw/$scene" "$out/draw/$scene/sw.png" 0d0d0f
    python3 tools/golden/golden.py "$out/draw/$scene/sw.png" "$ref"
done
