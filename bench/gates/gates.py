#!/usr/bin/env python3
"""Release gates of docs/GATES.md, checked against bench/gates/recorded.json.

    python3 bench/gates/gates.py frame DIR      frame CPU time against the fastest comparison
    python3 bench/gates/gates.py rss DIR        resident memory against the lightest comparison
    python3 bench/gates/gates.py size FILE      binary size of each example against its budget
    python3 bench/gates/gates.py --self-test

DIR holds one bench/vs/measure.py JSON per framework, lcgr.json among them (ci/jobs/gates-vs.sh
writes them). A comparison gate holds on a scene when LCGR is no worse than the best other
framework. The recorded file says which gates held when it was last measured and by how much
LCGR missed the others. CI fails when a gate regresses: one that held no longer holds, one that
did not hold misses by more than TOLERANCE more than it did, or a recorded framework is missing.
A gate that newly holds is printed so it can be recorded. A gate that does not hold is a finding
(docs/GATES.md), printed every run; the threshold is never moved to make it hold.

Timings mean nothing on a loaded machine: when the 1-minute load average during a measurement was
above a quarter of the CPU count, timing gates are printed and not applied (as ci/jobs/bench.sh).

    python3 bench/gates/gates.py frame DIR --record    rewrite the recorded entries from DIR
"""
import argparse
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RECORDED = os.path.join(HERE, "recorded.json")
TOLERANCE = 0.5  # timings move by about a third between runs on one machine (docs/CHECKS.md)
SIZE_GROWTH = 0.02  # docs/GATES.md: growth above 2% fails CI
MEMORY_TOLERANCE = 0.1  # LCGR measured 12,476 and 12,104 KiB in two gates-vs runs (3%)
# The idle scene is gated by frames built and wake-ups (the idle gate), not by frame time.
TIMED_SCENES = ("form", "list", "text", "springs", "resize")


def versus(values, recorded, tolerance):
    """One comparison gate. values {framework: number, lower is better}, "lcgr" among them;
    recorded {"held", "ratio"} or None. Returns (entry, status, failed)."""
    others = {n: v for n, v in values.items() if n != "lcgr"}
    best = min(others, key=others.get)
    ratio = values["lcgr"] / others[best] if others[best] else float("inf")
    entry = {"held": ratio <= 1, "ratio": round(ratio, 3), "best": best}
    if recorded is None:
        return entry, "not recorded", True
    if recorded["held"] and not entry["held"]:
        return entry, "REGRESSED: held, now does not", True
    if not recorded["held"] and ratio > recorded["ratio"] * (1 + tolerance):
        return entry, f"REGRESSED: misses by more than recorded x{recorded['ratio']}", True
    if entry["held"]:
        return entry, "held" if recorded["held"] else "now holds: record it", False
    return entry, f"NOT MET (finding; recorded x{recorded['ratio']})", False


def busy(load):
    return load > (os.cpu_count() or 1) / 4


def results(d):
    out = {}
    for path in sorted(glob.glob(os.path.join(d, "*.json"))):
        with open(path) as f:
            r = json.load(f)
        out[r["name"]] = r
    if "lcgr" not in out:
        sys.exit(f"gates: no lcgr.json in {d}")
    return out


def check_frame(runs, recorded):
    """Frame CPU time: per scene, the median frame of LCGR against the fastest other framework."""
    failed, rows, entries = False, [], {}
    for scene in TIMED_SCENES:
        values = {n: r["scenes"][scene]["median_us"] for n, r in runs.items()}
        e, status, f = versus(values, recorded.get(scene), TOLERANCE)
        entries[scene] = e
        failed |= f
        rows.append(f"{scene:<8} lcgr {values['lcgr']:9.1f} us  best {e['best']:<8} {values[e['best']]:9.1f} us  x{e['ratio']:<6} {status}")
    return entries, rows, failed


def check_rss(runs, recorded):
    """Resident memory: VmRSS after the idle scene's first frame, while it waits for input
    (tools/bench/probe.py), against the lightest other framework. Pages the process maps and
    touches count, shared libraries included; the GPU driver's are not there to count, since no
    harness opens a device."""
    values = {n: r["rss_kib"] for n, r in runs.items()}
    e, status, failed = versus(values, recorded.get("idle"), MEMORY_TOLERANCE)
    row = f"idle     lcgr {values['lcgr']:9.0f} KiB best {e['best']:<8} {values[e['best']]:9.0f} KiB x{e['ratio']:<6} {status}"
    return {"idle": e}, [row], failed


CHECKS = {"frame": (check_frame, True), "rss": (check_rss, False)}  # gate: (check, timed)


def check_size(text, budgets):
    """Binary size: `zig build size` output (tools/bench/size.zig, ReleaseSmall) against the
    budget of each example, loaded bytes (text + rodata + data) and bss separately. Sizes do not
    depend on load, so this gate always applies. Returns (sizes, rows, failed)."""
    sizes, rows, failed = {}, [], False
    for line in text.splitlines():
        f = line.split()
        if len(f) != 5 or not f[1].isdigit():
            continue
        t, ro, d, bss = map(int, f[1:])
        sizes[f[0]] = {"loaded": t + ro + d, "bss": bss}
    for name, now in sizes.items():
        budget = budgets.get(name)
        for k in ("loaded", "bss"):
            if budget is None:
                status, bad = "no budget", True
            elif now[k] > budget[k] * (1 + SIZE_GROWTH):
                status, bad = f"OVER BUDGET {budget[k]} by {now[k] / budget[k] - 1:+.1%}", True
            elif now[k] < budget[k] * (1 - SIZE_GROWTH):
                status, bad = f"under budget {budget[k]} by {now[k] / budget[k] - 1:+.1%}: lower it", False
            else:
                status, bad = f"within budget {budget[k]}", False
            failed |= bad
            rows.append(f"{name:<8} {k:<7} {now[k]:>10} B  {status}")
    missing = [n for n in budgets if n not in sizes]
    rows += [f"{n:<8} no size reported" for n in missing]
    return sizes, rows, failed or bool(missing)


def run_size(path, record):
    rec = {}
    if os.path.exists(RECORDED):
        with open(RECORDED) as f:
            rec = json.load(f)
    with open(path) as f:
        sizes, rows, failed = check_size(f.read(), rec.get("size", {}))
    print("gate size: loaded bytes and bss of each example (ReleaseSmall)")
    print("\n".join(rows))
    if record:
        rec["size"] = sizes
        with open(RECORDED, "w") as f:
            json.dump(rec, f, indent=1)
            f.write("\n")
        print(f"gates: recorded size in {RECORDED}")
        return 0
    return 1 if failed else 0


def frameworks_missing(runs, recorded):
    return [n for n in recorded.get("frameworks", []) if n not in runs]


def run_compare(kind, d, record):
    rec = {}
    if os.path.exists(RECORDED):
        with open(RECORDED) as f:
            rec = json.load(f)
    runs = results(d)
    missing = frameworks_missing(runs, rec)
    check, timed = CHECKS[kind]
    entries, rows, failed = check(runs, rec.get(kind, {}))
    print(f"gate {kind}: LCGR against {', '.join(n for n in runs if n != 'lcgr')}")
    print("\n".join(rows))
    load = max(max(r["load_before"], r["load_after"]) for r in runs.values())
    if record:
        print(f"gates: load up to {load} on {os.cpu_count()} CPUs during the measurement")
        rec[kind] = entries
        rec["frameworks"] = sorted(n for n in runs if n != "lcgr")
        with open(RECORDED, "w") as f:
            json.dump(rec, f, indent=1)
            f.write("\n")
        print(f"gates: recorded {kind} in {RECORDED}")
        return 0
    if missing:
        print("gates: missing results for " + ", ".join(missing))
        return 1
    if failed and timed and busy(load):
        print(f"gates: load {load} on {os.cpu_count()} CPUs during the measurement, timing gate not applied")
        return 0
    return 1 if failed else 0


def self_test():
    # A gate that held and still holds, one that held and no longer does.
    assert versus({"lcgr": 9, "a": 10, "b": 20}, {"held": True, "ratio": 0.9}, 0.5)[2] is False
    e, s, f = versus({"lcgr": 11, "a": 10, "b": 20}, {"held": True, "ratio": 0.9}, 0.5)
    assert f and s.startswith("REGRESSED") and e == {"held": False, "ratio": 1.1, "best": "a"}, (e, s)
    # A gate that did not hold: a finding while it misses by about as much, a failure when worse.
    assert versus({"lcgr": 30, "a": 10}, {"held": False, "ratio": 2.5}, 0.5)[2] is False
    assert versus({"lcgr": 40, "a": 10}, {"held": False, "ratio": 2.5}, 0.5)[2] is True
    assert versus({"lcgr": 5, "a": 10}, {"held": False, "ratio": 2.5}, 0.5)[1] == "now holds: record it"
    assert versus({"lcgr": 5, "a": 10}, None, 0.5)[2] is True
    # Frame gate over measure.py results.
    def run(name, *medians):
        return {"name": name, "load_before": 0, "load_after": 0,
                "scenes": {s: {"median_us": m} for s, m in zip(TIMED_SCENES, medians)}}
    runs = {"lcgr": run("lcgr", 10, 10, 10, 10, 10), "a": run("a", 20, 20, 5, 20, 20)}
    entries, _, failed = check_frame(runs, {})
    assert failed and [entries[s]["held"] for s in TIMED_SCENES] == [True, True, False, True, True]
    _, _, failed = check_frame(runs, entries)
    assert not failed
    runs["lcgr"]["scenes"]["form"]["median_us"] = 30
    _, rows, failed = check_frame(runs, entries)
    assert failed and "REGRESSED" in rows[0], rows
    for r, kib in zip(runs.values(), (900, 1000)):
        r["rss_kib"] = kib
    entries, _, failed = check_rss(runs, {})
    assert failed and entries["idle"]["held"]
    runs["lcgr"]["rss_kib"] = 1001
    _, rows, failed = check_rss(runs, entries)
    assert failed and "REGRESSED" in rows[0], rows
    assert frameworks_missing(runs, {"frameworks": ["a", "b"]}) == ["b"]
    out = "example text rodata data bss\ndump 100 50 0 7\n"
    sizes, _, failed = check_size(out, {"dump": {"loaded": 150, "bss": 7}})
    assert not failed and sizes == {"dump": {"loaded": 150, "bss": 7}}
    assert check_size(out, {"dump": {"loaded": 146, "bss": 7}})[2] is True  # 2.7% over
    assert check_size(out, {"dump": {"loaded": 148, "bss": 7}})[2] is False  # 1.4% over
    assert check_size(out, {"dump": {"loaded": 150, "bss": 7}, "gone": {}})[2] is True
    assert check_size(out, {})[2] is True
    print("gates self-test ok")


def main():
    if "--self-test" in sys.argv:
        self_test()
        return 0
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("gate", choices=sorted(CHECKS) + ["size"])
    ap.add_argument("path", help="DIR of results, or for size the output of zig build size")
    ap.add_argument("--record", action="store_true")
    a = ap.parse_args()
    if a.gate == "size":
        return run_size(a.path, a.record)
    return run_compare(a.gate, a.path, a.record)


if __name__ == "__main__":
    sys.exit(main())
