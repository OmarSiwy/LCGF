# all: no
# The AccessKit bridge (src/a11y/accesskit/) against AccessKit's prebuilt C library: the semantic
# tree converted to AccessKit tree updates, checked through AccessKit's own debug output, and the
# platform adapters linked for each platform's library. Out of `all` because the release archive
# (lazy build.zig.zon dependency) is 68 MB.
zig build accesskit --summary all
# Linked against the Windows (MinGW) library; run it under Wine where there is one (`-fwine`).
zig build accesskit-build -Dtarget=x86_64-windows-gnu
