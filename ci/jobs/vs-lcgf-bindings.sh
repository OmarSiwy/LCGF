# shell: vs
# all: no
# LCGF from C++ and Rust on the bench/scenes/ scenes (bench/vs/lcgf-cpp/, lcgf-rust/), beside the
# Zig row (vs-lcgf), each measured as bench/vs/measure.py measures every framework. The scenes
# are the same frames (bindings/check/run.sh gates that), so the difference is the seam: rows
# made by the caller (lcgf::Row, Row::from) and pushed inline through lcgf_rt_view, one direct
# call into liblcgf for the rest. On the springs scene (2,000 builder calls a frame) C++ and
# Rust land within run-to-run spread of Zig (docs/guide/bindings.md). Prints numbers; timings
# only compare on one machine, so nothing is gated.
zig build vs-lcgf
zig build abi -Doptimize=ReleaseFast -p zig-out/abi
cmake -S bench/vs/lcgf-cpp -B zig-out/vs-lcgf-cpp -DCMAKE_PREFIX_PATH="$PWD/zig-out/abi" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS=-march=native >/dev/null
cmake --build zig-out/vs-lcgf-cpp
export CARGO_TARGET_DIR="$PWD/zig-out/cargo" LCGF_PREFIX="$PWD/zig-out/abi" RUSTFLAGS="-C target-cpu=native"
cargo build --locked --manifest-path bench/vs/lcgf-rust/Cargo.toml --release
cargo build --locked --manifest-path bench/vs/lcgf-rust/Cargo.toml --profile small
mkdir -p zig-out/vs
python3 bench/vs/measure.py --name lcgf --exe zig-out/bin/vs-lcgf --small zig-out/bin/vs-lcgf-small --json zig-out/vs/lcgf.json
python3 bench/vs/measure.py --name lcgf-cpp --exe zig-out/vs-lcgf-cpp/vs-lcgf-cpp --small zig-out/vs-lcgf-cpp/vs-lcgf-cpp-small --json zig-out/vs/lcgf-cpp.json
python3 bench/vs/measure.py --name lcgf-rust --exe zig-out/cargo/release/vs-lcgf-rust --small zig-out/cargo/small/vs-lcgf-rust --json zig-out/vs/lcgf-rust.json
