# Compile only: these targets cannot run here.
for t in aarch64-linux aarch64-macos x86_64-windows wasm32-wasi riscv64-linux; do
    echo "-- $t"
    zig build test-build -Dtarget="$t"
done
