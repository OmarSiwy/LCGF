# The iOS shell (src/shell/ios/) for the iOS targets this machine cannot run: its example
# compiled into a static library for devices and for the simulator on Apple silicon (no iOS SDK
# here, so nothing is linked; an app bundle links it with libSystem, and UIKit, Core
# Foundation and Metal are opened at run time). Reading UIKit's events (translate.zig, the input
# replay tests) is tested by `zig build test` on every host, here included. On a device or
# simulator, `ios-example --replay` runs the same recording through the real view and Metal
# layer; no job does that yet (it needs Xcode's SDK and a simulator on a macOS runner).
for t in aarch64-ios aarch64-ios-simulator; do
    for mode in Debug ReleaseFast; do
        echo "-- $t $mode"
        zig build ios-build -Dtarget="$t" -Doptimize="$mode"
    done
done
