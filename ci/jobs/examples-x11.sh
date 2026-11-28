# shell: golden
# all: no
# Every lcgf_app example package (examples/<name>/build.zig calling `lcgf.addApp`) in a window
# on Xvfb for a second, as ci/jobs/app.sh runs examples/app: the default build on the GPU
# (lavapipe here: golden_build links the golden shell's Mesa), then the same binary in the
# software window (LCGF_RENDER=sw). WAYLAND_DISPLAY is emptied so the software path takes X11.
# A window that cannot open, or an example that checks itself (viewport: no scene drawn on
# the GPU), fails the job. -noreset and -displayfd as in ci/jobs/x11.sh.
repo=$PWD
dir=$(mktemp -d)
Xvfb -displayfd 3 -screen 0 1024x768x24 -nolisten tcp -noreset 3>"$dir/display" 2>"$dir/xvfb.log" &
xvfb=$!
trap 'kill $xvfb; rm -rf "$dir"' EXIT
for _ in $(seq 100); do [ -s "$dir/display" ] && break; sleep 0.1; done
display=":$(cat "$dir/display")"
for project in $(grep -l 'lcgf.addApp' examples/*/build.zig); do
    name=$(basename "$(dirname "$project")")
    (cd "examples/$name" && golden_build install --pkg-dir "$repo/zig-pkg" -p "$dir/$name")
    for render in "" sw; do
        echo "-- $name LCGF_RENDER=$render"
        DISPLAY="$display" XAUTHORITY=/dev/null WAYLAND_DISPLAY= LCGF_APP_SECONDS=1 LCGF_RENDER=$render "$dir/$name/bin/$name"
    done
done
