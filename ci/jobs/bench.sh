# Prints numbers (tools/bench); timings are only comparable on one machine.
# Fails when a pass median is >50% slower than tools/bench/baseline.json.
mkdir -p zig-out
zig build bench -- --json "$PWD/zig-out/bench.json"
python3 tools/bench/compare.py --self-test
# The baseline is from the owner's machine (docs/CHECKS.md: never compare timings across machines),
# so on GitHub runners the table is printed but does not fail the job.
# Timings mean nothing on a loaded machine (many lanes building at once): print, do not fail,
# when the 1-minute load average is above half the CPU count.
busy=$(awk -v n="$(nproc)" '{ print ($1 > n / 2) }' /proc/loadavg)
[ "$busy" = 1 ] && echo "bench: load $(cut -d' ' -f1 /proc/loadavg) on $(nproc) CPUs, gate not applied"
python3 tools/bench/compare.py tools/bench/baseline.json zig-out/bench.json || [ -n "${GITHUB_ACTIONS-}" ] || [ "$busy" = 1 ]
# bench/scenes/: printed, not gated (no baseline yet).
for scene in form list text; do zig build bench -- --scene "$scene"; done
zig build size
