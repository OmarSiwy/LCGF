"""Every ```zig block of docs/guide/*.md must be a verbatim piece of a docs/guide/*.zig file, so
the code a guide shows is code `zig build docs` compiles and runs. Usage: snippets.py <docs/guide>
"""
import glob, os, re, sys

def norm(block):
    # Indentation differs between a test body and the guide; compare stripped lines.
    return '\n'.join(l.strip() for l in block.strip('\n').split('\n'))

d = sys.argv[1]
code = '\n'.join(norm(open(f).read()) for f in sorted(glob.glob(os.path.join(d, '*.zig'))))
bad = 0; n = 0
for md in sorted(glob.glob(os.path.join(d, '*.md'))):
    for block in re.findall(r'^```zig\n(.*?)^```', open(md).read(), re.M | re.S):
        n += 1
        if norm(block) not in code:
            bad += 1
            print(f"{md}: a zig block is not in any {d}/*.zig file:\n{block}", file=sys.stderr)
if bad: sys.exit(1)
print(f"guides: {n} zig blocks, all compiled", file=sys.stderr)
