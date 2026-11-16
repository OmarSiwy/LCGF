# all: no
# runner: windows
# What only Windows can show, on a Windows runner (no Nix there: the workflow installs the
# flake's Zig with setup-zig). The Win32 shell's real-window tests and its example; the
# Direct3D 12 back end on WARP, every render conformance scene offscreen and through the
# swapchain, including the real device-removal test Wine skips; the AccessKit bridge's tests
# against AccessKit's Windows library. Linux checks the same code by cross-compiling
# (ci/jobs/win32.sh, d3d12-build.sh) and by Wine (d3d12.sh).
echo "-- win32"
zig build win32 win32-example --summary all
echo "-- d3d12 on WARP"
zig build d3d12 --summary all
zig-out/bin/d3d12-test.exe
for mode in offscreen present; do
    out=zig-out/d3d12/$mode; rm -rf "$out"
    zig-out/bin/d3d12-play.exe "$out" "$mode"
    for ref in src/render/conformance/*.png; do
        python tools/golden/golden.py "$out/$(basename "$ref")" "$ref"
    done
done
echo "-- accesskit"
zig build accesskit --summary all
