# shell: golden
# all: no
# The X11 shell (src/shell/x11/) on Xvfb: its tests (the example from the input recording, keys,
# scale, cursors, clipboard, IME, wait and wake, multiple windows, drag and drop) run against a
# real X server, then the example runs in a window for 2 seconds. -noreset: an X server resets
# when its last client leaves and refuses connections meanwhile; the tests open and close many.
# -displayfd picks a free display, so parallel runs do not collide.
zig build x11 x11-example --summary all
dir=$(mktemp -d)
Xvfb -displayfd 3 -screen 0 1024x768x24 -nolisten tcp -noreset 3>"$dir/display" 2>"$dir/xvfb.log" &
xvfb=$!
trap 'kill $xvfb; rm -rf "$dir"' EXIT
for _ in $(seq 100); do [ -s "$dir/display" ] && break; sleep 0.1; done
display=":$(cat "$dir/display")"
for mode in Debug ReleaseFast; do
    LCGR_X11_TEST_DISPLAY="$display" zig build x11 -Doptimize="$mode" --summary all
done
DISPLAY="$display" XAUTHORITY=/dev/null XMODIFIERS= zig-out/bin/x11-example 2
