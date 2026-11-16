# The docs (docs/): the API index generated from the sources (zig-out/docs/API.md), and the
# guides (docs/guide/*.md), whose examples run as tests and whose zig blocks must be pieces of them.
zig build docs
grep -q '^## `lcgr.simd`' zig-out/docs/API.md
