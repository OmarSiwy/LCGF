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
zig build abi -Doptimize=ReleaseFast -Dwgpu-native=v29
sh bindings/check/run.sh "$PWD/zig-out"
