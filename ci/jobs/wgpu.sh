# shell: golden
# all: no
# The wgpu-native back end (src/render/wgpu/) on Mesa lavapipe, built against each supported
# wgpu-native major (-Dwgpu-native, archives in build.zig.zon, headers translated by build.zig).
# The tests draw and read pixels back; wgpu-play draws every render conformance scene (custom
# commands by the host's own pipeline), without and with 4x multisampling, compared with its
# golden image; and the canvas scene, compared with sw's golden of it.
for v in v27 v29; do
    golden_build wgpu wgpu-play -Dwgpu-native=$v --summary all
    for samples in 1 4; do
        out=zig-out/wgpu/$v-x$samples; rm -rf "$out"
        zig-out/bin/wgpu-play "$out" "$samples"
        for ref in src/render/conformance/*.png; do
            # At 4x, lavapipe's scissor lets half of the samples above and left of the custom
            # draw's rectangle through (tools/golden/golden.py, --scissor-ring).
            ring=""
            if [ "$samples" -gt 1 ] && [ "$(basename "$ref")" = custom.png ]; then ring="--scissor-ring 8,8,152,112"; fi
            python3 tools/golden/golden.py "$out/$(basename "$ref")" "$ref" $ring
        done
        python3 tools/golden/golden.py "$out/canvas.png" tools/golden/ref/draw/canvas.png
    done
done
