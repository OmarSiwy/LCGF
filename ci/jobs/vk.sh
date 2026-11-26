# shell: golden
# all: no
# The Vulkan back end (src/render/vk/) on Mesa lavapipe. Its tests run on a real Vulkan 1.3
# implementation through the platform loader (VK_ICD_FILENAMES picks lavapipe in this shell);
# one of them draws every render conformance scene offscreen and through a headless swapchain,
# without and with 4x multisampling, against its golden. vk-play writes the same frames as PNGs
# and tools/golden/golden.py compares them, the check every back end's job applies; the canvas
# scene (src/render/gpu/canvas.zig's pipeline) is compared with sw's golden of it.
golden_build vk vk-play --summary all
for mode in offscreen present; do
    for samples in 1 4; do
        out=zig-out/vk/$mode-x$samples; rm -rf "$out"
        zig-out/bin/vk-play "$out" "$mode" "$samples"
        for ref in src/render/conformance/*.png; do
            python3 tools/golden/golden.py "$out/$(basename "$ref")" "$ref"
        done
        python3 tools/golden/golden.py "$out/canvas.png" tools/golden/ref/draw/canvas.png
    done
done
