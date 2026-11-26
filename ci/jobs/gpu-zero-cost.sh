# shell: golden
# lcgf_render.gpu costs nothing over writing the native calls by hand (src/render/vk/gpu_probe.zig):
# the same custom draw over the same data, once in raw Vulkan and once through the projection,
# built ReleaseFast. Both functions' instructions are disassembled, with addresses and objdump's
# address comments dropped, and required to be the same, instruction for instruction.
zig build gpu-probe
body() {
    objdump -d --no-show-raw-insn --disassemble="$1" zig-out/gpu-probe.o |
        sed -n "/<$1>:/,/^$/p" | tail -n +2 | sed -E 's/^ *[0-9a-f]+:\s*//; s/<[^>]*>//g; s/\s*#.*$//; s/\s+$//' | grep -v '^$'
}
body probe_native > zig-out/gpu-probe-native.s
body probe_gpu > zig-out/gpu-probe-gpu.s
n=$(wc -l < zig-out/gpu-probe-native.s)
[ "$n" -gt 10 ] || { echo "FAIL: probe_native disassembled to $n lines"; exit 1; }
if ! diff -u zig-out/gpu-probe-native.s zig-out/gpu-probe-gpu.s; then
    echo "FAIL: the draw through lcgf_render.gpu is not the hand-written Vulkan draw"
    exit 1
fi
echo "ok   lcgf_render.gpu draw: $n instructions, identical to the hand-written Vulkan calls"
