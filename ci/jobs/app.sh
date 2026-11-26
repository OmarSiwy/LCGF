# shell: golden
# all: no
# lcgf_app (src/app/app.zig): examples/app in a window from one call. It runs for a second on
# Xvfb (the X11 shell) and, when weston is installed, on a headless Weston (the Wayland shell:
# the same binary picks it from WAYLAND_DISPLAY); it compiles for Windows and macOS, whose
# shells it wires in from the target alone.
zig build app-example --summary all
dir=$(mktemp -d)
Xvfb -displayfd 3 -screen 0 1024x768x24 -nolisten tcp -noreset 3>"$dir/display" 2>"$dir/xvfb.log" &
xvfb=$!
trap 'kill $xvfb $weston 2>/dev/null; rm -rf "$dir"' EXIT
weston=
for _ in $(seq 100); do [ -s "$dir/display" ] && break; sleep 0.1; done
DISPLAY=":$(cat "$dir/display")" XAUTHORITY=/dev/null WAYLAND_DISPLAY= LCGF_APP_SECONDS=1 zig-out/bin/app-example
if command -v weston >/dev/null; then
    mkdir -m 700 "$dir/xdg"
    XDG_RUNTIME_DIR="$dir/xdg" weston --backend=headless --socket=lcgf-app --width=640 --height=480 >"$dir/weston.log" 2>&1 &
    weston=$!
    for _ in $(seq 100); do [ -S "$dir/xdg/lcgf-app" ] && break; sleep 0.1; done
    XDG_RUNTIME_DIR="$dir/xdg" WAYLAND_DISPLAY=lcgf-app LCGF_APP_SECONDS=1 zig-out/bin/app-example
fi
for t in x86_64-windows aarch64-macos; do
    echo "-- $t"
    zig build app-example -Dtarget="$t" -p "$dir/$t"
done
