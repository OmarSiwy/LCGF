# shell: shaders
# all: no
# A custom node drawn every frame through lcgf_render.gpu, in the UI's own command buffer
# (src/render/vk/probe_projection.zig; docs/research/custom-webgpu/README.md). Under
# synchronization validation every composed frame must match its reference image, and a control
# that skips the pass's layout hand-off must be caught. Then a short timing run; the job does
# not judge the numbers, it shows them.
golden_build custom-draw-probe -Doptimize=ReleaseFast
sh docs/research/custom-webgpu/validate.sh zig-out/bin/custom-draw-projection
python3 docs/research/custom-webgpu/measure.py zig-out/bin --rounds 3
