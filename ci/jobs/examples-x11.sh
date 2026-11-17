# shell: golden
# all: no
# Every example in an X11 window on Xvfb for 1 second (src/example/window.zig): it must present
# at least one frame with no server error. -noreset and -displayfd as in ci/jobs/x11.sh.
zig build examples --summary all
dir=$(mktemp -d)
Xvfb -displayfd 3 -screen 0 1024x768x24 -nolisten tcp -noreset 3>"$dir/display" 2>"$dir/xvfb.log" &
xvfb=$!
trap 'kill $xvfb; rm -rf "$dir"' EXIT
for _ in $(seq 100); do [ -s "$dir/display" ] && break; sleep 0.1; done
display=":$(cat "$dir/display")"
for exe in zig-out/bin/example-*; do
    DISPLAY="$display" XAUTHORITY=/dev/null "$exe" 1
done
