#!/usr/bin/env python3
"""Measures one comparison harness the way docs/perf/vs.md reports it (Linux).

    python3 bench/vs/measure.py --name clay --exe zig-out/bin/vs-clay --small zig-out/bin/vs-clay-small

For every scene of bench/scenes/ it runs `EXE --scene NAME` RUNS times and keeps the median of the
per-run frame medians and p99s (each run times 3,000 frames). Then it runs tools/bench/probe.py on
`EXE --idle --scene idle` (resident memory after one frame and wake-ups while idle, median of RUNS)
and tools/bench/size.zig on SMALL (bytes of text, rodata and data: what the binary loads, without
symbols or debug info). The 1-minute load average is printed before and after: timings taken on a
loaded machine mean little, and timings never compare across machines.

Every harness speaks the protocol of tools/bench/bench.zig: a header line with `frames=N`, a line
`frame MEDIAN P99` in microseconds, and with `--idle` a line starting "ready". So `--exe` may also be
the LCGR benchmark itself (zig build vs-lcgr), which gives the reference row.
"""
import argparse
import json
import os
import re
import statistics
import subprocess
import sys

SCENES = ["form", "list", "text", "springs", "resize", "idle"]


def load():
    with open("/proc/loadavg") as f:
        return float(f.read().split()[0])


def frame(cmd):
    out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    built = int(re.search(r"\bframes=(\d+)", out).group(1))
    med, p99 = re.search(r"^frame\s+([\d.]+)\s+([\d.]+)", out, re.M).groups()
    return built, float(med), float(p99)


def probe(cmd, seconds):
    out = subprocess.run(
        [sys.executable, "tools/bench/probe.py", "--seconds", str(seconds), "--"] + cmd,
        check=True, capture_output=True, text=True).stdout
    rss, hwm = map(int, re.search(r"resident\s+(\d+) KiB\s+\(peak (\d+) KiB\)", out).groups())
    wakeups = int(re.search(r"idle\s+(\d+) wake-ups", out).group(1))
    return rss, hwm, wakeups


def libraries(cmd):
    """Bytes of the shared libraries mapped once the harness is idle (files, counted once each)."""
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    if not p.stdout.readline().startswith("ready"):
        p.kill()
        sys.exit("measure: expected a 'ready' line")
    with open(f"/proc/{p.pid}/maps") as f:
        paths = {line.split()[-1] for line in f if ".so" in line.split()[-1]}
    p.stdin.close()
    p.wait(timeout=5)
    return len(paths), sum(os.path.getsize(path) for path in paths)


def size(size_tool, exe):
    out = subprocess.run([size_tool, exe], check=True, capture_output=True, text=True).stdout
    text, rodata, data, bss = map(int, out.splitlines()[1].split()[1:])
    return text + rodata + data, bss


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--exe", required=True, help="harness built for speed")
    ap.add_argument("--small", help="harness built for size (default: --exe)")
    ap.add_argument("--size-tool", default="zig-out/bin/size")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--seconds", type=float, default=2.0, help="idle window of each probe")
    ap.add_argument("--libraries", action="store_true",
                    help="also sum the shared libraries mapped when idle (for frameworks that ship as them)")
    ap.add_argument("--json", help="also write the numbers here")
    a = ap.parse_args()

    r = {"name": a.name, "load_before": load(), "scenes": {}}
    for scene in SCENES:
        runs = [frame([a.exe, "--scene", scene]) for _ in range(a.runs)]
        r["scenes"][scene] = {
            "frames": runs[0][0],
            "median_us": statistics.median(x[1] for x in runs),
            "p99_us": statistics.median(x[2] for x in runs),
        }
    probes = [probe([a.exe, "--idle", "--scene", "idle"], a.seconds) for _ in range(a.runs)]
    r["rss_kib"] = statistics.median(p[0] for p in probes)
    r["peak_kib"] = statistics.median(p[1] for p in probes)
    r["idle_wakeups_per_s"] = statistics.median(p[2] for p in probes) / a.seconds
    r["loaded_bytes"], r["bss_bytes"] = size(a.size_tool, a.small or a.exe)
    if a.libraries:
        r["libraries"], r["library_bytes"] = libraries([a.exe, "--idle", "--scene", "idle"])
    r["load_after"] = load()

    print(f"{a.name}: medians of {a.runs} runs, load {r['load_before']:.2f} -> {r['load_after']:.2f}")
    print(f"{'scene':<8} {'frames':>6} {'median us':>9} {'p99 us':>9}")
    for scene, s in r["scenes"].items():
        print(f"{scene:<8} {s['frames']:>6} {s['median_us']:>9.1f} {s['p99_us']:>9.1f}")
    print(f"resident {r['rss_kib']:.0f} KiB (peak {r['peak_kib']:.0f} KiB), "
          f"idle {r['idle_wakeups_per_s']:.1f} wake-ups/s, "
          f"binary {r['loaded_bytes']} B loaded + {r['bss_bytes']} B bss")
    if a.libraries:
        print(f"shared libraries mapped when idle: {r['libraries']} files, {r['library_bytes']} B")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(r, f, indent=1)


if __name__ == "__main__":
    main()
