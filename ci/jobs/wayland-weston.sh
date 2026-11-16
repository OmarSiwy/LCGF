# shell: golden
# all: no
# The Wayland shell's example on a real compositor: weston --backend=headless (no display, no
# input devices; the golden shell provides it). One window drawn with the pixman renderer and
# captured with weston-screenshooter, its pixels checked where src/shell/headless.zig checks
# them; then a second toplevel and a popup at output scale 2.
zig build wayland-example
dir=$(mktemp -d "${TMPDIR:-/tmp}/lcgr-wl.XXXX") # short: socket paths are at most 108 bytes
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$dir"' EXIT
example=$PWD/zig-out/bin/wayland-example

compositor() { # args: weston options; leaves WAYLAND_DISPLAY and XDG_RUNTIME_DIR set
    rm -rf "$dir/run"; mkdir -p "$dir/run"
    export XDG_RUNTIME_DIR=$dir/run WAYLAND_DISPLAY=wl
    (cd "$dir" && weston --backend=headless --socket=wl --width=800 --height=600 "$@" >"$dir/weston.log" 2>&1) &
    for _ in $(seq 100); do [ -S "$dir/run/wl" ] && return; sleep 0.1; done
    echo "weston did not start"; cat "$dir/weston.log"; exit 1
}

# One window, captured while it idles.
compositor --renderer=pixman --debug
timeout 30 "$example" --exit-when-idle --idle 4 >"$dir/one.txt" &
sleep 2
(cd "$dir" && timeout 10 weston-screenshooter)
wait %2
cat "$dir/one.txt"
kill %1; wait %1 2>/dev/null || true
grep -q "error null" "$dir/one.txt"
python3 - "$dir" <<'PY'
import glob, re, sys
sys.path.insert(0, "tools/golden")
from golden import read_png
d = sys.argv[1]
w, h, px = read_png(glob.glob(d + "/wayland-screenshot-*.png")[0])
def at(x, y):
    i = (y * w + x) * 4
    return "%02x%02x%02x" % tuple(px[i:i + 3])
col = dict(re.findall(r"(panel|control|text) ([0-9a-f]{6})", open(d + "/one.txt").read()))
# The window's top: the first row whose sidebar column has the panel colour below the toolbar.
top = next((y for y in range(h) if at(80, y) == col["panel"] and at(400, y) == col["panel"]), None)
if top is None:
    sys.exit("no window in the screenshot; column 80: " + " ".join(at(80, y) for y in range(0, h, 20)))
checks = [((80, top + 500), col["panel"]), ((12, top + 74), col["control"]),
          ((400, top + 300), "000000"), ((20, top + 70), col["text"])]
for (x, y), want in checks:
    got = at(x, y)
    print(f"({x}, {y}): {got}, want {want}")
    assert got == want, "pixel mismatch"
print(f"screenshot {w}x{h}: the window's frame is on screen at y = {top}")
PY

# Two toplevels and a popup, at scale 2.
compositor --scale=2
timeout 30 "$example" --exit-when-idle --multi | tee "$dir/multi.txt"
kill %1; wait %1 2>/dev/null || true
test "$(grep -c 'scale 2, configured true' "$dir/multi.txt")" = 3
grep -q "error null" "$dir/multi.txt"
