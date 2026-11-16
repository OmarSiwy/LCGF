#!/usr/bin/env python3
"""Release gates of docs/GATES.md, checked against bench/gates/recorded.json.

    python3 bench/gates/gates.py frame DIR      frame CPU time against the fastest comparison
    python3 bench/gates/gates.py rss DIR        resident memory against the lightest comparison
    python3 bench/gates/gates.py first-frame DIR   time to first frame against the lightest comparison
    python3 bench/gates/gates.py measure-first-frame JSON EXE   add EXE's time to first frame to JSON
    python3 bench/gates/gates.py idle FILE      zero frames and zero wake-ups while idle
    python3 bench/gates/gates.py latency FILE   input-to-photon latency against its budget
    python3 bench/gates/gates.py compile-time       comptime front end compile time against its budget
    python3 bench/gates/gates.py census         every census probe is in the census object
    python3 bench/gates/gates.py size FILE      binary size of each example against its budget
    python3 bench/gates/gates.py table [--write]  the published table in bench/gates/README.md
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
import re
import statistics
import subprocess
import sys
import tempfile
import time

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
    entry = {"held": ratio <= 1, "ratio": round(ratio, 3), "best": best, "values": values}
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


def measure_first_frame(exe, runs=11):
    """Median milliseconds from starting `exe --idle --scene idle` to its "ready" line: process
    start, loading, setup and the first frame, until the harness waits for input (the protocol of
    bench/vs/measure.py)."""
    times = []
    for _ in range(runs):
        t0 = time.perf_counter()
        p = subprocess.Popen([exe, "--idle", "--scene", "idle"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        line = p.stdout.readline()
        times.append((time.perf_counter() - t0) * 1000)
        p.stdin.close()
        p.wait(timeout=10)
        if not line.startswith("ready"):
            sys.exit(f"gates: {exe} printed {line!r}, not a ready line")
    return statistics.median(times)


def check_first_frame(runs, recorded):
    """Time to first frame (measure_first_frame), LCGR against the lightest other framework."""
    values = {n: r["first_frame_ms"] for n, r in runs.items()}
    e, status, failed = versus(values, recorded.get("idle"), TOLERANCE)
    row = f"idle     lcgr {values['lcgr']:9.2f} ms  best {e['best']:<8} {values[e['best']]:9.2f} ms  x{e['ratio']:<6} {status}"
    return {"idle": e}, [row], failed


CHECKS = {"frame": (check_frame, True), "rss": (check_rss, False), "first-frame": (check_first_frame, True)}  # gate: (check, timed)


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


def check_idle(text):
    """Idle (target D5): in the output of the benchmark's idle scene, frames built of its 3,000
    unchanged polls, and in tools/bench/probe.py's, wake-ups while waiting after the first frame.
    The two frames allowed are the first frame and the one settle frame after it
    (bench/scenes/idle.zig); every poll after them must build nothing. Not timed: always applies.
    Returns failure lines, empty when the gate holds."""
    frames = re.search(r"scene=idle\b.*\bframes=(\d+)", text)
    wakeups = re.search(r"^idle\s+(\d+) wake-ups", text, re.M)
    bad = []
    if not frames or not wakeups:
        return ["idle: no 'scene=idle ... frames=' line or no probe 'idle N wake-ups' line"]
    if int(frames.group(1)) > 2:
        bad.append(f"idle: {frames.group(1)} frames built of unchanged polls, more than the first and the settle frame")
    if int(wakeups.group(1)) != 0:
        bad.append(f"idle: {wakeups.group(1)} wake-ups while waiting for input")
    return bad


def check_latency(text, budget, load):
    """Input-to-photon latency: the line of bench/gates/latency.zig (zig build gates-latency).
    Every pointer move must show in the first frame presented after it (late=0, always applied),
    and the median time from the event to the pixels must stay within the recorded budget plus
    TOLERANCE (timed: not applied above load nproc/4). Returns (median_us, failure lines)."""
    m = re.search(r"latency late=(\d+) polls=\d+ median_us=([\d.]+)", text)
    if not m:
        return None, ["latency: no 'latency late=N ... median_us=M' line"]
    late, median = int(m.group(1)), float(m.group(2))
    bad = [f"latency: {late} moves shown a frame late"] if late else []
    if budget is None:
        bad.append("latency: no budget recorded")
    elif median > budget * (1 + TOLERANCE) and not busy(load):
        bad.append(f"latency: median {median} us over the budget {budget} us by more than {TOLERANCE:.0%}")
    return median, bad


SPEC_SIZES = (100, 1000, 10000)


def spec_source(nodes):
    """A Zig file flattening a spec of nodes + 1 nodes (a column of nodes / 10 rows, each a row
    of 9 labels) with the comptime front end (src/comptime/flatten.zig), and exporting a read of
    one table so the flatten is analysed."""
    rows = ", ".join("s.row(.{}, .{" + ", ".join(["s.label(.t)"] * 9) + "})" for _ in range(nodes // 10))
    return f"""const lcgr = @import("lcgr");
const s = lcgr.spec;
const F = blk: {{
    @setEvalBranchQuota(100_000_000);
    break :blk lcgr.flatten.Flat(s.col(.{{}}, .{{{rows}}}));
}};
export fn probe(i: u32) u32 {{
    return F.parent[i % F.node_count];
}}
"""


def measure_compile_time(runs=5):
    """Median seconds of `zig build-obj -fno-emit-bin` (parse and semantic analysis, where the
    comptime flatten runs; no code generation) per spec size, each run with an empty cache. The
    generated files live in a temporary directory, outside the tree `zig fmt` checks."""
    with tempfile.TemporaryDirectory() as d:
        return compile_times(d, runs)


def compile_times(d, runs):
    root = os.path.dirname(os.path.dirname(HERE))
    with open(os.path.join(d, "options.zig"), "w") as f:
        f.write("pub const lanes: ?u32 = null;\n")
    out = {}
    for n in SPEC_SIZES:
        src = os.path.join(d, f"spec{n}.zig")
        with open(src, "w") as f:
            f.write(spec_source(n))
        times = []
        for k in range(runs):
            cache = os.path.join(d, f"cache{n}-{k}")
            subprocess.run(["rm", "-rf", cache], check=True)
            cmd = ["zig", "build-obj", "-fno-emit-bin", "-OReleaseFast", "--cache-dir", cache,
                   "--dep", "lcgr", f"-Mroot={src}",
                   "--dep", "build_options", f"-Mlcgr={os.path.join(root, 'src', 'lcgr.zig')}",
                   f"-Mbuild_options={os.path.join(d, 'options.zig')}"]
            t0 = time.perf_counter()
            subprocess.run(cmd, check=True)
            times.append(time.perf_counter() - t0)
        out[str(n)] = round(statistics.median(times), 3)
    return out


def check_compile_time(seconds, budgets, load):
    """Compile time per spec size within its recorded budget plus TOLERANCE (timed: not applied
    above load nproc/4). Returns (rows, failed)."""
    rows, failed = [], False
    for n, sec in seconds.items():
        b = budgets.get(n)
        if b is None:
            status, bad = "no budget", True
        elif sec > b * (1 + TOLERANCE):
            status, bad = f"OVER BUDGET {b} s by {sec / b - 1:+.0%}", not busy(load)
        else:
            status, bad = f"within budget {b} s", False
        failed |= bad
        rows.append(f"{n:>6} nodes {sec:7.3f} s  {status}")
    return rows, failed


def check_census(src):
    """Branches in hot loops (docs/CHECKS.md section 2): the census jobs fail when a function of
    the census object gains a conditional jump over tools/census/baseline*.json, but only for
    functions in the object. A probe file (src/**/census_probe*.zig) that src/census_probes.zig
    does not import is never disassembled, so its passes could gain any jump unseen. Returns the
    probe files missing from the object's root, relative to src."""
    with open(os.path.join(src, "census_probes.zig")) as f:
        imported = set(re.findall(r'@import\("([^"]+)"\)', f.read()))
    probes = sorted(os.path.relpath(p, src) for p in glob.glob(os.path.join(src, "**", "census_probe*.zig"), recursive=True))
    return [p for p in probes if p not in imported and p != "census_probes.zig"]


README = os.path.join(HERE, "README.md")
BEGIN, END = "<!-- gates table: generated by gates.py table --write -->", "<!-- end of gates table -->"
NAMES = {"lcgr": "LCGR", "clay": "Clay", "imgui": "Dear ImGui", "lvgl": "LVGL", "egui": "egui",
         "iced": "Iced", "slint": "Slint", "qtquick": "Qt Quick"}


def table(rec):
    """The recorded measurements as Markdown: the comparison per framework, then every gate."""
    names = ["lcgr"] + rec["frameworks"]
    rows = [("frame", s, f"Frame CPU time, {s} (median us)", "{:,.1f}") for s in TIMED_SCENES]
    rows += [("rss", "idle", "Resident memory after one idle frame (KiB)", "{:,.0f}"),
             ("first-frame", "idle", "Time to first frame (ms)", "{:,.2f}")]
    out = ["| | " + " | ".join(NAMES.get(n, n) for n in names) + " | Gate |",
           "|---|" + "---|" * (len(names) + 1)]
    for kind, key, label, fmt in rows:
        e = rec[kind][key]
        verdict = "held" if e["held"] else f"not met: x{e['ratio']} of {NAMES.get(e['best'], e['best'])}"
        low = min(e["values"].values())  # the lowest of the row, LCGR included, in bold
        cells = [("**" + fmt.format(e["values"][n]) + "**") if e["values"][n] == low else fmt.format(e["values"][n]) for n in names]
        out.append(f"| {label} | " + " | ".join(cells) + f" | {verdict} |")
    out += ["", "| Gate | Budget or rule | Recorded |", "|---|---|---|"]
    for name, b in rec["size"].items():
        out.append(f"| Binary size, {name} | loaded and bss each within 2% of the budget | {b['loaded']:,} B loaded, {b['bss']:,} B bss |")
    out.append(f"| Input-to-photon latency | every move shown in the first frame; median within 50% of the budget | {rec['latency_us']} us median |")
    for n, sec in rec["compile_time_s"].items():
        out.append(f"| Compile time, {int(n):,}-node spec | within 50% of the budget | {sec} s |")
    out.append("| Idle | at most the first and the settle frame of 3,000 unchanged polls, 0 wake-ups | checked every run (all) |")
    out.append("| Branches in hot loops | census baselines, every probe file in the census object | checked every run (all) |")
    return "\n".join(out)


def publish(write):
    """Puts table() between the markers of README. Returns False when the README's table is not
    the recorded one (and write is off): a re-recorded gate must be republished."""
    with open(RECORDED) as f:
        rec = json.load(f)
    with open(README) as f:
        text = f.read()
    head, rest = text.split(BEGIN, 1)
    _, tail = rest.split(END, 1)
    new = head + BEGIN + "\n" + table(rec) + "\n" + END + tail
    if write:
        with open(README, "w") as f:
            f.write(new)
    return new == text


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
    assert f and s.startswith("REGRESSED") and e["held"] is False and e["ratio"] == 1.1 and e["best"] == "a", (e, s)
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
    for r, ms in zip(runs.values(), (1.0, 2.0)):
        r["first_frame_ms"] = ms
    entries, _, failed = check_first_frame(runs, {})
    assert (entries["idle"]["held"], entries["idle"]["ratio"]) == (True, 0.5)
    runs["lcgr"]["first_frame_ms"] = 3.0
    assert check_first_frame(runs, entries)[2] is True
    ok = "scene=idle core=src nodes=200 frames=2 polls=3000\nidle      0 wake-ups in 2 s  (0.0/s)\n"
    assert check_idle(ok) == []
    assert len(check_idle(ok.replace("frames=2", "frames=3"))) == 1
    assert len(check_idle(ok.replace("idle      0", "idle      4"))) == 1
    assert len(check_idle("")) == 1
    line = "latency late=0 polls=4000 median_us=356.3 p99_us=388.5\n"
    assert check_latency(line, 356.3, 0) == (356.3, [])
    assert len(check_latency(line, 200.0, 0)[1]) == 1
    assert check_latency(line, 200.0, 1e9)[1] == []  # loaded: the timing is not applied
    assert len(check_latency(line.replace("late=0", "late=3"), 356.3, 1e9)[1]) == 1
    assert spec_source(20).count("s.label(.t)") == 18
    assert check_compile_time({"100": 0.1}, {"100": 0.1}, 0) == (["   100 nodes   0.100 s  within budget 0.1 s"], False)
    assert check_compile_time({"100": 0.2}, {"100": 0.1}, 0)[1] is True
    assert check_compile_time({"100": 0.2}, {"100": 0.1}, 1e9)[1] is False
    assert check_compile_time({"100": 0.1}, {}, 0)[1] is True
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, "a"))
        for p in ("a/census_probe.zig", "a/census_probe_b.zig", "census_probes.zig"):
            open(os.path.join(d, p), "w").close()
        with open(os.path.join(d, "census_probes.zig"), "w") as f:
            f.write('comptime {\n    _ = @import("a/census_probe.zig");\n}\n')
        assert check_census(d) == ["a/census_probe_b.zig"]
    rec = {"frameworks": ["a"], "frame": {}, "size": {"x": {"loaded": 1, "bss": 2}}, "latency_us": 3,
           "compile_time_s": {"100": 0.1}}
    for kind, values in (("frame", {"lcgr": 1.0, "a": 2.0}), ("rss", {"lcgr": 3, "a": 2}), ("first-frame", {"lcgr": 1, "a": 1})):
        for key in (TIMED_SCENES if kind == "frame" else ("idle",)):
            rec.setdefault(kind, {})[key] = versus(values, None, 0)[0]
    t = table(rec)
    assert "| Frame CPU time, form (median us) | **1.0** | 2.0 | held |" in t, t
    assert "| Resident memory after one idle frame (KiB) | 3 | **2** | not met: x1.5 of a |" in t, t
    assert "| Time to first frame (ms) | **1.00** | **1.00** | held |" in t, t
    print("gates self-test ok")


def main():
    if "--self-test" in sys.argv:
        self_test()
        return 0
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("gate", choices=sorted(CHECKS) + ["size", "idle", "latency", "compile-time", "census", "table", "measure-first-frame"])
    ap.add_argument("path", nargs="?", help="DIR of results, or for size the output of zig build size")
    ap.add_argument("exe", nargs="?", help="for measure-first-frame: the harness")
    ap.add_argument("--record", action="store_true")
    ap.add_argument("--write", action="store_true", help="for table: rewrite the README's table")
    a = ap.parse_args()
    if a.gate == "measure-first-frame":
        with open(a.path) as f:
            r = json.load(f)
        r["first_frame_ms"] = measure_first_frame(a.exe)
        with open("/proc/loadavg") as f:  # the timing gates' load check covers this run too
            r["load_after"] = max(r["load_after"], float(f.read().split()[0]))
        with open(a.path, "w") as f:
            json.dump(r, f, indent=1)
        print(f"{r['name']}: first frame {r['first_frame_ms']:.2f} ms")
        return 0
    if a.gate == "idle":
        with open(a.path) as f:
            bad = check_idle(f.read())
        print("gate idle: " + ("; ".join(bad) if bad else "held: 2 frames of 3,000 polls at most, 0 wake-ups"))
        return 1 if bad else 0
    if a.gate == "latency":
        rec = {}
        if os.path.exists(RECORDED):
            with open(RECORDED) as f:
                rec = json.load(f)
        with open("/proc/loadavg") as f:
            load = float(f.read().split()[0])
        if os.environ.get("GITHUB_ACTIONS"):
            load = float("inf")  # the budget is from the owner's machine: timings never compare across machines
        with open(a.path) as f:
            median, bad = check_latency(f.read(), rec.get("latency_us"), load)
        if a.record and median is not None:
            rec["latency_us"] = median
            with open(RECORDED, "w") as f:
                json.dump(rec, f, indent=1)
                f.write("\n")
            print(f"gates: recorded latency budget {median} us (load {load})")
            return 0
        note = ", timing not applied" if busy(load) else ""
        print(f"gate latency: median {median} us, budget {rec.get('latency_us')} us, load {load}{note}: " + ("; ".join(bad) or "held"))
        return 1 if bad else 0
    if a.gate == "table":
        current = publish(a.write)
        print("gate table: bench/gates/README.md " + ("shows the recorded measurements" if current else "is not the recorded table: run gates.py table --write"))
        return 0 if current else 1
    if a.gate == "census":
        missing = check_census(os.path.join(os.path.dirname(os.path.dirname(HERE)), "src"))
        for p in missing:
            print(f"gate census: src/{p} is not imported by src/census_probes.zig: its passes are not censused")
        if not missing:
            print("gate census: every census probe file is in the census object")
        return 1 if missing else 0
    if a.gate == "compile-time":
        rec = {}
        if os.path.exists(RECORDED):
            with open(RECORDED) as f:
                rec = json.load(f)
        seconds = measure_compile_time()
        with open("/proc/loadavg") as f:
            load = float(f.read().split()[0])
        if os.environ.get("GITHUB_ACTIONS"):
            load = float("inf")  # the budget is from the owner's machine: timings never compare across machines
        rows, failed = check_compile_time(seconds, rec.get("compile_time_s", {}), load)
        print(f"gate compile-time: comptime front end, load {load}" + (", timing not applied" if busy(load) else ""))
        print("\n".join(rows))
        if a.record:
            rec["compile_time_s"] = seconds
            with open(RECORDED, "w") as f:
                json.dump(rec, f, indent=1)
                f.write("\n")
            print(f"gates: recorded compile-time budgets in {RECORDED}")
            return 0
        return 1 if failed else 0
    if a.gate == "size":
        return run_size(a.path, a.record)
    return run_compare(a.gate, a.path, a.record)


if __name__ == "__main__":
    sys.exit(main())
