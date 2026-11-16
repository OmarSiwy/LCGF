#!/usr/bin/env python3
"""Sizes of wasm modules: file bytes, gzip -9 bytes (what a server sends), and the code and data
sections. Standard library only (ci/jobs/web-size.sh).

    python3 src/render/web/size.py MODULE.wasm...
"""
import gzip
import sys
from pathlib import Path


def sections(data):
    """{section name: payload bytes} of a wasm binary."""
    assert data[:4] == b"\0asm", "not a wasm module"
    names = {1: "type", 2: "import", 3: "function", 5: "memory", 6: "global", 7: "export", 10: "code", 11: "data", 0: "custom"}
    out, i = {}, 8
    while i < len(data):
        sid, i = data[i], i + 1
        size = shift = 0
        while True:  # unsigned LEB128
            b, i = data[i], i + 1
            size |= (b & 0x7F) << shift
            shift += 7
            if b < 0x80:
                break
        name = names.get(sid, f"id{sid}")
        out[name] = out.get(name, 0) + size
        i += size
    return out


def main(paths):
    print(f"{'module':<16}{'bytes':>9}{'gzip':>9}{'code':>9}{'data':>9}{'custom':>9}")
    for p in paths:
        data = Path(p).read_bytes()
        s = sections(data)
        print(f"{Path(p).name:<16}{len(data):>9}{len(gzip.compress(data, 9)):>9}{s.get('code', 0):>9}{s.get('data', 0):>9}{s.get('custom', 0):>9}")


if __name__ == "__main__":
    main(sys.argv[1:])
