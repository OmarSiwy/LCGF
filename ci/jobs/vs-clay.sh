# all: no
# Clay on the bench/scenes/ scenes (bench/vs/clay/, docs/perf/vs.md): frame time, resident memory,
# idle wake-ups and binary size, beside the LCGR benchmark measured the same way. Prints numbers;
# timings only compare on one machine, so nothing is gated.
zig build vs-lcgr vs-clay web
mkdir -p zig-out/vs
python3 bench/vs/measure.py --name lcgr --exe zig-out/bin/vs-lcgr --small zig-out/bin/vs-lcgr-small --json zig-out/vs/lcgr.json
python3 bench/vs/measure.py --name clay --exe zig-out/bin/vs-clay --small zig-out/bin/vs-clay-small --startup zig-out/bin/vs-clay-static --json zig-out/vs/clay.json
# Layout alone in wasm, built alike (src/render/web/layout.zig, bench/vs/clay/layout.c).
python3 src/render/web/size.py zig-out/web/layout.wasm zig-out/web/clay-layout.wasm
