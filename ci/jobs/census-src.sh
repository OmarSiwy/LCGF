# Branch census of the production passes in src/ (src/layout/census_probe.zig), at a fixed CPU so
# codegen is the same everywhere. Fails when a pass gains a conditional jump over
# bench/census/baseline-src.json or baseline-alpha8.json. Separate objects keep
# LLVM from merging the two format loops behind wrappers outside the census.
python3 bench/census/census.py --self-test
zig build census-src-obj -Dcpu=x86_64_v3
python3 bench/census/census.py zig-out/census_src.o --baseline bench/census/baseline-src.json
python3 bench/census/census.py zig-out/census_alpha8.o --baseline bench/census/baseline-alpha8.json
