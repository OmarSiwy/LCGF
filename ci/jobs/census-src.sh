# Branch census of the production passes in src/ (src/layout/census_probe.zig), at a fixed CPU so
# codegen is the same everywhere. Fails when a pass gains a conditional jump over
# tools/census/baseline-src.json.
python3 tools/census/census.py --self-test
zig build census-src-obj -Dcpu=x86_64_v3
python3 tools/census/census.py zig-out/census_src.o --baseline tools/census/baseline-src.json
