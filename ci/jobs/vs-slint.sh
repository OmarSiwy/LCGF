# shell: vs
# all: no
# Slint on the bench/scenes/ scenes (bench/vs/slint/, docs/perf/vs.md): frame time, resident memory,
# idle wake-ups and binary size, beside the LCGR benchmark measured the same way. Prints numbers;
# timings only compare on one machine, so nothing is gated. Built by cargo (crates pinned by
# bench/vs/slint/Cargo.lock), never by zig build.
export CARGO_TARGET_DIR="$PWD/zig-out/cargo"
cargo build --locked --manifest-path bench/vs/slint/Cargo.toml --release
cargo build --locked --manifest-path bench/vs/slint/Cargo.toml --profile small
zig build vs-lcgr
mkdir -p zig-out/vs
python3 bench/vs/measure.py --name lcgr --exe zig-out/bin/vs-lcgr --small zig-out/bin/vs-lcgr-small --json zig-out/vs/lcgr.json
python3 bench/vs/measure.py --name slint --exe zig-out/cargo/release/vs-slint --small zig-out/cargo/small/vs-slint --json zig-out/vs/slint.json
