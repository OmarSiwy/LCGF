# shell: golden
# all: no
# The Vulkan back end (src/render/vk/) on Mesa lavapipe: its tests run on a real Vulkan 1.3
# implementation through the platform loader (VK_ICD_FILENAMES picks lavapipe in this shell),
# and vk-play draws the render conformance scenes, offscreen and through a headless swapchain
# (acquire, submit, present), each compared with its golden image.
# `custom` is drawn by the host's own pipeline in the UI's command buffer (custom.zig).
zig build vk vk-play --summary all
for mode in offscreen present; do
    out=zig-out/vk/$mode; rm -rf "$out"
    zig-out/bin/vk-play "$out" "$mode"
    for s in rects clip text custom; do
        python3 tools/golden/golden.py "$out/$s.png" "src/render/conformance/$s.png"
    done
done
