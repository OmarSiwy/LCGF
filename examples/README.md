# Standalone example projects

Each directory is a Zig application with its own build script, package manifest,
sources and headless tests. Use the repository's pinned Zig
`0.18.0-dev.1151+8dfb7a7cc`, available through `nix develop` at the checkout root.

| Project | What it demonstrates |
|---|---|
| [hello](hello/) | A centered greeting and a button |
| [counter](counter/) | Signals, derived values and frame reuse |
| [form](form/) | Text editing, validation and submission |
| [list](list/) | Visible rows of a 100,000-item list |
| [dashboard](dashboard/) | Host-drawn bar and line charts |
| [viewport](viewport/) | A ray-cast sphere behind UI controls |
| [texture](texture/) | A second UI rendered into a texture |
| [viper](viper/) | VIPER: entity, interactor, presenter, view and router files |
| [mvp](mvp/) | MVP: one model, a passive view and a stateless presenter |
| [mvvp](mvvp/) | MVVP, a project-defined Model-View-ViewModel-Presenter hybrid |
| [mvvm](mvvm/) | MVVM: a view bound to ViewModel commands |
| [mvvm-c](mvvm-c/) | MVVM-C: a coordinator owns navigation |
| [mcu](mcu/) | A thermostat replay and Cortex-M7 image |
| [embedded](embedded/) | A simulated SPI counter board and two firmware targets |
| [markup](markup/) | A counter written in HTML and CSS: a comptime page by `addMarkup` in Zig, the same page from C++ (`cpp/`) and Rust (`rust/`) |

From a project directory, `zig build` installs the application, `zig build run`
runs it and `zig build test` runs its headless checks. The original seven desktop
programs and the five architecture examples use the software renderer and Linux/X11.
For interactive timing at large window
sizes, run `zig build run -Doptimize=ReleaseFast` in the example directory.
The shared host embeds printable ASCII glyphs from DejaVu Sans Mono and installs
the font license under `share/licenses/`. The board projects run on a host
simulator. Their READMEs list the firmware targets and options.

## Use a project outside this checkout

Copy one directory. Its manifest declares one direct dependency, `lcgf`.
For a copied example next to `gui-framework/`, select that checkout once using
the same Zig version as above.

```sh
zig fetch --save=lcgf ../gui-framework
zig build test
```

Pass a relative path to the framework when using a different layout. Zig
updates the local dependency entry in the copied project's manifest. Use the
framework revision that ships these projects. The desktop build scripts use its
`buildDesktopExample` helper. The runner and
replay support are part of the framework package, so these commands also work
with an unpacked SDK containing the package's declared paths. Each board
project owns its simulator inputs and firmware sources.

Zig fetches the framework's pinned packages on the first build, into `zig-pkg/`
at the root of the checkout (not tracked). For an offline build, fill it once
while online with `zig build --fetch` in the framework checkout, then point
other projects at it, for example
`zig build test --pkg-dir ../gui-framework/zig-pkg` from a sibling project or
`zig build test --pkg-dir ../../zig-pkg` from an in-tree project.

The repository-wide `zig build examples` command builds the original seven
desktop executables and thermostat image and runs their tests. The examples CI
job also discovers each standalone build and runs `install test`, including the
five architecture examples. `zig build embedded
embedded-sim` covers the counter board.
