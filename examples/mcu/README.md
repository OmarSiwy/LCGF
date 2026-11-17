# mcu

Replay a thermostat on a simulated touch panel and build Cortex-M7 firmware.

Run `zig build run` to replay the board inputs on the host or `zig build test` to check
the resulting panel and thermostat. `zig build` installs the simulator and the
freestanding Cortex-M7 image in `zig-out/bin/`.

Use Zig `0.18.0-dev.1151+8dfb7a7cc` and the LCGF revision that ships this
example. Inside the framework checkout the local dependency resolves automatically.
After copying this project next to that checkout, run
`zig fetch --save=lcgf ../gui-framework` once. Use the relative path to the
checkout if your layout differs.
For offline builds, pass the checkout's `zig-pkg` directory to `zig build --pkg-dir`.
