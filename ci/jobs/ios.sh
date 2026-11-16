# The iOS shell (src/shell/ios/) for the iOS targets this machine cannot run: its example
# compiled into a static library (no iOS SDK here, so nothing is linked; an app bundle links
# it with libSystem, and UIKit, Core Foundation and Metal are opened at run time). Reading
# UIKit's events (translate.zig, the input replay tests) is tested by `zig build test` on every
# host, here included.
for mode in Debug ReleaseFast; do
    echo "-- aarch64-ios $mode"
    zig build ios-build -Dtarget=aarch64-ios -Doptimize="$mode"
done
