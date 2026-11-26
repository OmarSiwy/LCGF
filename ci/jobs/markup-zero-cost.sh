# The markup compiler's pages cost nothing over hand-written ones (docs/plans/markup-compiler.md
# M10.1): for every fixture, one ComptimeUi frame (tools/lcgf-gen/markup/testdata/cost_probe.zig)
# built over the generated module and over the hand-written twin must have byte-identical code:
# the same .text size and SHA-256. ReleaseFast, stripped, x86_64-linux; only .text is compared
# (symbol names differ: page_ui.State against twin.State).
zig build markup-cost-obj -Dtarget=x86_64-linux
python3 - zig-out/markup-cost <<'PY'
import hashlib, os, struct, sys
def text(path):
    b = open(path, 'rb').read()
    shoff, = struct.unpack_from('<Q', b, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 0x3A)
    def sh(i):
        name, _, _, _, off, size = struct.unpack_from('<IIQQQQ', b, shoff + i * shentsize)
        return name, off, size
    _, stroff, _ = sh(shstrndx)
    out = b''
    for i in range(shnum):
        name, off, size = sh(i)
        if b[stroff + name:].split(b'\0')[0].startswith(b'.text'): out += b[off:off + size]
    return out
d = sys.argv[1]
names = sorted({f.rsplit('-', 1)[0] for f in os.listdir(d)})
bad = 0
for n in names:
    a, t = text(f'{d}/{n}-page.o'), text(f'{d}/{n}-twin.o')
    same = a == t
    bad += not same
    print(f'{n:10} generated {len(a):6} B {hashlib.sha256(a).hexdigest()[:16]}  twin {len(t):6} B {hashlib.sha256(t).hexdigest()[:16]}  {"identical" if same else "DIFFERENT"}')
sys.exit(1 if bad else 0)
PY
