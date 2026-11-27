# shell: golden
# all: no
# Vulkan over an X window (src/shell/x11/gpu.zig) on Xvfb and Mesa lavapipe: the shell opens a
# window on a real X server, libxcb gives Vulkan a surface over it, a frame is drawn and
# presented, and the window is read back from the server. lavapipe presents with
# plain X requests, so no GPU and no DRI3 are needed. -displayfd as in ci/jobs/x11.sh.
dir=$(mktemp -d)
Xvfb -displayfd 3 -screen 0 1024x768x24 -nolisten tcp -noreset 3>"$dir/display" 2>"$dir/xvfb.log" &
xvfb=$!
trap 'kill $xvfb; rm -rf "$dir"' EXIT
for _ in $(seq 100); do [ -s "$dir/display" ] && break; sleep 0.1; done
display=":$(cat "$dir/display")"
for mode in Debug ReleaseFast; do
    LCGF_X11_TEST_DISPLAY="$display" XAUTHORITY=/dev/null golden_build x11-gpu -Doptimize="$mode" --summary all
done
