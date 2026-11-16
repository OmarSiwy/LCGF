# The Metal back end (src/render/metal/). On Linux: its tests that need no device (the ones
# that do skip), then the tests cross-compiled and linked for both macOS architectures. On a Mac
# the same commands run every test on the real device.
zig build metal --summary all
for t in aarch64-macos x86_64-macos; do
    echo "-- $t"
    zig build metal-build -Dtarget="$t"
done
