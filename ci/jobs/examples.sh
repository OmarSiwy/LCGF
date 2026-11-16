# The examples (examples/): each one's smoke test drives it from a recording and checks what
# it built and drew; each one is also built as an X11 program (run by ci/run.sh examples-x11).
zig build examples --summary all
# The microcontroller demo linked for a Cortex-M7 (no emulator in the dev shell: linked, not run).
size zig-out/mcu/example-mcu-cortex-m7
