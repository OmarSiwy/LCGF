# The markup compiler's pages cost nothing over hand-written ones (docs/plans/markup-compiler.md
# M10.1). Two pairs per fixture must have byte-identical code, the same .text size and SHA-256:
#
# - page/twin: one ComptimeUi frame (tools/lcgf-gen/markup/testdata/cost_probe.zig), built over
#   the generated module and over the hand-written twin.
# - rt/rtvars: one runtime-frontend frame (cost_probe_rt.zig), built without and with
#   --runtime-vars=t-, for pages that use no token (docs/plans/schemify.md §2, T-RT).
#
# ReleaseFast, stripped, x86_64-linux. Only .text is compared, because symbol names differ
# (page_ui.State against twin.State).
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
files = set(os.listdir(d))
names = sorted({f.rsplit('-', 1)[0] for f in files})
bad = 0
for n in names:
    for a_side, b_side in (('page', 'twin'), ('rt', 'rtvars')):
        if f'{n}-{a_side}.o' not in files: continue
        a, t = text(f'{d}/{n}-{a_side}.o'), text(f'{d}/{n}-{b_side}.o')
        same = a == t
        bad += not same
        print(f'{n:10} {a_side:4} {len(a):6} B {hashlib.sha256(a).hexdigest()[:16]}  {b_side:6} {len(t):6} B {hashlib.sha256(t).hexdigest()[:16]}  {"identical" if same else "DIFFERENT"}')
sys.exit(1 if bad else 0)
PY
