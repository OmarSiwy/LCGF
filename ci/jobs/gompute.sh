# all: no
# The Gompute back end (src/render/gompute/): its kernels compiled to PTX (sm_75) and HSACO
# (gfx1100) from the pinned Gompute revision (lazy build.zig.zon dependency), and its tests, which
# run the kernels on the CPU and, where a CUDA driver and card are present, on the GPU too.
zig build gompute --summary all
