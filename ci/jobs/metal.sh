# The Metal back end (src/render/metal/). Everywhere: its tests that need no device (the ones
# that do skip off macOS), including the conformance scenes' call stream through a recording
# encoder, then the tests and metal-play cross-compiled and linked for both macOS
# architectures. On a Mac (uname Darwin) also every test on the real device, and metal-play
# draws the render conformance scenes, each compared with its golden image as every back end's
# job does. The workflow's runners are Linux, so that half runs only on a Mac today.
zig build metal --summary all
for t in aarch64-macos x86_64-macos; do
    echo "-- $t"
    zig build metal-build metal-play -Dtarget="$t"
done
if [ "$(uname)" = Darwin ]; then
    zig build metal-play
    out=zig-out/metal; rm -rf "$out"
    zig-out/bin/metal-play "$out"
    for ref in src/render/conformance/*.png; do
        python3 tools/golden/golden.py "$out/$(basename "$ref")" "$ref"
    done
    python3 tools/golden/golden.py "$out/canvas.png" tools/golden/ref/draw/canvas.png
else
    echo "metal: not macOS, conformance pixels not drawn"
fi
