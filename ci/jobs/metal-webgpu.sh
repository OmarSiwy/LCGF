# all: no
# runner: macos
# Compare the WebGPU callback with a native reference, then time native compositing.
set -eu
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
zig build metal-webgpu-probe -Dwgpu-native=v29 -Daccesskit=false -Doptimize=ReleaseFast
./zig-out/bin/metal-webgpu-probe
