#!/bin/sh
# From the repository root in the vs development shell. Extra arguments go to Zig.
set -eu
src=bench/vs/window-resize
out=zig-out/bin
obj=zig-out/window-resize
mkdir -p "$out" "$obj"
: "${CARGO_TARGET_DIR:=$PWD/zig-out/cargo}"
export CARGO_TARGET_DIR
zig build vs-resize-adapters "$@"
# shellcheck disable=SC2046
cc -O2 -fPIC $(pkg-config --cflags x11 cairo) -c "$src/window.c" -o "$obj/window.o"
libs=$(pkg-config --libs x11 cairo)
for toolkit in clay imgui lvgl; do
    c++ -o "$out/resize-$toolkit" "$obj/window.o" "zig-out/lib/libresize-$toolkit-adapter.a" $libs -lm
done
# shellcheck disable=SC2046
c++ -O2 -std=c++17 -fPIC "$src/qtquick.cpp" $(pkg-config --cflags --libs Qt6Quick Qt6Qml Qt6Gui Qt6Core) -o "$out/resize-qtquick"
cc -O2 -std=gnu99 -I"$NUKLEAR_SRC" "$src/nuklear.c" "$obj/window.o" $libs -lm -o "$out/resize-nuklear"
cc -O2 -std=gnu99 -I"$MICROUI_SRC/src" "$src/microui.c" "$MICROUI_SRC/src/microui.c" "$obj/window.o" $libs -lm -o "$out/resize-microui"
cc -O2 -std=gnu11 "$src/gtk4.c" $(pkg-config --cflags --libs gtk4-x11 x11) -lm -o "$out/resize-gtk4"
c++ -O2 -std=c++17 -fPIC "$src/qtwidgets.cpp" $(pkg-config --cflags --libs Qt6Widgets) -o "$out/resize-qtwidgets"
# Link only these three binaries to the X11 presenter. The original comparison
# binaries retain their existing dependency and size measurements.
# Cargo does not fingerprint objects passed via linker arguments. A content-addressed
# name makes a presenter change relink each Rust adapter on incremental builds.
checksum=$(cksum < "$obj/window.o" | cut -d ' ' -f1)
presenter="$PWD/$obj/window-$checksum.o"
cp "$obj/window.o" "$presenter"
set -- "-Clink-arg=$presenter"
for arg in $libs; do set -- "$@" "-Clink-arg=$arg"; done
for toolkit in egui iced slint; do
    cargo rustc --locked --release --manifest-path "bench/vs/$toolkit/Cargo.toml" \
        --features window-resize --bin "resize-$toolkit" -- "$@"
    cp "$CARGO_TARGET_DIR/release/resize-$toolkit" "$out/"
done
