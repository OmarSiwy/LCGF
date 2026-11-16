# all: no
# The Gompute back end (src/render/gompute/) against the GPU golden images, as sw-golden checks
# the software back end: every render conformance scene and every draw-feature scene, dumped
# from src/, drawn by gompute-play and compared with tools/golden/golden.py at 0 bad pixels.
# Out of `all` because it fetches Gompute (lazy build.zig.zon dependency).
zig build conformance-dump gompute-play
out=zig-out/gompute; rm -rf "$out"
zig-out/bin/conformance-dump "$out/conformance"
for s in "$out"/conformance/*/; do
    n=$(basename "$s")
    zig-out/bin/gompute-play "$s" "$s/gompute.png"
    python3 tools/golden/golden.py "$s/gompute.png" "src/render/conformance/$n.png"
done
for ref in tools/drawgolden/ref/*.png; do
    scene=$(basename "$ref" .png)
    zig build draw-dump -- "$scene" "$PWD/$out/draw/$scene"
    zig-out/bin/gompute-play "$out/draw/$scene" "$out/draw/$scene/gompute.png" 0d0d0f
    python3 tools/golden/golden.py "$out/draw/$scene/gompute.png" "$ref"
done
