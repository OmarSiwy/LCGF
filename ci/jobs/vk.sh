# shell: golden
# all: no
# The Vulkan back end (src/render/vk/) on Mesa lavapipe: its tests run on a real Vulkan 1.3
# implementation through the platform loader (VK_ICD_FILENAMES picks lavapipe in this shell),
# and vk-play draws the render conformance scenes, offscreen and through a headless swapchain
# (acquire, submit, present), each compared with its golden image.
# `custom` needs the host's inline draw (plan commit C0388) and is not compared yet.
zig build vk vk-play --summary all
for mode in offscreen present; do
    out=zig-out/vk/$mode; rm -rf "$out"
    zig-out/bin/vk-play "$out" "$mode"
    for s in rects clip text; do
        python3 tools/golden/golden.py "$out/$s.png" "src/render/conformance/$s.png"
    done
done
