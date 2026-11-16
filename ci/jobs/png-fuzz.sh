# all: no
# Mutated test images through the PNG decoder for 300 s (slow, so not in `all`).
# FUZZ_SEED overrides the seed; a crash prints the command that reproduces it.
zig build png-fuzz -Doptimize=ReleaseSafe -- 300 "${FUZZ_SEED:-$(date +%s)}"
