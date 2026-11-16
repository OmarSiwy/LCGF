# shell: bench
# all: no
# Cache-miss profile per pass (docs/perf/cache.md): hardware counters per pass from
# `bench --counters`, and perf stat over the whole run as a cross-check. Needs
# kernel.perf_event_paranoid <= 2 and a core with these events (pinned to CPU 2: a P-core on
# hybrid Intel parts). Prints numbers; gates nothing.
if [ "$(cat /proc/sys/kernel/perf_event_paranoid)" -gt 2 ]; then
    echo "perf-cache: perf_event_paranoid > 2, skipped"
else
    zig build bench # build first, so perf stat below counts the run, not the compile
    for scene in rows form list text springs resize; do
        taskset -c 2 perf stat -e cycles:u,instructions:u,L1-dcache-load-misses:u,LLC-load-misses:u -- \
            zig build bench -- --counters --scene "$scene"
    done
fi
