# shell: golden
# all: no
# Render conformance scenes (src/render/conformance.zig) drawn by a real wgpu device on Mesa
# lavapipe and compared with their golden images.
zig build conformance-dump
out=zig-out/conformance; rm -rf "$out"
zig-out/bin/conformance-dump "$out"
for s in "$out"/*/; do
    n=$(basename "$s")
    python3 src/render/conformance/render.py "$s" "$s/frame.png"
    python3 tools/golden/golden.py "$s/frame.png" "src/render/conformance/$n.png"
done
