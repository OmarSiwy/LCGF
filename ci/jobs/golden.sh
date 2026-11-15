# shell: golden
# all: no
# Golden images and the GPU pixel check (tools/golden/), on Mesa lavapipe.
# The dumper is the prototype's today; point `dump` at the src/ one when it exists.
python3 tools/golden/golden.py --self-test
(cd prototype && zig build dump)
out=zig-out/golden; mkdir -p "$out"
prototype/zig-out/bin/dump 3>"$out/quad.wgsl" 4>"$out/quads.bin" 5>"$out/glyphs.bin" 6>"$out/cmds.txt"
python3 tools/golden/gpu.py "$out" "$out/frame.png"
python3 tools/golden/golden.py "$out/frame.png" prototype/wgpu-check.png
