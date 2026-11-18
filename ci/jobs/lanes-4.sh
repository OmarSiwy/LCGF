# simd.lanes follows the CPU: the SSE2 baseline gives 4 f32 lanes.
zig build test -Dcpu=x86_64
