# all: no
# Mutated test fonts through the font parser for 300 s (slow, so not in `all`).
# FUZZ_SEED overrides the seed; a crash prints the command that reproduces it.
zig build font-fuzz -Doptimize=ReleaseSafe -- 300 "${FUZZ_SEED:-$(date +%s)}"
