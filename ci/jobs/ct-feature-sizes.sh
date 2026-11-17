# Comparable stripped ELF libraries built for a fixed x86-64 baseline.
zig build ct-feature-sizes -Dtarget=x86_64-linux -Dcpu=baseline -Doptimize=ReleaseSmall
python3 - <<'PY'
from pathlib import Path
import subprocess

sizes = {}
print("variant     ELF bytes     .text   .rodata")
for name in ("plain", "caption", "full"):
    path = Path(f"zig-out/ct-feature-sizes/{name}.so")
    rows = subprocess.check_output(["size", "-A", str(path)], text=True).splitlines()
    sec = {parts[0]: int(parts[1]) for row in rows if (parts := row.split()) and parts[0].startswith(".")}
    sizes[name] = (path.stat().st_size, sec[".text"], sec[".rodata"])
    print(f"{name:<10} {sizes[name][0]:>10} {sizes[name][1]:>9} {sizes[name][2]:>9}")
for i in range(3):
    if not sizes["plain"][i] < sizes["full"][i] or not sizes["caption"][i] < sizes["full"][i]:
        raise SystemExit("Expected disabled features to reduce each size relative to full")
PY
