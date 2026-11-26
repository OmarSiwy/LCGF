#!/bin/sh
# Builds bench/vs/capy/main.zig as a Capy example (Capy builds every file in its examples/), with
# the Zig Capy pins (0.14.1; ZIG14 names it) and GTK 4's headers. CAPY_SRC is a Capy checkout:
# git clone https://github.com/capy-ui/capy (measured at fd77077). Writes zig-out/bin/vs-capy.
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
: "${CAPY_SRC:?set CAPY_SRC to a Capy checkout}"
zig=${ZIG14:-zig}
cp "$root/bench/vs/capy/main.zig" "$CAPY_SRC/examples/vs-capy.zig"
(cd "$CAPY_SRC" && "$zig" build -Doptimize=ReleaseFast)
mkdir -p "$root/zig-out/bin"
cp "$CAPY_SRC/zig-out/bin/vs-capy" "$root/zig-out/bin/vs-capy"
