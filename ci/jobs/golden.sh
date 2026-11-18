# shell: golden
# all: no
# Golden images and the GPU pixel check (tools/golden/), on Mesa lavapipe.
# Draw the production toolbar and custom viewport, then check its reference pixels.
python3 tools/golden/golden.py --self-test
zig build golden-dump
out=zig-out/golden; mkdir -p "$out"
zig-out/bin/golden-dump 3>"$out/quad.wgsl" 4>"$out/quads.bin" 5>"$out/glyphs.bin" 6>"$out/cmds.txt"
python3 tools/golden/gpu.py "$out" "$out/frame.png"
python3 tools/golden/golden.py "$out/frame.png" tools/golden/reference.png
