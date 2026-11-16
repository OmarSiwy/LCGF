# shell: golden
# all: no
# The wgpu-native back end (src/render/wgpu/) on Mesa lavapipe: wgpu-native v29 from
# build.zig.zon, its headers translated by build.zig. The tests draw and read pixels back;
# wgpu-play draws the render conformance scenes, compared with their golden images.
zig build wgpu wgpu-play --summary all
out=zig-out/wgpu; rm -rf "$out"
zig-out/bin/wgpu-play "$out"
for n in rects clip; do
    python3 tools/golden/golden.py "$out/$n.png" "src/render/conformance/$n.png"
done
