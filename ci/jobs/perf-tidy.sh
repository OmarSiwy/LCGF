# Formatting and the build-time rules of the performance guide (ci/perf_tidy.py; the table in
# docs/CODE_STANDARD.md says which check covers which rule), as a ratchet: fails when a file
# gains a finding over ci/perf_tidy_baseline.json. Fewer is fine: lower it with
# `python3 ci/perf_tidy_gate.py --record src build.zig`.
zig build lint
