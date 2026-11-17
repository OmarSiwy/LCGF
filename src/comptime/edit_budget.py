#!/usr/bin/env python3
"""Time real spec edits in one incremental Zig compiler process per fixture (x86_64-linux)."""
import statistics
import struct
import subprocess
import tempfile
import time
from pathlib import Path

from budget import SPEC_SIZES, arguments, fixture


def update(compiler):
    # Client.update through Server.error_bundle in the pinned Zig std/zig protocol.
    compiler.stdin.write(struct.pack("<II", 1, 0))
    compiler.stdin.flush()
    digest = None
    while True:
        header = compiler.stdout.read(8)
        if len(header) != 8:
            raise RuntimeError("Zig exited before reporting the update")
        tag, length = struct.unpack("<II", header)
        body = compiler.stdout.read(length)
        if tag == 2:
            digest = body[1:].hex()
        if tag == 1:
            if body != bytes(8) or digest is None:
                raise RuntimeError(f"Zig update failed: {body[8:]!r}")
            return digest


def measure(directory, nodes):
    # Alternate the short row between the beginning and end. Node 10 alternates
    # between a child of the root (0) and a label under the first row (1).
    first = fixture(nodes)
    last = fixture(nodes, short_last=True)
    main = "\npub fn main() u8 { return @intCast(probe(10)); }\n"
    source = directory / "spec.zig"
    cache = directory / str(nodes)
    source.write_text(first + main)
    command = ["zig", "build-exe", "-fincremental", "-fno-llvm", "--name", "probe",
               "--cache-dir", cache, *arguments(directory, source), "--listen=-"]
    compiler = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        samples = []
        for run in range(6):
            if run:
                source.write_text((last if run % 2 else first) + main)
            start = time.perf_counter()
            digest = update(compiler)
            elapsed = time.perf_counter() - start
            if run:
                samples.append(elapsed)
            exe = cache / "o" / digest / "probe"
            if subprocess.run([exe]).returncode != run % 2:
                raise RuntimeError(f"stale generated parent table after update {run}")
        compiler.stdin.write(struct.pack("<II", 0, 0))
        compiler.stdin.flush()
        if compiler.wait(timeout=30):
            raise RuntimeError("Zig exited unsuccessfully")
        return statistics.median(samples)
    finally:
        compiler.kill()
        compiler.wait()
        compiler.stdin.close()
        compiler.stdout.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        (directory / "options.zig").write_text("pub const lanes: ?u32 = null;\n")
        for n in SPEC_SIZES:
            print(f"{n:5} nodes  {measure(directory, n) * 1000:8.2f} ms", flush=True)
