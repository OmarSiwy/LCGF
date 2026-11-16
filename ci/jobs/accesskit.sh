# all: no
# The AccessKit bridge (src/a11y/accesskit/) against AccessKit's prebuilt C library: the semantic
# tree converted to AccessKit tree updates, checked through AccessKit's own debug output. Out of
# `all` because the release archive (lazy build.zig.zon dependency) is 68 MB.
zig build accesskit --summary all
