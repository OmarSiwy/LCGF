# shell: golden
# all: no
# The wgpu-native back end (src/render/wgpu/) on Mesa lavapipe, built against each supported
# wgpu-native major (-Dwgpu-native, archives in build.zig.zon, headers translated by build.zig).
# The tests draw and read pixels back; wgpu-play draws the render conformance scenes, without
# and with 4x multisampling, compared with their golden images.
for v in v27 v29; do
    zig build wgpu wgpu-play -Dwgpu-native=$v --summary all
    for samples in 1 4; do
        out=zig-out/wgpu/$v-x$samples; rm -rf "$out"
        zig-out/bin/wgpu-play "$out" "$samples"
        for n in rects clip text; do
            python3 tools/golden/golden.py "$out/$n.png" "src/render/conformance/$n.png"
        done
    done
done
