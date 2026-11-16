# shell: vs
# all: no
# Qt Quick on the bench/scenes/ scenes (bench/vs/qtquick/, docs/perf/vs.md): frame time, resident
# memory, idle wake-ups and binary size, beside the LCGR benchmark measured the same way. Prints
# numbers; timings only compare on one machine, so nothing is gated. Built with the dev shell's
# C++ compiler against Qt 6 from the locked nixpkgs, never by zig build. Qt ships as shared
# libraries, so the job also sums the libraries mapped when idle.
qt="$(pkg-config --cflags --libs Qt6Quick Qt6Qml Qt6Gui Qt6Core)"
mkdir -p zig-out/bin zig-out/vs
c++ -O2 -fPIC -std=c++17 bench/vs/qtquick/main.cpp $qt -o zig-out/bin/vs-qtquick
c++ -Os -s -fPIC -std=c++17 bench/vs/qtquick/main.cpp $qt -o zig-out/bin/vs-qtquick-small
zig build vs-lcgr
python3 bench/vs/measure.py --name lcgr --exe zig-out/bin/vs-lcgr --small zig-out/bin/vs-lcgr-small --json zig-out/vs/lcgr.json
python3 bench/vs/measure.py --name qtquick --exe zig-out/bin/vs-qtquick --small zig-out/bin/vs-qtquick-small --libraries --json zig-out/vs/qtquick.json
