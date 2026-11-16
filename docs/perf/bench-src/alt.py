# Alternates --core=prototype and --core=src runs of every bench scene, ROUNDS rounds, and prints
# the median of the per-run medians per frame pass as a markdown table (docs/perf/bench-src.md).
#   python3 docs/perf/bench-src/alt.py PATH_TO_BENCH_EXE ROUNDS
import subprocess, sys, statistics, os
exe, rounds = sys.argv[1], int(sys.argv[2])
scenes = ["rows", "form", "list", "text", "springs", "resize", "idle"]
passes = ["begin+hit", "build", "layout", "paint", "frame"]
res = {}
loads = []
for r in range(rounds):
    for s in scenes:
        for c in (["prototype", "src"] if r % 2 == 0 else ["src", "prototype"]):
            out = subprocess.run([exe, "--core=" + c, "--scene", s], capture_output=True, text=True, check=True).stdout
            for line in out.splitlines():
                f = line.split()
                if f and f[0] in passes:
                    res.setdefault((s, f[0], c), []).append(float(f[1]))
    loads.append(os.getloadavg()[0])
print(f"rounds={rounds} load1 per round={loads} cpus={os.cpu_count()}")
print("| scene | pass | prototype us | src us | src/prototype |")
print("|---|---|---:|---:|---:|")
for s in scenes:
    for p in passes:
        a = statistics.median(res[(s, p, "prototype")]); b = statistics.median(res[(s, p, "src")])
        print(f"| {s} | {p} | {a:.1f} | {b:.1f} | {b / a if a else 0:.2f} |")
