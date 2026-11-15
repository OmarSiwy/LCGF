# all: no
# Seeded random loop over the tools/fuzz entry points for 60 s (slow, so not in `all`).
# FUZZ_SEED overrides the seed; a crash prints the command that reproduces it.
zig build fuzz
zig build fuzz-run -Doptimize=ReleaseSafe -- 60 "${FUZZ_SEED:-$(date +%s)}"
