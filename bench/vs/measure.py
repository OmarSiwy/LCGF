#!/usr/bin/env python3
"""Measures one comparison harness the way docs/perf/vs.md reports it (Linux).

    python3 bench/vs/measure.py --name clay --exe zig-out/bin/vs-clay --small zig-out/bin/vs-clay-small

For every scene of bench/scenes/ it runs `EXE --scene NAME` RUNS times and keeps the median of the
per-run poll medians and p99s (each run times 3,000 polls). Then it runs bench/micro/probe.py on
`EXE --idle --scene idle` (resident memory after one frame and wake-ups while idle, median of RUNS)
and bench/micro/size.zig on SMALL (bytes of text, rodata and data: what the binary loads, without
symbols or debug info). The 1-minute load average is printed before and after: timings taken on a
loaded machine mean little, and timings never compare across machines.

Every harness speaks the protocol of bench/micro/bench.zig: a header line with `frames=N`, a line
`frame MEDIAN P99` in microseconds over every poll (LCGF's `poll` line, when there is one), and with `--idle` a line starting "ready". So `--exe` may also be
the LCGF benchmark itself (zig build vs-lcgf), which gives the reference row.
"""
import argparse
import json
import math
import os
import re
import select
import statistics
import subprocess
import sys
import time

SCENES = ["form", "list", "text", "springs", "resize", "idle"]


POLLS = 3000


def load():
    with open("/proc/loadavg") as f:
        return float(f.read().split()[0])


def validate_scene(name, scene, built, med, p99):
    if type(built) is not int or not 0 <= built <= POLLS or (scene != "idle" and built == 0):
        raise ValueError(f"{name}/{scene}: invalid output frame count {built!r}")
    # These immediate-mode adapters emit a visible command list on every poll.
    if name in ("microui", "nuklear", "clay") and built != POLLS:
        raise ValueError(f"{name}/{scene}: expected {POLLS} frames, saw {built}")
    if (any(type(t) not in (int, float) or not math.isfinite(t) for t in (med, p99))
            or not 0 <= med <= p99):
        raise ValueError(f"{name}/{scene}: invalid median/p99 {med!r}/{p99!r}")


def parse_frame(out, scene):
    header = re.search(r"^.*\bscene=([^\s]+).*?\bframes=(\d+)\s+polls=(\d+)(?:\s|$)", out, re.M)
    if not header or header[1] != scene or int(header[3]) != POLLS:
        raise ValueError(f"{scene}: expected a measurement of {POLLS} polls for this scene")
    # LCGF's diagnostic bench prints both timings. Use every poll for comparisons.
    def line(name):
        return re.search(rf"^{name}\s+([\d.]+)\s+([\d.]+)(?:\s|$)", out, re.M)
    timing = line("poll") or line("frame")
    if not timing:
        raise ValueError(f"{scene}: missing median/p99 timing")
    return dict(frames=int(header[2]), median_us=float(timing[1]), p99_us=float(timing[2]))


def measure_scene(command, scene, footprint=False, timeout=600):
    cmd = [*command, "--scene", scene]
    if not footprint:
        out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
        return parse_frame(out, scene)

    # The result marker is written after every timed poll. Keep this exact process
    # alive until Linux has reported its resident pages and process high-water mark.
    with subprocess.Popen([*cmd, "--hold-after-scene"], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as child:
        deadline = time.monotonic() + timeout
        data = bytearray()
        try:
            while b"\nscene complete\n" not in data:
                if len(data) > 65536:
                    raise ValueError(f"{scene}: harness did not return a complete scene result")
                remaining = max(0, deadline - time.monotonic())
                if not select.select([child.stdout], [], [], remaining)[0]:
                    raise TimeoutError(f"{scene}: timed out waiting for scene completion")
                chunk = os.read(child.stdout.fileno(), 4096)
                if not chunk:
                    raise ValueError(f"{scene}: harness did not return a complete scene result")
                data.extend(chunk)
                # An adapter can print diagnostics before it finishes a long scene.
                # The shared driver always flushes the timings and marker together.
                if b"\nframe " in data:
                    deadline = min(deadline, time.monotonic() + 5)
            sample = parse_frame(data.decode(), scene)
            with open(f"/proc/{child.pid}/status") as status:
                for line in status:
                    field, _, value = line.partition(":")
                    if field in ("VmRSS", "VmHWM"):
                        kib, unit = value.split()
                        if unit != "kB":
                            raise ValueError(f"unexpected {field} unit {unit}")
                        sample["rss_kib" if field == "VmRSS" else "peak_kib"] = int(kib)
            if "rss_kib" not in sample or "peak_kib" not in sample:
                raise ValueError(f"{scene}: missing process memory readings")
            # Closing stdin acknowledges the sample. Drain any trailing adapter output.
            child.communicate(timeout=10)
            if child.returncode:
                raise subprocess.CalledProcessError(child.returncode, child.args)
            return sample
        finally:
            if child.poll() is None:
                child.kill()


def summarize_scene(name, scene, samples):
    for s in samples:
        validate_scene(name, scene, s["frames"], s["median_us"], s["p99_us"])
    result = dict(frames=statistics.median_low(s["frames"] for s in samples),
                  median_us=statistics.median(s["median_us"] for s in samples),
                  p99_us=statistics.median(s["p99_us"] for s in samples), samples=samples)
    if any("rss_kib" in s or "peak_kib" in s for s in samples):
        for sample in samples:
            rss, peak = sample.get("rss_kib"), sample.get("peak_kib")
            if type(rss) is not int or type(peak) is not int or not 0 < rss <= peak:
                raise ValueError(f"{name}/{scene}: invalid process memory readings {rss!r}/{peak!r}")
        for field in ("rss_kib", "peak_kib"):
            result[field] = statistics.median(s[field] for s in samples)
    return result


def probe(cmd, seconds):
    out = subprocess.run(
        [sys.executable, "bench/micro/probe.py", "--seconds", str(seconds), "--"] + cmd,
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
        paths = set()
        for line in f:
            fields = line.rstrip().split(maxsplit=5)
            if len(fields) == 6 and fields[5].startswith("/") and ".so" in os.path.basename(fields[5]):
                paths.add(fields[5].replace(r"\040", " "))
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
    ap.add_argument("--startup", help="harness for resident memory and start-up (default: --exe); "
                    "a static build, for a framework compared with a static row")
    ap.add_argument("--size-tool", default="zig-out/bin/size")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--seconds", type=float, default=2.0, help="idle window of each probe")
    ap.add_argument("--libraries", action="store_true",
                    help="also sum the shared libraries mapped when idle (for frameworks that ship as them)")
    ap.add_argument("--scene-memory", action="store_true",
                    help="sample the speed build's resident and peak KiB after each scene (requires --hold-after-scene)")
    ap.add_argument("--json", help="also write the numbers here")
    a = ap.parse_args()

    if a.runs < 1 or not math.isfinite(a.seconds) or a.seconds <= 0:
        ap.error("--runs and --seconds must be positive")
    r = {"name": a.name, "runs": a.runs, "idle_seconds": a.seconds, "load_before": load(), "scenes": {}}
    for scene in SCENES:
        runs = [measure_scene([a.exe], scene, a.scene_memory) for _ in range(a.runs)]
        r["scenes"][scene] = summarize_scene(a.name, scene, runs)
    probes = [probe([a.startup or a.exe, "--idle", "--scene", "idle"], a.seconds) for _ in range(a.runs)]
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
