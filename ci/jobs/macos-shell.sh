# all: no
# runner: macos
# What only macOS can show, on a macOS runner: the macOS shell's real-window tests (the example
# from posted events, size and close, scale, cursors, pasteboard, the text input client, wait
# and wake from a worker thread, two windows, the menu bar and Quit, drag registration,
# appearance), then the example in a window for 2 seconds. Linux checks the same code by
# cross-compiling (ci/jobs/shell-macos.sh) and tests the event translation in `zig build test`.
zig build macos macos-example --summary all
zig-out/bin/macos-example 2
