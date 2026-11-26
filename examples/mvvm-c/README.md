# mvvm-c

MVVM-C: MVVM with a coordinator that owns navigation.

- `model.zig`: the tasks and the Advance operation.
- `view_model.zig`: builds the projection and runs Advance; returns navigation as a request.
- `coordinator.zig`: owns the page; the only code that changes it.
- `view.zig`: passive; draws the projection and reports clicks.
- `app.zig`: owns the model and the coordinator; hands requests to the coordinator.

The app shows four tasks with **All**, **Open** and **Advance** buttons. Advance marks the
next task done; All and Open switch the page between every task and the unfinished ones.

On Linux with an X11 display, run `zig build run`. Use `zig build test` for the headless
replay, which clicks Advance and Open and checks where each click landed. For offline builds,
pass the checkout's `zig-pkg` directory to `zig build --pkg-dir`. Use Zig
`0.18.0-dev.1151+8dfb7a7cc` and the LCGF revision that ships this example.
