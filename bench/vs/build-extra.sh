#!/usr/bin/env bash
# Compile the additional scene harnesses with the benchmark shell's pinned sources.
set -euo pipefail
mkdir -p zig-out/bin
for variant in fast small; do
    flags=(-O2)
    suffix=
    if [[ $variant == small ]]; then flags=(-Os -s); suffix=-small; fi
    out=zig-out/bin/vs
    cc "${flags[@]}" -std=gnu99 -I"$NUKLEAR_SRC" bench/vs/nuklear/main.c -lm -o "$out-nuklear$suffix"
    cc "${flags[@]}" -std=gnu99 -I"$MICROUI_SRC/src" bench/vs/microui/main.c "$MICROUI_SRC/src/microui.c" -lm -o "$out-microui$suffix"
    cc "${flags[@]}" -std=gnu11 bench/vs/gtk4/main.c $(pkg-config --cflags --libs gtk4-x11 x11) -lm -o "$out-gtk4$suffix"
    c++ "${flags[@]}" -fPIC -std=c++17 bench/vs/qtwidgets/main.cpp $(pkg-config --cflags --libs Qt6Widgets) -o "$out-qtwidgets$suffix"
done
