# The docs (docs/): the API index generated from the sources, zig-out/docs/API.md.
zig build docs
grep -q '^## `lcgr.simd`' zig-out/docs/API.md
