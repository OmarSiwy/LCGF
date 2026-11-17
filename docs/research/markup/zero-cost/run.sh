#!/bin/sh
# Builds hand.zig (a page written by hand) and gen.zig (the same page as the markup tool would
# generate it, with its comptime name checks and handler dispatch) and prints the size and
# SHA-256 of each object's .text, with the function ci/jobs/render-select.sh uses.
# Run from the repository root: nix develop -c sh docs/research/markup/zero-cost/run.sh
set -eu
here=docs/research/markup/zero-cost
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
echo 'pub const lanes: ?u32 = null;' > "$out/options.zig"
eval "$(sed -n '/^text() {/,/^}/p' ci/jobs/render-select.sh)"
for f in hand gen; do
    zig build-obj -OReleaseFast -fstrip --cache-dir "$out/cache" \
        --dep lcgf --dep handlers "-Mroot=$here/$f.zig" \
        --dep build_options -Mlcgf=src/lcgf.zig "-Mbuild_options=$out/options.zig" \
        "-Mhandlers=$here/handlers.zig" "-femit-bin=$out/$f.o"
    text "$out/$f.o" > "$out/$f.text"
    echo "$f: $(cat "$out/$f.text")"
done
cmp "$out/hand.text" "$out/gen.text"
