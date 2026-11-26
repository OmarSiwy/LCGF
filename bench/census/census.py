#!/usr/bin/env python3
"""Branch census: count conditional jumps in the hot functions of an object file.

    python3 bench/census/census.py OBJ [--prefix p_] [--baseline FILE] [--write-baseline FILE]
    python3 bench/census/census.py --self-test

Disassembles OBJ with objdump and reports, for every function whose name starts
with the prefix, its conditional jumps. A backward jump is loop control. A short
forward jump inside a per-row loop is a branch the data can mispredict: the gate
is that per-row loops contain loop-control jumps only (docs/CHECKS.md section 2).

Build the production probes with `zig build census-src-obj -Dcpu=x86_64_v3`
and pass `zig-out/census_src.o` and `--baseline bench/census/baseline-src.json`.

--baseline FILE fails (exit 1) when a function has more conditional jumps,
backward jumps or short forward jumps than FILE records, or when the functions
differ from FILE. Fewer is fine; lower the baseline in the same commit. A new
jump is accepted only by raising FILE in a commit that explains it (read the
disassembly, as docs/CHECKS.md does for the four recorded short forward jumps).
"""
import argparse
import json
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


GATED = ("jcc", "back", "short_fwd")


def check(rows, baseline):
    """Gate failures of rows against baseline {name: {jcc, back, short_fwd}}; empty means pass."""
    bad = [f"{n}: not in the baseline; add it" for n in rows if n not in baseline]
    bad += [f"{n}: in the baseline but not in the object" for n in baseline if n not in rows]
    for n in rows.keys() & baseline.keys():
        for k in GATED:
            if rows[n][k] > baseline[n][k]:
                bad.append(f"{n}: {k} {rows[n][k]} > baseline {baseline[n][k]}")
    return bad


def self_test():
    # Two functions in the shape of objdump -d: a loop (one backward jcc), and the
    # same loop after it gained a data-dependent skip (one short forward jcc).
    txt = """
0000000000000000 <p_loop>:
   0:	31 c0                	xor    %eax,%eax
   2:	ff c0                	inc    %eax
   4:	39 f8                	cmp    %edi,%eax
   6:	72 fa                	jb     2 <p_loop+0x2>
   8:	c3                   	ret

0000000000000010 <p_skip>:
  10:	31 c0                	xor    %eax,%eax
  12:	85 37                	test   %esi,(%rdi)
  14:	74 02                	je     18 <p_skip+0x8>
  16:	ff c0                	inc    %eax
  18:	39 f8                	cmp    %edi,%eax
  1a:	72 f6                	jb     12 <p_skip+0x2>
  1c:	c3                   	ret

0000000000000020 <other>:
  20:	74 00                	je     22 <other+0x2>
"""
    rows = census(txt, "p_")
    assert list(rows) == ["p_loop", "p_skip"], rows
    assert (rows["p_loop"]["jcc"], rows["p_loop"]["back"], rows["p_loop"]["short_fwd"]) == (1, 1, 0)
    assert (rows["p_skip"]["jcc"], rows["p_skip"]["back"], rows["p_skip"]["short_fwd"]) == (2, 1, 1)
    loop = {"jcc": 1, "back": 1, "short_fwd": 0}
    assert check({"p_loop": rows["p_loop"]}, {"p_loop": loop}) == []
    assert check({"p_loop": rows["p_skip"]}, {"p_loop": loop}) == [
        "p_loop: jcc 2 > baseline 1",
        "p_loop: short_fwd 1 > baseline 0",
    ]
    assert check(rows, {"p_loop": loop}) == ["p_skip: not in the baseline; add it"]
    assert check({}, {"p_loop": loop}) == ["p_loop: in the baseline but not in the object"]
    assert check({"p_loop": rows["p_loop"]}, {"p_loop": dict(loop, jcc=5)}) == []
    print("census self-test ok")


def table(rows):
    out = [f"{'function':12s} {'insns':>6s} {'jcc':>4s} {'back':>5s} {'fwd':>4s} {'short-fwd':>9s} {'vec':>5s}"]
    for name, r in rows.items():
        out.append(f"{name:12s} {r['insns']:6d} {r['jcc']:4d} {r['back']:5d} {r['fwd']:4d} {r['short_fwd']:9d} {r['vec']:5d}")
        out += ["      short fwd: " + s for s in r["shorts"]]
    return "\n".join(out)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("obj", nargs="?")
    ap.add_argument("--prefix", default="p_")
    ap.add_argument("--baseline", help="JSON of per-function jcc/back/short_fwd ceilings")
    ap.add_argument("--write-baseline", help="write the current counts as a baseline")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args(argv)
    if a.self_test:
        self_test()
        return 0
    if not a.obj:
        ap.error("OBJ is required")
    txt = subprocess.run(["objdump", "-d", a.obj], check=True, capture_output=True, text=True).stdout
    rows = census(txt, a.prefix)
    if not rows:
        print(f"census: no function starting with {a.prefix!r} in {a.obj}", file=sys.stderr)
        return 1
    print(table(rows))
    if a.write_baseline:
        with open(a.write_baseline, "w") as f:
            json.dump({n: {k: r[k] for k in GATED} for n, r in rows.items()}, f, indent=2)
            f.write("\n")
    if a.baseline:
        with open(a.baseline) as f:
            bad = check(rows, json.load(f))
        for b in bad:
            print("census: " + b, file=sys.stderr)
        if bad:
            return 1
        print(f"census: {len(rows)} functions within {a.baseline}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
