# The Win32 shell (src/shell/win32/) on the Windows targets this machine cannot run: its tests
# (the real-window tests: `zig build win32` on Windows) and the example program, compiled and
# linked, not run. Its message translation (translate.zig) is tested by `zig build test` on
# every host, here included.
for t in aarch64-windows x86_64-windows; do
    echo "-- $t"
    zig build win32-build win32-example -Dtarget="$t"
done
# The x86_64 example, built last, links only system DLLs.
objdump -p zig-out/bin/win32-example.exe | sed -n 's/^\tDLL Name: //p' | sort
