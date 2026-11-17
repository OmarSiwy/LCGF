# embedded

Run the counter board on a simulated RGB565 SPI display and build its firmware.

Run `zig build run` to drive the simulated panel from `counter.replay`. Use
`zig build test` to check the panel pixels and `zig build firmware` to build
Cortex-M7 and RV32IMAC images. Add `-Dno-float=true` to bake integer-only panel
assets or `-Dfixed-point=true` to use fixed-point rectangle coordinates.

Use Zig `0.18.0-dev.1151+8dfb7a7cc` and the LCGF revision that ships this
example. Inside the framework checkout the local dependency resolves automatically.
After copying this project next to that checkout, run
`zig fetch --save=lcgf ../gui-framework` once. Use the relative path to the
checkout if your layout differs.
For offline builds, pass the checkout's `zig-pkg` directory to `zig build --pkg-dir`.
