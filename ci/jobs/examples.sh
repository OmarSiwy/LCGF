# The examples (examples/). Each is a package of its own: the desktop ones on lcgf_app with the
# render back end at its default, their tests playing recordings into their `App` without a
# window (lcgf_replay); ci/run.sh examples-x11 runs their windows. The root `examples` step tests
# the microcontroller demo and links it for a Cortex-M7 (no emulator in the dev shell: linked,
# not run).
zig build examples --summary all
size zig-out/mcu/example-mcu-cortex-m7

# Build and test every package as a consumer would. All use the package directory the root
# build above fetched into (zig-pkg/, not tracked).
repo=$PWD
for project in examples/*/build.zig; do
    (cd "$(dirname "$project")" && zig build install test --pkg-dir "$repo/zig-pkg")
done
