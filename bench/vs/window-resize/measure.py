"""Drive the eight mapped resize fixtures on a private Xvfb display."""
import argparse
from contextlib import contextmanager
import csv
import io
import json
import math
import os
from pathlib import Path
import platform
import select
import statistics
import subprocess

FRAMEWORKS = ("lcgf", "clay", "imgui", "egui", "iced", "lvgl", "slint", "qtquick")
KINDS = ("grow", "shrink", "drag-settle")


@contextmanager
def private_display():
    # Xvfb selects an unused display atomically, even when CI jobs start together.
    read_fd, write_fd = os.pipe()
    with os.fdopen(read_fd) as ready, os.fdopen(write_fd, "w") as writer:
        server = subprocess.Popen(
            ["Xvfb", "-displayfd", str(write_fd), "-screen", "0", "2800x1800x24",
             "-dpi", "96", "-nolisten", "tcp", "-noreset"], pass_fds=(write_fd,))
        try:
            writer.close()
            if not select.select([ready], [], [], 10)[0]:
                raise RuntimeError("Timed out starting private X server")
            number = ready.readline().strip()
            if not number.isdecimal():
                raise RuntimeError("Private X server failed to start")
            yield ":" + number
        finally:
            server.terminate()
            server.wait()


def measure(name, args, cpus, display, rounds):
    env = dict(os.environ, DISPLAY=display, XAUTHORITY="/dev/null", QT_QPA_PLATFORM="xcb", QT_QUICK_BACKEND="software",
               QT_SCALE_FACTOR="1", QT_AUTO_SCREEN_SCALE_FACTOR="0")
    # Only one client runs at a time. Keep polling/readback off its CPU.
    client = subprocess.Popen(["taskset", "-c", str(cpus[0]), args.bin / f"resize-{name}"], env=env)
    try:
        result = subprocess.run(["taskset", "-c", str(cpus[-1]), args.observer, str(rounds), f"resize-{name}"],
                                check=True, stdout=subprocess.PIPE, text=True, env=env)
        if client.poll() is not None:
            raise RuntimeError(f"{name} exited with {client.returncode} during the measurement")
    finally:
        client.terminate()
        try:
            client.wait(timeout=3)
        except subprocess.TimeoutExpired:
            client.kill()
            client.wait()
    samples = []
    for n, kind, elapsed, readback in csv.reader(io.StringIO(result.stdout)):
        samples.append(dict(round=int(n), kind=kind, latency_ms=float(elapsed), readback_ms=float(readback)))
    if [(row["round"], row["kind"]) for row in samples] != [
            (n, kind) for n in range(1, rounds + 1) for kind in KINDS]:
        raise RuntimeError(f"{name} returned incomplete samples")
    return samples


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", type=Path, default=Path("zig-out/bin"))
    parser.add_argument("--observer", type=Path, default=Path("zig-out/bin/resize-observe"))
    parser.add_argument("--json", type=Path, default=Path("zig-out/window-resize.json"))
    parser.add_argument("--rounds", type=int, default=25)
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("--rounds must be positive")
    cpus = sorted(os.sched_getaffinity(0))
    rows = {name: [] for name in FRAMEWORKS}
    load = []
    with private_display() as display:
        # Rotate the order between short blocks to spread changes in machine load.
        for offset in range(0, args.rounds, 5):
            count = min(5, args.rounds - offset)
            start = (3 * (offset // 5)) % len(FRAMEWORKS)
            print(f"Resize rounds {offset+1}–{offset+count}", flush=True)
            for name in FRAMEWORKS[start:] + FRAMEWORKS[:start]:
                load.append(os.getloadavg()[0])
                samples = measure(name, args, cpus, display, count)
                for sample in samples:
                    sample["round"] += offset
                rows[name].extend(samples)
    print("Resize to verified server pixels, p50 / p95 (ms)")
    print("Framework           grow           shrink      drag-settle")
    for name, samples in rows.items():
        fields = []
        for kind in KINDS:
            values = sorted(s["latency_ms"] for s in samples if s["kind"] == kind)
            p95 = values[math.ceil(.95 * len(values)) - 1]
            fields.append(f"{statistics.median(values):6.2f}/{p95:6.2f}")
        print(f"{name:<10} " + "  ".join(fields))
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(dict(client_cpu=cpus[0], observer_cpu=cpus[-1],
                                         kernel=platform.release(), load_range=[min(load), max(load)],
                                         rounds=args.rounds, samples=rows),
                                    indent=2) + "\n")


if __name__ == "__main__":
    main()
