# std's width query gives only 4 or 8 lanes on x86-64, so the root package forces 2.
# The prototype has no such option; its 2-lane run is recorded in docs/CHECKS.md.
zig build test -Dlanes=2
