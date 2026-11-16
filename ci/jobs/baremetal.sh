# The bare-metal shell's example (src/shell/baremetal/firmware.zig): its test replays
# testdata/firmware.replay through Baremetal(Sim) here, and the same code is linked as a
# freestanding executable for Cortex-M7 and RV32IMAC (no OS, no libc, no allocator). No
# emulator is in the dev shell, so the microcontroller builds are linked, not run; `size`
# prints what they take.
zig build baremetal --summary all
size zig-out/bin/firmware-cortex-m7 zig-out/bin/firmware-rv32imac
