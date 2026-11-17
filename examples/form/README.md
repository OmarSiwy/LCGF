# form

Edit and validate a name and age before submitting the form.

On Linux with an X11 display, run `zig build run`. Pass a duration in seconds with
`zig build run -- 2`. Use `zig build test` for the headless replay or `zig build` to
install the executable in `zig-out/bin/`. The application is in `app.zig`.

Use Zig `0.18.0-dev.1151+8dfb7a7cc` and the LCGF revision that ships this
example. Inside the framework checkout the local dependency resolves automatically.
After copying this project next to that checkout, run
`zig fetch --save=lcgf ../gui-framework` once. Use the relative path to the
checkout if your layout differs. The framework build script supplies `buildDesktopExample`.
For offline builds, pass the checkout's `zig-pkg` directory to `zig build --pkg-dir`.
