# Prints numbers (tools/bench); timings are only comparable on one machine.
# Fails when a pass median is >50% slower than tools/bench/baseline.json.
mkdir -p zig-out
zig build bench -- --json "$PWD/zig-out/bench.json"
python3 tools/bench/compare.py --self-test
python3 tools/bench/compare.py tools/bench/baseline.json zig-out/bench.json
zig build size
