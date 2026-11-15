#!/usr/bin/env python3
"""Compare a benchmark run with a stored baseline and print a delta table per pass.

    zig build bench -- --json "$PWD/run.json"
    python3 tools/bench/compare.py tools/bench/baseline.json run.json [--tolerance 0.5]

Exits 1 when a gated pass median is slower than the baseline by more than the tolerance (a
fraction: 0.5 means 50 percent). Gated by default are the frame passes; the layout sub-passes are
printed but not gated, because the small ones (1 to 70 us) moved by 50 to 100 percent between two
runs on a loaded machine. Timings move by about a third between runs on one machine (docs/CHECKS.md)
and are not comparable across machines: record the baseline on the machine that compares.
To record one: zig build bench -- --json "$PWD/tools/bench/baseline.json"
"""
import argparse
import json
import sys

FRAME_PASSES = "begin+hit,build,layout,paint,frame"


def table(base, cur, tolerance, gated):
    rows, slow = [], []
    for name, b in base["passes"].items():
        c = cur["passes"].get(name)
        if c is None:
            rows.append((name, b["median_us"], None, None, "missing"))
            slow.append(name)
            continue
        delta = c["median_us"] / b["median_us"] - 1 if b["median_us"] else 0.0
        status = "ok"
        if delta > tolerance:
            status = "SLOWER" if name in gated else "slower (not gated)"
        if status == "SLOWER":
            slow.append(name)
        rows.append((name, b["median_us"], c["median_us"], delta, status))
    return rows, slow


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("baseline")
    ap.add_argument("current")
    ap.add_argument("--tolerance", type=float, default=0.5)
    ap.add_argument("--gate", default=FRAME_PASSES, help="comma-separated passes that can fail")
    a = ap.parse_args()
    with open(a.baseline) as f:
        base = json.load(f)
    with open(a.current) as f:
        cur = json.load(f)
    for key in ("lanes", "nodes", "texts", "frames"):
        if base.get(key) != cur.get(key):
            print(f"warning: {key} differs: baseline {base.get(key)}, current {cur.get(key)}")
    rows, slow = table(base, cur, a.tolerance, set(a.gate.split(",")))
    print(f"{'pass':<10} {'base us':>9} {'now us':>9} {'delta':>8}  (tolerance +{a.tolerance:.0%})")
    for name, b, c, d, status in rows:
        now = "-" if c is None else f"{c:9.1f}"
        dd = "-" if d is None else f"{d:+8.1%}"
        print(f"{name:<10} {b:9.1f} {now:>9} {dd:>8}  {status}")
    if slow:
        print("slower than baseline: " + ", ".join(slow))
        return 1
    return 0


def self_test():
    base = {"passes": {"a": {"median_us": 100.0}, "b": {"median_us": 10.0}, "c": {"median_us": 1.0}}}
    cur = {"passes": {"a": {"median_us": 149.0}, "b": {"median_us": 16.0}, "c": {"median_us": 9.0}}}
    rows, slow = table(base, cur, 0.5, {"a", "b"})
    assert slow == ["b"], slow
    assert [r[4] for r in rows] == ["ok", "SLOWER", "slower (not gated)"], rows
    del cur["passes"]["a"]
    assert table(base, cur, 0.5, set())[1] == ["a"]
    print("compare self-test ok")


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        self_test()
        sys.exit(0)
    sys.exit(main())
