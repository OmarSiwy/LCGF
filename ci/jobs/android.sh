# The Android shell (src/shell/android/) for the Android target this machine cannot run: its
# example linked as the shared library a NativeActivity loads (no NDK: the Android libraries
# are stubs that only give it its DT_NEEDED entries, build.zig). Reading NativeActivity's
# events (translate.zig, the input replay tests) is tested by `zig build test` on every host,
# here included. The check below is what the device's loader needs: the entry point exported,
# and only the system's libraries needed. On a device, the example started with the intent
# extra lcgr.replay runs the same recording through the real activity and swapchain and logs
# its result; no job does that yet (it needs the Android SDK to package an APK, and an
# emulator or a device).
for mode in Debug ReleaseFast; do
    echo "-- aarch64-linux-android $mode"
    zig build android-build -Dtarget=aarch64-linux-android -Doptimize="$mode"
done
so=zig-out/lib/libandroid-example.so
readelf -d "$so" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort | tr '\n' ' '; echo
readelf --dyn-syms -W "$so" | grep -q ' FUNC .* GLOBAL .* [0-9]\+ ANativeActivity_onCreate$'
[ "$(readelf -d "$so" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort | tr '\n' ' ')" = "libandroid.so libc.so libdl.so liblog.so " ]
