#!/usr/bin/env python3
"""Compile the gate's row/label fixture at exact node counts and report object sections."""
import argparse
import re
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "bench/gates"))
from gates import SPEC_SIZES, spec_source


def fixture(nodes, *, short_last=False):
    # The gate counts descendants. Remove one label to include the root in this report.
    source = spec_source(nodes)
    leaf = "s.label(.t), "
    split = source.rpartition if short_last else source.partition
    left, removed, right = split(leaf)
    assert removed
    source = left + right
    return source + f'comptime {{ if (F.node_count != {nodes}) @compileError("wrong node count"); }}\n'


def arguments(directory, source):
    return ["--dep", "lcgr", f"-Mroot={source}", "--dep", "build_options",
            f"-Mlcgr={ROOT / 'src/lcgr.zig'}", f"-Mbuild_options={directory / 'options.zig'}"]


def section_sizes(obj):
    listing = subprocess.check_output(["objdump", "-h", obj], text=True)
    sizes = {"text": 0, "rodata": 0}
    for section, size in re.findall(r"^\s*\d+\s+\.(text|rodata)(?:\.\S+)?\s+([\da-fA-F]+)", listing, re.M):
        sizes[section] += int(size, 16)
    return sizes


def measure(directory, nodes, runs):
    source = directory / "spec.zig"
    source.write_text(fixture(nodes))
    obj = directory / "probe.o"
    seconds = []
    for run in range(runs):
        command = ["zig", "build-obj", "-OReleaseSmall", "-target", "x86_64-linux",
                   "-mcpu", "x86_64_v3", "--cache-dir", directory / f"{nodes}-{run}",
                   f"-femit-bin={obj}", *arguments(directory, source)]
        start = time.perf_counter()
        subprocess.run(command, check=True)
        seconds.append(time.perf_counter() - start)
    sizes = section_sizes(obj)
    return statistics.median(seconds), sizes["text"], sizes["rodata"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=5)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        (directory / "options.zig").write_text("pub const lanes: ?u32 = null;\n")
        print("nodes  compile_s  text_B  rodata_B", flush=True)
        for nodes in SPEC_SIZES:
            seconds, code, data = measure(directory, nodes, args.runs)
            print(f"{nodes:5} {seconds:10.3f} {code:7} {data:9}", flush=True)


if __name__ == "__main__":
    main()
