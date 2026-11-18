# shell: vs
# all: no
# Release gates against the comparison frameworks (docs/GATES.md, bench/gates/gates.py): builds
# every harness of bench/vs/ as the ci/jobs/vs-*.sh jobs do, measures each with
# bench/vs/measure.py beside the LCGF row, then fails when a gate regresses against
# bench/gates/recorded.json. Timings are measured and compared in this one run, on one machine.
# Keep the GTK display server outside every timed process start and isolate pointer events.
if [[ ${LCGF_VS_PRIVATE_DISPLAY:-0} != 1 ]]; then
    xvfb-run -a -s "-screen 0 1920x1080x24 -noreset" env LCGF_VS_PRIVATE_DISPLAY=1 ci/run.sh gates-vs
    exit
fi
python3 -m unittest discover -s bench/vs -p test_report.py
export GDK_BACKEND=x11 GSK_RENDERER=cairo GTK_A11Y=none
export CARGO_TARGET_DIR="$PWD/zig-out/cargo"
zig build vs-lcgf vs-clay vs-imgui vs-lvgl
for n in egui iced slint; do
    cargo build --locked --manifest-path "bench/vs/$n/Cargo.toml" --release
    cargo build --locked --manifest-path "bench/vs/$n/Cargo.toml" --profile small
done
qt="$(pkg-config --cflags --libs Qt6Quick Qt6Qml Qt6Gui Qt6Core)"
mkdir -p zig-out/bin zig-out/gates
c++ -O2 -fPIC -std=c++17 bench/vs/qtquick/main.cpp $qt -o zig-out/bin/vs-qtquick
c++ -Os -s -fPIC -std=c++17 bench/vs/qtquick/main.cpp $qt -o zig-out/bin/vs-qtquick-small
bench/vs/build-extra.sh
rm -f zig-out/gates/*.json
# Use CPU 2 where available, otherwise the first CPU allowed by the runner.
cpu=$(python3 -c 'import os; cpus=os.sched_getaffinity(0); print(2 if 2 in cpus else min(cpus))')
# Pinned to one CPU, every framework on the same one.
# The fourth argument, when given, is the build measured for resident memory and start-up.
m() {
    taskset -c "$cpu" python3 bench/vs/measure.py --libraries --name "$1" --exe "$2" --small "$3" --startup "${4:-$2}" --json "zig-out/gates/$1.json"
    taskset -c "$cpu" python3 bench/gates/gates.py measure-first-frame "zig-out/gates/$1.json" "${4:-$2}"
}
m lcgf zig-out/bin/vs-lcgf zig-out/bin/vs-lcgf-small
m clay zig-out/bin/vs-clay zig-out/bin/vs-clay-small zig-out/bin/vs-clay-static
for n in imgui lvgl qtquick nuklear microui gtk4 qtwidgets; do m "$n" "zig-out/bin/vs-$n" "zig-out/bin/vs-$n-small"; done
for n in egui iced slint; do m "$n" "zig-out/cargo/release/vs-$n" "zig-out/cargo/small/vs-$n"; done
# Complete the measurement and preserve it even if a release target regresses.
bench/vs/window-resize/run.sh
python3 bench/vs/report.py zig-out/gates zig-out/window-resize.json zig-out/comparison --cpu "$cpu"
failed=0
for gate in frame rss first-frame; do
    python3 bench/gates/gates.py "$gate" zig-out/gates || failed=1
done
exit "$failed"
