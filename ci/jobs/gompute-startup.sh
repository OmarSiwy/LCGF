# shell: golden
# all: no
# Context memory and start-up of the Gompute back end against the Vulkan back end on the same
# GPU (src/render/gompute/DECISION.md, C0423): driver and context only, then an empty 800x600
# frame, each measured by src/render/gompute/measure.py (spawn to ready, resident memory, GPU
# memory from nvidia-smi) and tools/bench/probe.py (idle wake-ups). Needs CUDA and the NVIDIA
# Vulkan driver; prints numbers, no threshold.
icd=/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json
if ! [ -f "$icd" ] || ! nvidia-smi -L > /dev/null 2>&1; then echo "no CUDA device or NVIDIA Vulkan driver: skipped"; return 0; fi
export VK_ICD_FILENAMES=$icd
zig build gompute-play
zig build vk-play -Doptimize=ReleaseFast
for mode in device empty; do
    python3 src/render/gompute/measure.py -- zig-out/bin/gompute-probe "$mode"
    python3 src/render/gompute/measure.py -- zig-out/bin/vk-probe "$mode"
done
CUDA_CACHE_DISABLE=1 python3 src/render/gompute/measure.py -- zig-out/bin/gompute-probe device
for b in gompute-probe vk-probe; do python3 tools/bench/probe.py -- "zig-out/bin/$b" empty; done
