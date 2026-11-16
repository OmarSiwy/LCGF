# System font discovery for the fallback chain (src/text/fallback/system.zig) on the OSes this
# machine cannot run: compiled and linked, not run.
for t in x86_64-windows aarch64-macos x86_64-macos; do
    echo "-- $t"
    zig build fallback-system-build -Dtarget="$t"
done
