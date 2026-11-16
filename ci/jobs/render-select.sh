# The back-end selector costs nothing (src/render/select.zig): for every back end, the probe
# (src/render/select_probe.zig) built through lcgr_render and by importing the back end's own
# module must have byte-identical code: the same .text size and SHA-256. Back ends that only
# run elsewhere are cross-compiled: Metal for aarch64-macos, Direct3D 12 for x86_64-windows,
# web for wasm32. The objects are ReleaseFast and stripped; only the code section is compared
# (the files also hold paths that differ).
text() {
    python3 - "$1" <<'PY'
import hashlib, struct, sys
b = open(sys.argv[1], 'rb').read()
def elf():
    is64 = b[4] == 2; e = '<' if b[5] == 1 else '>'
    if is64: shoff, = struct.unpack_from(e + 'Q', b, 0x28); shentsize, shnum, shstrndx = struct.unpack_from(e + 'HHH', b, 0x3A)
    else: shoff, = struct.unpack_from(e + 'I', b, 0x20); shentsize, shnum, shstrndx = struct.unpack_from(e + 'HHH', b, 0x2E)
    def sh(i):
        o = shoff + i * shentsize
        if is64: name, _, _, _, off, size = struct.unpack_from(e + 'IIQQQQ', b, o)
        else: name, _, _, _, off, size = struct.unpack_from(e + 'IIIIII', b, o)
        return name, off, size
    if shnum == 0 or shstrndx == 0xffff:  # past 0xff00 sections: the counts live in section 0
        o = shoff
        size, link = struct.unpack_from(e + ('QI' if is64 else 'II'), b, o + (0x20 if is64 else 0x14))
        shnum = shnum or size
        if shstrndx == 0xffff: shstrndx = link
    _, stroff, _ = sh(shstrndx)
    for i in range(shnum):
        name, off, size = sh(i)
        if b[stroff + name:].split(b'\0')[0] == b'.text': return b[off:off + size]
def macho():
    ncmds, = struct.unpack_from('<I', b, 16); o = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', b, o)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects, = struct.unpack_from('<I', b, o + 64)
            for k in range(nsects):
                s = o + 72 + k * 80
                if b[s:s + 16].rstrip(b'\0') == b'__text':
                    sz, off = struct.unpack_from('<QI', b, s + 40)
                    return b[off:off + sz]
        o += size
def coff():
    nsects, = struct.unpack_from('<H', b, 2); opt, = struct.unpack_from('<H', b, 16)
    for k in range(nsects):
        s = 20 + opt + k * 40
        if b[s:s + 8].rstrip(b'\0') == b'.text':
            sz, off = struct.unpack_from('<II', b, s + 16)
            return b[off:off + sz]
def wasm():
    o = 8
    while o < len(b):
        sid = b[o]; o += 1; n = 0; shift = 0
        while True:
            x = b[o]; o += 1; n |= (x & 0x7f) << shift; shift += 7
            if x < 0x80: break
        if sid == 10: return b[o:o + n]
        o += n
t = elf() if b[:4] == b'\x7fELF' else macho() if b[:4] == b'\xcf\xfa\xed\xfe' else wasm() if b[:4] == b'\0asm' else coff()
assert t, 'no code section in ' + sys.argv[1]
print(len(t), hashlib.sha256(t).hexdigest())
PY
}
for spec in sw: vk: gles: wgpu:-Dwgpu-native=v29 metal:-Dtarget=aarch64-macos d3d12:-Dtarget=x86_64-windows-gnu web:-Dtarget=wasm32-freestanding; do
    kind=${spec%%:*}; args=${spec#*:}
    rm -rf zig-out/render-probe
    # shellcheck disable=SC2086
    zig build render-probe -Drender="$kind" $args
    sel=$(text zig-out/render-probe/selector.o); dir=$(text zig-out/render-probe/direct.o)
    if [ "$sel" != "$dir" ]; then
        echo "FAIL $kind: .text through lcgr_render ($sel) differs from the direct import ($dir)"
        exit 1
    fi
    echo "ok   $kind ${args:-native}: .text $sel, identical"
done
