# Prints numbers (bench/micro); timings are only comparable on one machine.
# Fails when a pass median is >50% slower than bench/micro/baseline.json.
mkdir -p zig-out
zig build bench -- --json "$PWD/zig-out/bench.json"
python3 bench/micro/compare.py --self-test
# The baseline is from the owner's machine (docs/CHECKS.md: never compare timings across machines),
# so on GitHub runners the table is printed but does not fail the job.
# Timings mean nothing on a loaded machine (many lanes building at once): print, do not fail,
# when the 1-minute load average is above a quarter of the CPU count.
busy=$(awk -v n="$(nproc)" '{ print ($1 > n / 4) }' /proc/loadavg)
[ "$busy" = 1 ] && echo "bench: load $(cut -d' ' -f1 /proc/loadavg) on $(nproc) CPUs, gate not applied"
python3 bench/micro/compare.py bench/micro/baseline.json zig-out/bench.json || [ -n "${GITHUB_ACTIONS-}" ] || [ "$busy" = 1 ]
# bench/scenes/: printed, not gated (no baseline yet).
for scene in form list text springs resize idle data data-idle mixed; do zig build bench -- --scene "$scene"; done
zig build size
