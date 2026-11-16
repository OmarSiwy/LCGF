#!/usr/bin/env python3
"""Start-up time and memory of a probe that prints a "ready" line and waits for stdin to close
(src/render/gompute/probe.zig, src/render/vk/probe.zig):

    python3 src/render/gompute/measure.py [--runs 5] -- COMMAND [ARGS...]

Per run: wall time from spawn to the ready line, resident memory (VmRSS) and the GPU memory
nvidia-smi reports for the process (compute and graphics processes alike). Prints the median of
each over the runs, and the ready line of the last run.
"""
import argparse
import statistics
import subprocess
import time


def gpu_mib(pid):
    """GPU memory nvidia-smi attributes to `pid`, in MiB, or None when it lists none."""
    out = subprocess.run(["nvidia-smi", "-q", "-d", "PIDS"], capture_output=True, text=True).stdout
    used = None
    lines = out.splitlines()
    for i, line in enumerate(lines):
        if line.strip().startswith("Process ID") and line.split(":")[1].strip() == str(pid):
            for follow in lines[i + 1 : i + 8]:
                if "Used GPU Memory" in follow:
                    used = int(follow.split(":")[1].split()[0])
                    break
    return used


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("command", nargs="+")
    a = ap.parse_args()
    start, rss, gpu = [], [], []
    line = ""
    for _ in range(a.runs):
        t0 = time.perf_counter()
        p = subprocess.Popen(a.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        line = p.stdout.readline().strip()
        start.append((time.perf_counter() - t0) * 1000)
        if not line.startswith("ready"):
            p.kill()
            raise SystemExit(f"measure: expected a 'ready' line, got {line!r}")
        time.sleep(0.3)
        with open(f"/proc/{p.pid}/status") as f:
            rss.append(next(int(x.split()[1]) for x in f if x.startswith("VmRSS")))
        gpu.append(gpu_mib(p.pid))
        p.stdin.close()
        p.wait(timeout=10)
    used = [x for x in gpu if x is not None]
    gpu_text = f"{statistics.median(used):.0f} MiB" if used else "not listed"
    print(f"measure: {line}")
    print(f"start-up {statistics.median(start):.0f} ms (median of {a.runs}; min {min(start):.0f}, max {max(start):.0f})")
    print(f"resident {statistics.median(rss) / 1024:.1f} MiB, GPU memory {gpu_text}")


if __name__ == "__main__":
    main()
