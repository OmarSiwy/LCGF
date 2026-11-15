#!/usr/bin/env python3
"""Branch census: count conditional jumps in the hot functions of an object file.

    python3 tools/census/census.py OBJ [--prefix p_]

Disassembles OBJ with objdump and reports, for every function whose name starts
with the prefix, its conditional jumps. A backward jump is loop control. A short
forward jump inside a per-row loop is a branch the data can mispredict: the gate
is that per-row loops contain loop-control jumps only (docs/CHECKS.md section 2).

Today OBJ is prototype/zig-out/asm_probe.o (`zig build census-obj -Dcpu=x86_64_v3`
in prototype/). To census src/, build an object that exports one function per
pass under a common prefix and pass that object and prefix.
"""
import argparse
import re
import subprocess
import sys

HEADER = re.compile(r"\n(?=[0-9a-f]+ <[^>]+>:\n)")
INSN = re.compile(r"\s+([0-9a-f]+):\s+(?:[0-9a-f]{2} )*\s*(\S+)\s*(.*)")


def census(txt, prefix):
    """objdump -d text -> {name: row}, in object order. Ported from prototype/census.py."""
    rows = {}
    for fn in HEADER.split(txt):
        m = re.match(r"([0-9a-f]+) <([^>]+)>:", fn)
        if not m or not m.group(2).startswith(prefix):
            continue
        lines = [l for l in fn.split("\n")[1:] if re.match(r"\s+[0-9a-f]+:", l)]
        row = {"insns": len(lines), "jcc": 0, "back": 0, "fwd": 0, "short_fwd": 0, "vec": 0, "shorts": []}
        for l in lines:
            mm = INSN.match(l)
            if not mm:
                continue
            addr, op, args = int(mm.group(1), 16), mm.group(2), mm.group(3)
            if re.search(r"[xyz]mm", args):
                row["vec"] += 1
            if op.startswith("j") and op not in ("jmp", "jmpq"):
                t = re.match(r"([0-9a-f]+)", args)
                if not t:
                    continue
                row["jcc"] += 1
                tgt = int(t.group(1), 16)
                if tgt <= addr:
                    row["back"] += 1
                else:
                    row["fwd"] += 1
                    if tgt - addr <= 32:
                        row["short_fwd"] += 1
                        row["shorts"].append(l.strip())
        rows[m.group(2)] = row
    return rows


def table(rows):
    out = [f"{'function':12s} {'insns':>6s} {'jcc':>4s} {'back':>5s} {'fwd':>4s} {'short-fwd':>9s} {'vec':>5s}"]
    for name, r in rows.items():
        out.append(f"{name:12s} {r['insns']:6d} {r['jcc']:4d} {r['back']:5d} {r['fwd']:4d} {r['short_fwd']:9d} {r['vec']:5d}")
        out += ["      short fwd: " + s for s in r["shorts"]]
    return "\n".join(out)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("obj")
    ap.add_argument("--prefix", default="p_")
    a = ap.parse_args(argv)
    txt = subprocess.run(["objdump", "-d", a.obj], check=True, capture_output=True, text=True).stdout
    rows = census(txt, a.prefix)
    if not rows:
        print(f"census: no function starting with {a.prefix!r} in {a.obj}", file=sys.stderr)
        return 1
    print(table(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
