# Gompute back end: decision record

The Gompute back end is optional and experimental (docs/DESIGN.md): CUDA and HIP compute kernels
written in Zig, for offscreen effects shown as textures, never a replacement for a graphics back
end. This file records each step of lane render-gompute with what was measured. Machine for every
number: x86_64 Linux (NixOS), RTX 4060 Laptop GPU (sm_89) with driver 595.71.05, no AMD GPU, Zig
0.18.0-dev.1151+8dfb7a7cc.

## C0418: pin a Gompute revision that builds with the project's Zig

Decision: pin Gompute 1.0.0 at commit 37432b2 (branch zig-0.18.0-dev.1151, the owner's PR #9) as
a lazy build.zig.zon dependency, fetched only for `zig build gompute`. abd75e4 was its last Zig 0.17
build and the 1.x heads before 37432b2 need 0.18.0-dev.349, which this project does not use.

Device targets are pinned, not left at Gompute's `.auto` (which runs `nvidia-smi` on the build
machine and silently compiles a backend out when it finds no GPU): CUDA as sm_75 PTX (any Turing
or newer card JITs it; no `ptxas` needed, `.sass = false`), HIP as gfx1100 HSACO, compile-only
here because this machine has no AMD GPU.

Measured:

| What | Value |
|---|---|
| Package archive / unpacked | 151 KB / 596 KB, no dependencies of its own |
| Cold `zig build gompute` (fresh cache dir) | 2.96 s wall, 214 MB peak RSS |
| PTX object (nvptx64-cuda, sm_75) | 53 ms |
| HSACO object (amdgcn-amdhsa, gfx1100) | 63 ms, 3.4 KB |
| `fill` test | passes on the CPU path and on CUDA (RTX 4060): the same 1,000 pixels |

One build fix was needed on our side: a kernel's per-thread function takes `g.GlobalPtr(T)`
(a plain `[*]T` on the host, a global-address-space pointer on the device) instead of a slice
made with `@addrSpaceCast`, which LLVM 23 rejected on nvptx64 ("Invalid cast" in bitcode).
