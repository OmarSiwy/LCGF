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
    *) echo "unknown job: $1" >&2; exit 2 ;;
    esac
}

jobs=(debug release-safe release-fast)
if [ "${1-}" = all ]; then
    for j in "${jobs[@]}"; do echo "== $j"; job "$j"; done
    echo "all ${#jobs[@]} jobs green"
else
    job "${1:?usage: ci/run.sh <job>|all}"
fi
