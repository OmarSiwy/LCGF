# shell: golden
# all: no
# The wgpu-native back end (src/render/wgpu/) on Mesa lavapipe: wgpu-native v29 from
# build.zig.zon, its headers translated by build.zig. The tests draw and read pixels back;
# wgpu-play draws the render conformance scenes, without and with 4x multisampling, compared
# with their golden images.
zig build wgpu wgpu-play --summary all
for samples in 1 4; do
    out=zig-out/wgpu/x$samples; rm -rf "$out"
    zig-out/bin/wgpu-play "$out" "$samples"
    for n in rects clip text; do
        python3 tools/golden/golden.py "$out/$n.png" "src/render/conformance/$n.png"
    done
done
