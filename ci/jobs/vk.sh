# shell: golden
# all: no
# The Vulkan back end (src/render/vk/) on Mesa lavapipe: its tests run on a real Vulkan 1.3
# implementation through the platform loader (VK_ICD_FILENAMES picks lavapipe in this shell).
zig build vk --summary all
