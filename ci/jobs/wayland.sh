# The Wayland shell (src/shell/wayland/) against a fake compositor on a socket pair: start-up,
# configure and resize, the example's input replayed as pointer events, keyboard (xkb), touch,
# scale, cursors, clipboard, IME, timers and wake, windows and popups, file drop, decorations.
# Debug, then ReleaseSafe at 4 lanes and Debug at 16 (the software back end draws the frames).
zig build wayland --summary all
zig build wayland -Doptimize=ReleaseSafe -Dlanes=4
zig build wayland -Dlanes=16
# The example compiles for the other Linux targets; they cannot run here.
for t in aarch64-linux riscv64-linux; do
    echo "-- $t"
    zig build wayland-example -Dtarget="$t" -p "zig-out/$t"
done
