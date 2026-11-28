# mvp

MVP: Model, View, Presenter.

- `model.zig`: all state, the tasks and the page.
- `presenter.zig`: stateless; builds the projection, draws the view, applies its click to the model.
- `view.zig`: passive; draws what it is given and reports clicks.
- `app.zig`: owns the model.

The app shows four tasks with **All**, **Open** and **Advance** buttons. Advance marks the
next task done; All and Open switch the page between every task and the unfinished ones.

Run `zig build run` to open it in a window through `lcgf_app` (Wayland or X11 on Linux,
Win32, macOS), on the GPU where there is one; `LCGF_APP_SECONDS=2` closes it after two seconds. Use `zig build test` for the headless
replay, which clicks Advance and Open and checks where each click landed. For offline builds,
pass the checkout's `zig-pkg` directory to `zig build --pkg-dir`. Use Zig
`0.18.0-dev.1151+8dfb7a7cc` and the LCGF revision that ships this example.
