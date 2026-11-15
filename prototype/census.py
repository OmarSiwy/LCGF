"""Branch census: count conditional jumps in the exported probe functions.

    zig build census-obj -Dcpu=x86_64_v3
    python3 census.py zig-out/asm_probe.o

Reads the disassembly of every function whose name starts with p_ (see
asm_probe.zig) and reports conditional jumps. A backward jump is loop control.
A short forward jump inside a per-row loop is a branch the data can mispredict:
the gate is that per-row loops contain loop-control jumps only.
"""
import re, subprocess, sys

obj = sys.argv[1] if len(sys.argv) > 1 else "zig-out/asm_probe.o"
txt = subprocess.run(["objdump", "-d", obj], check=True, capture_output=True, text=True).stdout
funcs = re.split(r'\n(?=[0-9a-f]+ <[^>]+>:\n)', txt)
print(f"{'function':12s} {'insns':>6s} {'jcc':>4s} {'back':>5s} {'fwd':>4s} {'short-fwd':>9s} {'vec':>5s}")
for fn in funcs:
    m = re.match(r'([0-9a-f]+) <([^>]+)>:', fn)
    if not m or not m.group(2).startswith('p_'):
        continue
    name = m.group(2)
    lines = [l for l in fn.split('\n')[1:] if re.match(r'\s+[0-9a-f]+:', l)]
    jcc = back = fwd = vec = short = 0
    shorts = []
    for l in lines:
        mm = re.match(r'\s+([0-9a-f]+):\s+(?:[0-9a-f]{2} )*\s*(\S+)\s*(.*)', l)
        if not mm:
            continue
        addr = int(mm.group(1), 16); op = mm.group(2); args = mm.group(3)
        if re.search(r'[xyz]mm', args):
            vec += 1
        if op.startswith('j') and op not in ('jmp', 'jmpq'):
            t = re.match(r'([0-9a-f]+)', args)
            if not t:
                continue
            jcc += 1
            tgt = int(t.group(1), 16)
            if tgt <= addr:
                back += 1
            else:
                fwd += 1
                if tgt - addr <= 32:
                    short += 1; shorts.append(l.strip())
    print(f"{name:12s} {len(lines):6d} {jcc:4d} {back:5d} {fwd:4d} {short:9d} {vec:5d}")
    for s in shorts:
        print("      short fwd:", s)
