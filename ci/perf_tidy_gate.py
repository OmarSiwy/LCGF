#!/usr/bin/env python3
"""Ratchet for ci/perf_tidy.py: no file may gain a finding over the recorded baseline.

    python3 ci/perf_tidy_gate.py PATHS...             fail when a (file, rule) count grew
    python3 ci/perf_tidy_gate.py --record PATHS...    rewrite the baseline from this tree

The linter and its rules are the build-time checks of "The Ultimate System-Level Performance
Guide" (docs/CODE_STANDARD.md). The code predates them, so the gate starts from what it found
(ci/perf_tidy_baseline.json: file -> rule -> count) and only ever goes down: a new finding is
fixed, or silenced on its line with `// tidy: allow(rule) reason`. Fewer is fine; lower the
baseline in the same commit with --record. A file that is gone is ignored.
"""
import collections
import json
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
BASELINE = HERE / "perf_tidy_baseline.json"
FINDING = re.compile(r"^(.+?):(\d+): (?:error|warning): \[([a-z-]+)\] ")


def findings(paths):
    """{file: {rule: [line, ...]}} from the linter's text output."""
    run = subprocess.run([sys.executable, str(HERE / "perf_tidy.py"), "--strict", *paths], capture_output=True, text=True)
    assert run.returncode in (0, 1), run.stderr
    found = collections.defaultdict(lambda: collections.defaultdict(list))
    for line in run.stdout.splitlines():
        match = FINDING.match(line)
        if match:
            found[match.group(1)][match.group(3)].append(int(match.group(2)))
    return found


def main():
    args = sys.argv[1:]
    record = "--record" in args
    paths = [a for a in args if a != "--record"]
    assert paths, __doc__
    found = findings(paths)
    if record:
        counts = {f: {r: len(lines) for r, lines in sorted(rules.items())} for f, rules in sorted(found.items())}
        BASELINE.write_text(json.dumps(counts, indent=1, sort_keys=True) + "\n")
        print(f"perf-tidy: recorded {sum(sum(c.values()) for c in counts.values())} findings in {len(counts)} files")
        return 0
    baseline = json.loads(BASELINE.read_text())
    grew = 0
    for file, rules in sorted(found.items()):
        for rule, lines in sorted(rules.items()):
            allowed = baseline.get(file, {}).get(rule, 0)
            if len(lines) > allowed:
                grew += 1
                shown = ", ".join(str(n) for n in lines[:12]) + (", ..." if len(lines) > 12 else "")
                print(f"{file}: [{rule}] {len(lines)} > baseline {allowed} (lines {shown})")
    total = sum(len(lines) for rules in found.values() for lines in rules.values())
    recorded = sum(sum(rules.values()) for rules in baseline.values())
    if grew:
        print(f"perf-tidy: {grew} (file, rule) counts grew: fix them or add `// tidy: allow(rule) reason`", file=sys.stderr)
        return 1
    print(f"perf-tidy: {total} findings, none over the baseline ({recorded} recorded)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
