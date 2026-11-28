# The macOS shell (src/shell/macos/) on the macOS targets this machine cannot run: its tests
# (the real-window tests: `zig build macos` on a Mac) and the example, compiled and linked,
# not run. Its event
# translation (translate.zig) is tested by `zig build test` on every host, here included.
for t in aarch64-macos x86_64-macos; do
    echo "-- $t"
    zig build macos-build macos-example app-macos-build -Dtarget="$t"
done
