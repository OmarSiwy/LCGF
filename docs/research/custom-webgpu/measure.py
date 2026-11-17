"""Time the same scene in four states. Select one Vulkan ICD in the environment."""
import argparse
import csv
import os
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("bin", type=Path, help="Directory with both ReleaseFast probe binaries")
parser.add_argument("--rounds", type=int, default=10)
args = parser.parse_args()
if args.rounds < 1:
    parser.error("rounds must be positive")

# Rotate and reverse to distribute warm caches and load drift across cases.
cases = [("native", "native"), ("webgpu", "native"), ("webgpu", "cached"), ("webgpu", "guest")]
writer = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
writer.writerow(["round", "binary", "mode", "load1", "frames", "redraws",
                 "cpu_us", "frame_us", "thread_us", "app_us"])
for r in range(args.rounds):
    order = cases[r % len(cases):] + cases[:r % len(cases)]
    for binary, mode in (order if r % 2 == 0 else reversed(order)):
        load = os.getloadavg()[0]
        result = subprocess.run([args.bin / ("custom-draw-" + binary), mode],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                check=True, text=True)
        fields = result.stdout.strip().split()
        if fields[:2] != ["ready", mode]:
            raise ValueError(result.stdout)
        data = dict(field.split("=", 1) for field in fields[2:])
        expected = 2000 if mode == "guest" else 0
        if int(data["frames"]) != 2000 or int(data["redraws"]) != expected:
            raise ValueError(result.stdout)
        writer.writerow([r, binary, mode, f"{load:.2f}", *[data[key] for key in
                         ("frames", "redraws", "cpu_us", "frame_us", "thread_us", "app_us")]])
        sys.stdout.flush()
