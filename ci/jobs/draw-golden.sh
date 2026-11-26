# shell: golden
# all: no
# Golden images of the draw features (tools/golden/): every scene is dumped from src/, drawn
# by tools/golden/gpu.py on Mesa lavapipe and compared with tools/golden/ref/draw/<scene>.png.
for ref in tools/golden/ref/draw/*.png; do
    scene=$(basename "$ref" .png)
    out=zig-out/drawgolden/$scene
    zig build draw-dump -- "$scene" "$PWD/$out"
    python3 tools/golden/gpu.py "$out" "$out/frame.png"
    python3 tools/golden/golden.py "$out/frame.png" "$ref"
done
