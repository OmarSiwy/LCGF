# all: no
# The Direct3D 12 back end (src/render/d3d12/), cross-compiled for x86_64-windows and run under
# Wine: its d3d12.dll is vkd3d, drawing through the host's Vulkan driver. The flake has no Wine
# yet, so this job uses the machine's (WINE, default `wine`) and the machine's Mesa lavapipe
# (LVP_ICD, default the NixOS driver path): a Vulkan driver built against the dev shell's newer
# glibc does not load into the system Wine. The tests ask for WARP; Wine has none and gives
# vkd3d on lavapipe, a software rasteriser too. One test draws every render conformance scene,
# offscreen and through the swapchain, against its golden; d3d12-play writes the same frames
# as PNGs and tools/golden/golden.py compares them, the check every back end's job applies.
zig build d3d12 --summary all
export WINEPREFIX="${WINEPREFIX:-$PWD/zig-out/wineprefix}" WINEDEBUG="${WINEDEBUG:--all}"
export WINEDLLOVERRIDES="mscoree=;mshtml=;winemenubuilder.exe="
export VK_ICD_FILENAMES="${LVP_ICD:-/run/opengl-driver/share/vulkan/icd.d/lvp_icd.x86_64.json}"
unset LD_LIBRARY_PATH
quiet() { grep -v -e '^libEGL' -e '^pci id' -e '^MESA' -e '^$' || true; }
"${WINE:-wine}" zig-out/bin/d3d12-test.exe 2>&1 | quiet
for mode in offscreen present; do
    out=zig-out/d3d12/$mode; rm -rf "$out"
    "${WINE:-wine}" zig-out/bin/d3d12-play.exe "$out" "$mode" 2>&1 | quiet
    for ref in src/render/conformance/*.png; do
        python3 tools/golden/golden.py "$out/$(basename "$ref")" "$ref"
    done
done
