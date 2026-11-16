# Usage: CPU=12 python3 docs/perf/bench-src/alt2.py BEFORE_EXE AFTER_EXE ROUNDS (docs/perf/port-perf.md)
# Pinned alternation of two bench binaries (before, after), both cores, every scene.
import subprocess, sys, statistics, os
before, after, rounds = sys.argv[1], sys.argv[2], int(sys.argv[3])
scenes = ["rows", "form", "list", "text", "springs", "resize", "idle"]
passes = ["build", "layout", "paint", "frame"]
res, loads = {}, []
runs = [("before", before, "prototype"), ("before", before, "src"), ("after", after, "prototype"), ("after", after, "src")]
for r in range(rounds):
    for s in scenes:
        for tag, exe, core in (runs if r % 2 == 0 else runs[::-1]):
            out = subprocess.run(["taskset", "-c", os.environ.get("CPU", "2"), exe, "--core=" + core, "--scene", s], capture_output=True, text=True, check=True).stdout
            for line in out.splitlines():
                f = line.split()
                if f and f[0] in passes: res.setdefault((s, f[0], tag, core), []).append(float(f[1]))
    loads.append(round(os.getloadavg()[0], 1))
print(f"rounds={rounds} load1 per round={loads}")
print("| scene | pass | prototype | src before | src after | after/prototype |")
print("|---|---|---:|---:|---:|---:|")
m = lambda *k: statistics.median(res[k])
for s in scenes:
    for p in passes:
        pr = statistics.median(res[(s, p, "before", "prototype")] + res[(s, p, "after", "prototype")])
        b, a = m(s, p, "before", "src"), m(s, p, "after", "src")
        print(f"| {s} | {p} | {pr:.1f} | {b:.1f} | {a:.1f} | {a / pr:.2f} |")
