# all: no
# LVGL on the bench/scenes/ scenes (bench/vs/lvgl/, docs/perf/vs.md): frame time, resident memory,
# idle wake-ups and binary size, beside the LCGR benchmark measured the same way. Prints numbers;
# timings only compare on one machine, so nothing is gated.
zig build vs-lcgr vs-lvgl
mkdir -p zig-out/vs
python3 bench/vs/measure.py --name lcgr --exe zig-out/bin/vs-lcgr --small zig-out/bin/vs-lcgr-small --json zig-out/vs/lcgr.json
python3 bench/vs/measure.py --name lvgl --exe zig-out/bin/vs-lvgl --small zig-out/bin/vs-lvgl-small --json zig-out/vs/lvgl.json
