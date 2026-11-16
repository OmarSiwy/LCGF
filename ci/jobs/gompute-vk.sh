# shell: golden
# all: no
# The Gompute back end presenting through Vulkan external memory (src/render/gompute/vulkan.zig):
# CUDA draws into memory Vulkan exported, Vulkan copies it into an image, the pixels are compared
# with the CPU path's; then gompute-vk-probe times that hand-over. Needs CUDA and the NVIDIA
# Vulkan driver, picked over the shell's lavapipe when the host has it; without them the test
# skips and the probe is not run.
icd=/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json
if [ -f "$icd" ] && nvidia-smi -L > /dev/null 2>&1; then
    export VK_ICD_FILENAMES=$icd
    zig build gompute-vk --summary all
    zig-out/bin/gompute-vk-probe
else
    zig build gompute-vk --summary all
    echo "no CUDA device or NVIDIA Vulkan driver: interop not exercised"
fi
