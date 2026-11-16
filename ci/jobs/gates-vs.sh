# shell: vs
# all: no
# Release gates against the comparison frameworks (docs/GATES.md, bench/gates/gates.py): builds
# every harness of bench/vs/ as the ci/jobs/vs-*.sh jobs do, measures each with
# bench/vs/measure.py beside the LCGR row, then fails when a gate regresses against
# bench/gates/recorded.json. Timings are measured and compared in this one run, on one machine.
export CARGO_TARGET_DIR="$PWD/zig-out/cargo"
zig build vs-lcgr vs-clay vs-imgui vs-lvgl
for n in egui iced slint; do
    cargo build --locked --manifest-path "bench/vs/$n/Cargo.toml" --release
    cargo build --locked --manifest-path "bench/vs/$n/Cargo.toml" --profile small
done
qt="$(pkg-config --cflags --libs Qt6Quick Qt6Qml Qt6Gui Qt6Core)"
mkdir -p zig-out/bin zig-out/gates
c++ -O2 -fPIC -std=c++17 bench/vs/qtquick/main.cpp $qt -o zig-out/bin/vs-qtquick
c++ -Os -s -fPIC -std=c++17 bench/vs/qtquick/main.cpp $qt -o zig-out/bin/vs-qtquick-small
rm -f zig-out/gates/*.json
# Pinned to one CPU, every framework on the same one.
m() { taskset -c 2 python3 bench/vs/measure.py --name "$1" --exe "$2" --small "$3" --json "zig-out/gates/$1.json"; }
m lcgr zig-out/bin/vs-lcgr zig-out/bin/vs-lcgr-small
for n in clay imgui lvgl qtquick; do m "$n" "zig-out/bin/vs-$n" "zig-out/bin/vs-$n-small"; done
for n in egui iced slint; do m "$n" "zig-out/cargo/release/vs-$n" "zig-out/cargo/small/vs-$n"; done
python3 bench/gates/gates.py frame zig-out/gates
