# The Win32 shell (src/shell/win32/) on the Windows targets this machine cannot run: compiled
# and linked, not run. Its message translation (translate.zig) is tested by `zig build test`.
for t in x86_64-windows aarch64-windows; do
    echo "-- $t"
    zig build win32-build -Dtarget="$t"
done
