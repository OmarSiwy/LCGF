# markup

A counter written in HTML and CSS (`ui/counter.html`, `ui/counter.css`). The build runs
`lcgf.addMarkup`, which compiles the page with `lcgf-gen` into `counter_ui`, a comptime page:
its generated view state, theme, `Spec`, `ComptimeUi` and `Page(H)`. `app.zig` writes only
the handlers the markup names (`on:click="inc"`, `on:change="step_changed"`).

`zig build test` runs the headless test, `zig build run` three headless frames, `zig build`
installs the executable. Editing the HTML or CSS reruns the compiler; editing only `app.zig`
does not. `zig build -Dmarkup-emit=gen` also copies the generated file to `gen/`, and
`zig build -Dmarkup-vendored=gen/counter_ui.zig` builds from that copy and fails when it is
stale. The guide is `docs/guide/markup.md`.

Use Zig `0.18.0-dev.1151+8dfb7a7cc`. For offline builds, pass the checkout's `zig-pkg`
directory to `zig build --pkg-dir`; the compiler's HTML parser, Lexbor, is a lazy dependency
of the framework.
