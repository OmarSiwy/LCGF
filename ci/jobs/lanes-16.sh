# std's width query gives only 4 or 8 lanes on x86-64, so the root package forces 16.
zig build test -Dlanes=16
