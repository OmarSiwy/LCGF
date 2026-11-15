#!/usr/bin/env python3
"""Resident-memory and idle-wakeup probe (Linux, reads /proc).

    python3 tools/bench/probe.py [--seconds 2] -- COMMAND [ARGS...]

Starts COMMAND with a pipe on stdin, waits for it to print a line starting with "ready" (its first
frame is done and it is waiting for events), then samples /proc/PID/task/*/status twice, SECONDS
apart. Prints resident memory (VmRSS, peak VmHWM) and the context switches of all its threads in
the window: each one is a wake-up, so an event-driven UI that is idle should show zero. Closing
stdin ends the command. Wall power (how the forrestthewoods.com article measured idle cost, with
a smart plug over ~5 minutes) needs hardware; wake-ups are the proxy a CI runner can count.
"""
import argparse
import glob
import subprocess
import sys
import time


def status(pid):
    """VmRSS and VmHWM in KiB, and context switches summed over threads."""
    fields = {}
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            key, _, val = line.partition(":")
            fields[key] = val.split()[0] if val.split() else ""
    switches = 0
    for path in glob.glob(f"/proc/{pid}/task/*/status"):
        with open(path) as f:
            for line in f:
                if line.startswith(("voluntary_ctxt_switches", "nonvoluntary_ctxt_switches")):
                    switches += int(line.split()[1])
    return int(fields["VmRSS"]), int(fields["VmHWM"]), switches


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=2.0)
    ap.add_argument("command", nargs="+")
    a = ap.parse_args()
    p = subprocess.Popen(a.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    line = p.stdout.readline()
    if not line.startswith("ready"):
        p.kill()
        sys.exit(f"probe: expected a 'ready' line, got {line!r}")
    time.sleep(0.2)  # let it reach its blocking read: blocking there is one switch, not idle work
    _, _, s0 = status(p.pid)
    time.sleep(a.seconds)
    rss, hwm, s1 = status(p.pid)
    wakeups = s1 - s0
    print(f"probe: {line.strip()}")
    print(f"resident  {rss} KiB  (peak {hwm} KiB)")
    print(f"idle      {wakeups} wake-ups in {a.seconds:g} s  ({wakeups / a.seconds:.1f}/s)")
    p.stdin.close()
    try:
        return p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill()
        sys.exit("probe: command did not exit when stdin closed")


if __name__ == "__main__":
    sys.exit(main())
