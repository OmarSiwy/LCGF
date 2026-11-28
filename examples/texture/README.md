# texture

Render a second UI to a texture, then display it on a tilted card.

Run `zig build run` to open it in a window through `lcgf_app` (Wayland or X11 on Linux,
Win32, macOS), on the GPU where there is one; `LCGF_APP_SECONDS=2` closes it after two seconds. Use `zig build test` for the headless replay or `zig build` to
install the executable in `zig-out/bin/`. The application is in `app.zig`.

Use Zig `0.18.0-dev.1151+8dfb7a7cc` and the LCGF revision that ships this
example. Inside the framework checkout the local dependency resolves automatically.
After copying this project next to that checkout, run
`zig fetch --save=lcgf ../gui-framework` once. Use the relative path to the
checkout if your layout differs.
For offline builds, pass the checkout's `zig-pkg` directory to `zig build --pkg-dir`.
