# The docs (docs/): the API index generated from the sources (zig-out/docs/API.md), and the
# guides (docs/guide/*.md), whose examples run as tests and whose zig blocks must be pieces of
# them, and whose catalogued compile errors must be what the cases in docs/guide/errors/ print.
zig build docs
grep -q '^## `lcgr.simd`' zig-out/docs/API.md
cmp docs/api/API.md zig-out/docs/API.md
# Control: a case that compiles must fail the step, so the error harness can fail.
control=docs/guide/errors/zz_control.zig
trap 'rm -f "$control"' EXIT
printf '%s\n' '//! expect: this message is never printed' 'pub const ok = 1;' > "$control"
if zig build docs >/dev/null 2>&1; then echo "control passed: the compile-error harness cannot fail"; exit 1; fi
rm -f "$control"
echo "docs: control case fails as it should"
