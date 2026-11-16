"""Checks that the guides show only what `zig build docs` checks. Usage: snippets.py <docs/guide>

- Every ```zig block of docs/guide/*.md must be a verbatim piece of a docs/guide/*.zig file,
  whose tests the build runs.
- Every line of a ```text block must end with the `//! expect: ` message of a compile-error case
  (docs/guide/errors/*.zig, which the build compiles and expects to fail with it, or
  src/comptime/compile_fail/*.zig, which `zig build ct-compile-fail` does the same for), so a
  catalogued message is one the compiler really prints.
"""
import glob, os, re, sys

def norm(block):
    # Indentation differs between a test body and the guide; compare stripped lines.
    return '\n'.join(l.strip() for l in block.strip('\n').split('\n'))

def expects(pattern):
    out = []
    for f in sorted(glob.glob(pattern)):
        first = open(f).readline().rstrip('\n')
        if first.startswith('//! expect: '): out.append(first[len('//! expect: '):])
    return out

d = sys.argv[1]
root = os.path.dirname(os.path.dirname(os.path.abspath(d)))
code = '\n'.join(norm(open(f).read()) for f in sorted(glob.glob(os.path.join(d, '*.zig'))))
known = expects(os.path.join(d, 'errors', '*.zig')) + expects(os.path.join(root, 'src', 'comptime', 'compile_fail', '*.zig'))
bad = 0; n = 0; m = 0
for md in sorted(glob.glob(os.path.join(d, '*.md'))):
    text = open(md).read()
    for block in re.findall(r'^```zig\n(.*?)^```', text, re.M | re.S):
        n += 1
        if norm(block) not in code:
            bad += 1
            print(f"{md}: a zig block is not in any {d}/*.zig file:\n{block}", file=sys.stderr)
    for block in re.findall(r'^```text\n(.*?)^```', text, re.M | re.S):
        for line in block.strip('\n').split('\n'):
            m += 1
            if not any(line.endswith(e) for e in known):
                bad += 1
                print(f"{md}: no compile-error case expects: {line}", file=sys.stderr)
if bad: sys.exit(1)
print(f"guides: {n} zig blocks, all compiled; {m} compile errors, all checked", file=sys.stderr)
