# all: no
# Measurements of the Gompute back end on CUDA device 0 (src/render/gompute/probe.zig): prints
# numbers, no threshold. Needs an NVIDIA driver and card; a machine without one skips it.
nvidia-smi -L > /dev/null 2>&1 || { echo "no CUDA device: skipped"; return 0; }
zig build gompute-play
zig-out/bin/gompute-probe readback
