# The examples (examples/): each one's smoke test drives it from a recording and checks what
# it built and drew; each one is also built as an X11 program (run by ci/run.sh examples-x11).
zig build examples --summary all
