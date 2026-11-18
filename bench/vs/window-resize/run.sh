#!/usr/bin/env bash
# Build the window fixtures in the vs shell, then observe them on a private display.
set -euo pipefail
cd "$(dirname "$0")/../../.."
zig build vs-window-resize -Doptimize=ReleaseFast
bash bench/vs/window-resize/build.sh
cc -std=c11 -O2 -Wall -Wextra bench/vs/window-resize/observe.c \
    $(pkg-config --cflags --libs x11) -o zig-out/bin/resize-observe
python3 bench/vs/window-resize/measure.py "$@"
