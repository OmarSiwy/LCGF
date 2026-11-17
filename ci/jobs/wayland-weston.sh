# shell: golden
# all: no
# The Wayland shell's example on a real compositor: weston --backend=headless (no display, no
# input devices; the golden shell provides it). One window drawn with the pixman renderer and
# captured with weston-screenshooter: every pixel of the frame the shell committed that is on
# screen must be in the capture unchanged. Then a second toplevel and a popup at output scale 2.
zig build wayland-example
dir=$(mktemp -d "${TMPDIR:-/tmp}/lcgf-wl.XXXX") # short: socket paths are at most 108 bytes
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$dir"' EXIT
example=$PWD/zig-out/bin/wayland-example

compositor() { # args: weston options; leaves WAYLAND_DISPLAY and XDG_RUNTIME_DIR set
    rm -rf "$dir/run"; mkdir -p "$dir/run"
    export XDG_RUNTIME_DIR=$dir/run WAYLAND_DISPLAY=wl
    # No window animations: a capture during one would catch the window part-way in.
    printf '[shell]\nanimation=none\nstartup-animation=none\nclose-animation=none\n' >"$dir/weston.ini"
    (cd "$dir" && weston --config="$dir/weston.ini" --backend=headless --socket=wl --width=800 --height=600 "$@" >"$dir/weston.log" 2>&1) &
    for _ in $(seq 100); do [ -S "$dir/run/wl" ] && return; sleep 0.1; done
    echo "weston did not start"; cat "$dir/weston.log"; exit 1
}

# One window, captured while it idles; the frame it committed is dumped beside the capture.
# The kiosk shell has no panel and shows the window fullscreen at (0, 0), so nothing the shell
# draws lands on it, however late its own client starts under load. The capture waits for the
# example's --ready (a frame of it was shown) instead of a fixed delay; up to three captures
# are taken, a few seconds apart, and the check passes on the first that holds the frame.
compositor --shell=kiosk --renderer=pixman --debug
timeout 120 "$example" --exit-when-idle --idle 12 --ready "$dir/ready" --dump "$dir/frame.bin" >"$dir/one.txt" &
for _ in $(seq 600); do [ -e "$dir/ready" ] && break; sleep 0.1; done
[ -e "$dir/ready" ] || { echo "the example never showed a frame"; exit 1; }
for shot in 1 2 3; do
    (cd "$dir" && timeout 20 weston-screenshooter && mv wayland-screenshot-*.png "shot-$shot.png")
    sleep 2
done
wait %2
cat "$dir/one.txt"
kill %1; wait %1 2>/dev/null || true
grep -q "error null" "$dir/one.txt"
python3 - "$dir" <<'PY'
import struct, sys
sys.path.insert(0, "tools/golden")
from golden import read_png
d = sys.argv[1]
raw = open(d + "/frame.bin", "rb").read()
fw, fh = struct.unpack("<II", raw[:8])
def frame(x, y):  # ARGB words, little-endian: B G R A
    i = 8 + (y * fw + x) * 4
    return raw[i + 2], raw[i + 1], raw[i]
def check(n):
    global sw, sh, shot
    sw, sh, shot = read_png(f"{d}/shot-{n}.png")
    hit = next(((ox, oy) for oy in range(0, 100) for ox in range(0, 100) if fits(ox, oy)), None)
    if hit is None:
        print(f"capture {n}: the frame is not in it; its column 80: " + " ".join("%02x%02x%02x" % screen(80, y) for y in range(0, sh, 25)))
        return False
    ox, oy = hit
    # Every pixel of the frame that is on screen must be the frame's.
    seen = bad = 0
    for y in range(fh):
        for x in range(fw):
            if ox + x < sw and oy + y < sh:
                seen += 1
                bad += screen(ox + x, oy + y) != frame(x, y)
    print(f"capture {n}, {sw}x{sh}: the {fw}x{fh} frame at ({ox}, {oy}), {seen} pixels on screen, {bad} differ")
    assert seen > fw * fh // 2 and bad == 0, "pixel mismatch"
    return True
def screen(x, y):
    i = (y * sw + x) * 4
    return tuple(shot[i:i + 3])
# Where the window is: the offset at which a few of the frame's pixels line up.
probes = [(x, y) for x in range(0, min(fw, 400), 37) for y in range(0, min(fh, 300), 29)]
def fits(ox, oy):
    return all(screen(ox + x, oy + y) == frame(x, y) for x, y in probes if ox + x < sw and oy + y < sh)
if not any(check(n) for n in (1, 2, 3)):
    sys.exit("the frame is in none of the captures")
PY

# Two toplevels and a popup, at scale 2.
compositor --scale=2
timeout 30 "$example" --exit-when-idle --multi | tee "$dir/multi.txt"
kill %1; wait %1 2>/dev/null || true
test "$(grep -c 'scale 2, configured true' "$dir/multi.txt")" = 3
grep -q "error null" "$dir/multi.txt"
