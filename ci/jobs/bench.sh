# Prints numbers (tools/bench); timings are only comparable on one machine.
# Fails when a pass median is >50% slower than tools/bench/baseline.json.
mkdir -p zig-out
zig build bench -- --json "$PWD/zig-out/bench.json"
python3 tools/bench/compare.py --self-test
# The baseline is from the owner's machine (docs/CHECKS.md: never compare timings across machines),
# so on GitHub runners the table is printed but does not fail the job.
python3 tools/bench/compare.py tools/bench/baseline.json zig-out/bench.json || [ -n "${GITHUB_ACTIONS-}" ]
zig build size
