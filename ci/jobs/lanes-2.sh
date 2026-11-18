# std's width query gives only 4 or 8 lanes on x86-64, so the root package forces 2.
zig build test -Dlanes=2
