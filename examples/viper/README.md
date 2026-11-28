# viper

VIPER: View, Interactor, Presenter, Entity, Router, one file each.

- `entity.zig`: plain task data.
- `interactor.zig`: the use case (Advance); the only writer of the entity.
- `router.zig`: owns the page shown.
- `presenter.zig`: formats the entity for the view; sends clicks to the interactor or router.
- `view.zig`: draws the projection and reports clicks.
- `app.zig`: composition root; owns the entity and the router.

The app shows four tasks with **All**, **Open** and **Advance** buttons. Advance marks the
next task done; All and Open switch the page between every task and the unfinished ones.

Run `zig build run` to open it in a window through `lcgf_app` (Wayland or X11 on Linux,
Win32, macOS), on the GPU where there is one; `LCGF_APP_SECONDS=2` closes it after two seconds. Use `zig build test` for the headless
replay, which clicks Advance and Open and checks where each click landed. For offline builds,
pass the checkout's `zig-pkg` directory to `zig build --pkg-dir`. Use Zig
`0.18.0-dev.1151+8dfb7a7cc` and the LCGF revision that ships this example.
