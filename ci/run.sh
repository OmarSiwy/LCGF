#!/usr/bin/env bash
# Run CI jobs. GitHub Actions and a local run call the same thing:
#
#   nix develop -c ci/run.sh <job>     one job
#   nix develop -c ci/run.sh all       every job not marked `# all: no`
#   ci/run.sh --matrix                 the job list as JSON, for the workflow
#
# A job is one file, ci/jobs/<name>.sh, run from the repository root with
# `both` defined. A lane adds a job by adding a file; nothing else changes.
# Header lines a job may have:
#   # shell: <name>   the flake dev shell it needs (default: default)
#   # all: no         left out of `all` (slow, or needs another shell)
#   # runner: <os>    the GitHub runner: windows or macos (default: ubuntu)
set -euo pipefail
cd "$(dirname "$0")/.."

# Each test job runs the root package and the prototype, whose tests are the
# reference behaviour and must keep passing (CLAUDE.md).
both() { zig build "$@" && (cd prototype && zig build "$@"); }

# Native binaries that load the golden shell's Mesa must use its glibc loader too.
golden_build() {
    local -a linker=()
    local path="${NIX_CC:-}/nix-support/dynamic-linker"
    if [[ -f "$path" ]]; then linker+=("-Ddynamic-linker=$(<"$path")"); fi
    zig build "${linker[@]}" "$@"
}

header() { sed -n "s/^# $2: *//p" "ci/jobs/$1.sh" | head -n1; }
names() { for f in ci/jobs/*.sh; do basename "$f" .sh; done; }

job() {
    [ -f "ci/jobs/$1.sh" ] || { echo "unknown job: $1" >&2; exit 2; }
    (set -euo pipefail; source "ci/jobs/$1.sh")
}

case "${1:?usage: ci/run.sh <job>|all|--matrix}" in
all)
    n=0
    for j in $(names); do
        [ "$(header "$j" all)" = no ] && continue
        echo "== $j"; job "$j"; n=$((n + 1))
    done
    echo "all $n jobs green" ;;
--matrix)
    sep=""; printf '['
    for j in $(names); do
        # The dedicated experiment branch requests only the native Apple hardware job.
        if [[ ${GITHUB_REF:-} == refs/heads/experiment/metal-custom-draw && $j != metal-webgpu ]]; then continue; fi
        s=$(header "$j" shell); r=$(header "$j" runner)
        printf '%s{"job":"%s","shell":"%s","runner":"%s-latest"}' "$sep" "$j" "${s:-default}" "${r:-ubuntu}"; sep=,
    done
    printf ']\n' ;;
*) job "$1" ;;
esac
