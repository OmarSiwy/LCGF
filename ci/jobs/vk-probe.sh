# shell: golden
# all: no
# Resident memory and frame CPU time of the Vulkan back end against the wgpu back end
# (wgpu-native v29 on the same Vulkan driver), measured by tools/bench/probe.py: driver only,
# an empty 800x600 frame, and the render conformance scenes drawn 2000 times. Prints numbers;
# no threshold (lavapipe's own ~67 MB dominates resident memory on CI). wgpu's instance is
# Vulkan-only (src/render/wgpu/host.zig); with wgpu-native's default of every back end it was
# +46 MB on lavapipe and +81 MB on NVIDIA, the GL one loading an EGL driver it never used.
zig build vk-play -Doptimize=ReleaseFast
zig build vk-probe-wgpu -Dwgpu-native=v29 -Doptimize=ReleaseFast
for b in vk-probe vk-probe-wgpu; do
    for mode in device empty scenes; do
        python3 tools/bench/probe.py -- "zig-out/bin/$b" "$mode"
    done
done
