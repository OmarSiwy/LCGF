# shell: vs
# all: no
# C++ and Rust over the C seam (src/abi/, bindings/, tools/lcgf-gen/). `zig build abi` installs
# liblcgf, lcgf.h, lcgf-gen, the C++ headers, the CMake package and (with -Dwgpu-native)
# wgpu-native; then CMake builds the C++ checks and cargo builds the Rust crates against that
# prefix alone, with no Zig. The same UIs replayed over the same input must give byte-identical
# draw lists in Zig (ComptimeUi), Zig through the seam, C++ and Rust, and so must the runtime
# front end's scenes. One GPU frame recorded through lcgf_render.gpu, lcgf/gpu.hpp and lcgf::gpu
# must make the same Vulkan calls, and check.zig's GPU checks must pass in C++ and Rust on
# Vulkan (lavapipe), GL ES (llvmpipe) and wgpu-native.
# DirectX-Headers for the D3D12 recorder: only this job needs them, so they are no build.zig.zon
# dependency (the pinned Zig would fetch them in every job). Pinned by the archive's SHA-256.
dx=$(mktemp -d)
curl -fsSL --retry 3 -o "$dx/dx.tar.gz" https://github.com/microsoft/DirectX-Headers/archive/refs/tags/v1.620.2.tar.gz
echo "2b916ef1be5db35313f56d60499274fed39db37b54a1f0befa8aa49041c14855  $dx/dx.tar.gz" | sha256sum -c --quiet
tar -xzf "$dx/dx.tar.gz" -C "$dx"
zig build abi -Doptimize=ReleaseFast -Dwgpu-native=v29 -Ddirectx-headers="$dx/DirectX-Headers-1.620.2"
# The Zig side is built for this CPU; so is Rust, or the gate would time a narrower build.
RUSTFLAGS="${RUSTFLAGS:--C target-cpu=native}" sh bindings/check/run.sh "$PWD/zig-out"
