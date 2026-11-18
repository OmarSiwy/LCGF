#!/usr/bin/env bash
# Publish only the measured files. The source checkout supplies Git credentials.
set -euo pipefail
report=$(realpath "${1:?comparison artifact directory}")
python3 - "$report/measurements.json" <<'PYCODE'
import json
import os
import sys

with open(sys.argv[1]) as f:
    meta = json.load(f)["metadata"]
if (meta["revision"] != os.environ["GITHUB_SHA"]
        or meta["run_number"] != int(os.environ["GITHUB_RUN_NUMBER"])
        or not 1 <= meta["attempt"] <= int(os.environ["GITHUB_RUN_ATTEMPT"])):
    sys.exit("Comparison provenance differs from the publishing run")
PYCODE
destination=benchmark-results
out=$(mktemp -d)
# git worktree needs a fresh path. Keep the parent as a cleanup boundary.
trap 'git worktree remove --force "$out/publish" 2>/dev/null || true; rmdir "$out"' EXIT
if git ls-remote --exit-code --heads origin "refs/heads/$destination" > /dev/null; then
    git fetch --no-tags origin "refs/heads/$destination"
    git worktree add --detach "$out/publish" FETCH_HEAD
    read -r decision < <(python3 - "$out/publish/measurements.json" "$report/measurements.json" <<'PY'
import json,sys
def sequence(path):
    with open(path) as f:
        m = json.load(f)["metadata"]
    return m["run_number"], m["attempt"]
print("publish" if sequence(sys.argv[2]) > sequence(sys.argv[1]) else "stale")
PY
)
    if [[ $decision == stale ]]; then
        echo "A report from this or a newer run is already published."
        exit 0
    fi
else
    status=$?
    [[ $status == 2 ]] || exit "$status"
    git worktree add --detach --no-checkout "$out/publish" HEAD
    git -C "$out/publish" switch --orphan "$destination"
fi
cp "$report/README.md" "$report/measurements.json" "$out/publish/"
git -C "$out/publish" add README.md measurements.json
git -C "$out/publish" -c user.name=github-actions\[bot\] -c user.email=41898282+github-actions\[bot\]@users.noreply.github.com \
    commit -m "bench: publish measurements for ${GITHUB_SHA:?measured revision}"
git -C "$out/publish" push origin "HEAD:refs/heads/$destination"
