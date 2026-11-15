#!/usr/bin/env bash
# One CI job by name. GitHub Actions (.github/workflows/ci.yml) and a local
# run call the same thing:  nix develop -c ci/run.sh <job>     (or: all)
#
# Each job runs the root package and the prototype, whose tests are the
# reference behaviour and must keep passing (CLAUDE.md).
set -euo pipefail
cd "$(dirname "$0")/.."

both() { zig build "$@" && (cd prototype && zig build "$@"); }

job() {
    case "$1" in
    debug)        both test ;;
    release-safe) both test -Doptimize=ReleaseSafe ;;
    release-fast) both test -Doptimize=ReleaseFast ;;
    # simd.lanes follows the CPU: SSE2 baseline gives 4 f32 lanes, AVX2 gives 8.
    lanes-4)      both test -Dcpu=x86_64 ;;
    lanes-8)      both test -Dcpu=x86_64_v3 ;;
    # Compile only: these targets cannot run here.
    cross)
        for t in aarch64-linux aarch64-macos x86_64-windows wasm32-wasi riscv64-linux; do
            echo "-- $t"
            zig build test-build -Dtarget="$t"
        done
        (cd prototype && zig build cross) ;;
    # Not in `all`: CI runs it in the golden shell (nix develop .#golden -c ci/run.sh golden).
    golden)       python3 tools/golden/golden.py --self-test ;;
    *) echo "unknown job: $1" >&2; exit 2 ;;
    esac
}

jobs=(debug release-safe release-fast lanes-4 lanes-8 cross)
if [ "${1-}" = all ]; then
    for j in "${jobs[@]}"; do echo "== $j"; job "$j"; done
    echo "all ${#jobs[@]} jobs green"
else
    job "${1:?usage: ci/run.sh <job>|all}"
fi
