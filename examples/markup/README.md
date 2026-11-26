# markup

A counter written in HTML and CSS (`ui/counter.html`, `ui/counter.css`), run from Zig, C++ and
Rust. The page uses classes and custom properties in its CSS, flex rows, formatted text
(`{count:.0}`, `Level {level:.2}`), two buttons with `on:click`, a checkbox with `bind:checked`,
a range slider with `bind:value`, an `lcgf-if` note and an `lcgf-each` row of up to 8 dots.

In Zig, the build runs `lcgf.addMarkup`, which compiles the page with `lcgf-gen` into
`counter_ui`, a comptime page: its generated view state, theme, `Spec`, `ComptimeUi` and
`Page(H)`. `app.zig` writes only the handlers the markup names (`on:click="inc"`,
`on:change="step_changed"`).

`zig build test` runs the headless test, `zig build run` three headless frames, `zig build`
installs the executable. Editing the HTML or CSS reruns the compiler; editing only `app.zig`
does not. `zig build -Dmarkup-emit=gen` also copies the generated file to `gen/`, and
`zig build -Dmarkup-vendored=gen/counter_ui.zig` builds from that copy and fails when it is
stale. The guide is `docs/guide/markup.md`.

## C++ and Rust

Both build against a `zig build abi` prefix and need no Zig compiler. `lcgf-gen` lowers the
same page to the C seam's tables. The app polls the frame's events (`clicked(Widget::inc)`) and
applies the logic `app.zig`'s handlers have. Each program clicks + headlessly and exits non-zero
unless the count is 1:

```sh
cmake -S cpp -B build -DCMAKE_PREFIX_PATH=<prefix> && cmake --build build && ./build/example-markup-cpp
LCGF_PREFIX=<prefix> cargo run --manifest-path rust/Cargo.toml
```

`lcgf_add_ui(app ../ui/counter.html)` and `lcgf::include_ui!("../ui/counter.html")` rerun
`lcgf-gen` when the HTML or CSS changes. A page outside the seam's subset is an error at its
HTML line; docs/guide/markup.md ("C++ and Rust") lists the subset.

Use Zig `0.18.0-dev.1151+8dfb7a7cc`. For offline builds, pass the checkout's `zig-pkg`
directory to `zig build --pkg-dir`; the compiler's HTML parser, Lexbor, is a lazy dependency
of the framework.
