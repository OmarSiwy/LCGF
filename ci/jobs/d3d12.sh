# all: no
# shell: golden
# The Direct3D 12 back end (src/render/d3d12/), cross-compiled for x86_64-windows and run under
# the golden shell's Wine: its d3d12.dll is vkd3d, drawing through the shell's Mesa lavapipe.
# The tests ask for WARP; Wine has none and gives vkd3d on lavapipe, a software rasteriser too
# (ci/jobs/d3d12-windows.sh runs the same checks on WARP on a Windows runner). One test draws
# every render conformance scene, offscreen and through the swapchain, against its golden;
# d3d12-play writes the same frames as PNGs and tools/golden/golden.py compares them, the check
# every back end's job applies; the canvas scene is compared with sw's golden of it.
# DXGI also opens a display for offscreen device creation. Keep one X server for all Wine calls.
if [[ -z "${DISPLAY:-}" ]]; then exec xvfb-run -a ci/run.sh d3d12; fi
zig build d3d12 --summary all
export WINEPREFIX="${WINEPREFIX:-$PWD/zig-out/wineprefix}" WINEDEBUG="${WINEDEBUG:--all}"
export WINEDLLOVERRIDES="mscoree=;mshtml=;winemenubuilder.exe="
quiet() { grep -v -e '^libEGL' -e '^pci id' -e '^MESA' -e '^$' || true; }
"${WINE:-wine}" zig-out/bin/d3d12-test.exe 2>&1 | quiet
# Direct3D 12 over a shown Win32 shell window (src/shell/win32/gpu.zig): its pictures are read
# back from the GPU, not from the screen.
"${WINE:-wine}" zig-out/bin/win32-gpu-test.exe 2>&1 | quiet
for mode in offscreen present; do
    out=zig-out/d3d12/$mode; rm -rf "$out"
    "${WINE:-wine}" zig-out/bin/d3d12-play.exe "$out" "$mode" 2>&1 | quiet
    for ref in src/render/conformance/*.png; do
        python3 tools/golden/golden.py "$out/$(basename "$ref")" "$ref"
    done
    python3 tools/golden/golden.py "$out/canvas.png" tools/golden/ref/draw/canvas.png
done
