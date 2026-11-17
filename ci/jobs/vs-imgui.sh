# all: no
# Dear ImGui on the bench/scenes/ scenes (bench/vs/imgui/, docs/perf/vs.md): frame time, resident memory,
# idle wake-ups and binary size, beside the LCGF benchmark measured the same way. Prints numbers;
# timings only compare on one machine, so nothing is gated.
zig build vs-lcgf vs-imgui
mkdir -p zig-out/vs
python3 bench/vs/measure.py --name lcgf --exe zig-out/bin/vs-lcgf --small zig-out/bin/vs-lcgf-small --json zig-out/vs/lcgf.json
python3 bench/vs/measure.py --name imgui --exe zig-out/bin/vs-imgui --small zig-out/bin/vs-imgui-small --json zig-out/vs/imgui.json
