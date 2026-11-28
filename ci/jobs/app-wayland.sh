# shell: golden
# all: no
# lcgf_app's GPU window on native Wayland (src/app/gpu_wayland.zig): a headless Weston on the
# gl renderer, which takes LINEAR XRGB8888 dma-bufs (zwp_linux_dmabuf_v1), and Mesa lavapipe,
# which exports them through /dev/udmabuf. lcgf_app's tests run against it (T1 to T4, not
# shown, runApp), then examples/surface for a second with no X display. Where lavapipe cannot
# export a dma-buf (no /dev/udmabuf, as on most CI runners) those tests skip.
golden_build app-test surface-example --summary all
dir=$(mktemp -d "${TMPDIR:-/tmp}/lcgf-wlgpu.XXXX") # short: socket paths are at most 108 bytes
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$dir"' EXIT
mkdir -p "$dir/run"
XDG_RUNTIME_DIR=$dir/run weston --backend=headless --socket=wl --renderer=gl --width=800 --height=600 >"$dir/weston.log" 2>&1 &
for _ in $(seq 100); do [ -S "$dir/run/wl" ] && break; sleep 0.1; done
[ -S "$dir/run/wl" ] || { echo "weston did not start"; cat "$dir/weston.log"; exit 1; }
XDG_RUNTIME_DIR=$dir/run LCGF_WAYLAND_TEST_DISPLAY=wl golden_build app-test --summary all
XDG_RUNTIME_DIR=$dir/run WAYLAND_DISPLAY=wl DISPLAY= LCGF_APP_SECONDS=1 zig-out/bin/surface-example
