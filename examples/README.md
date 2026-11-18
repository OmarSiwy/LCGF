# Standalone example projects

Each directory is a Zig application with its own build script, package manifest,
sources and replay tests. Use the repository's pinned Zig
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
| [mcu](mcu/) | A thermostat replay and Cortex-M7 image |
| [embedded](embedded/) | A simulated SPI counter board and two firmware targets |

From a project directory, `zig build` installs the application, `zig build run`
runs it and `zig build test` runs its headless checks. The seven desktop programs
use the software renderer and Linux/X11. For interactive timing at large window
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
framework revision that ships these projects. The desktop build scripts use
its `buildDesktopExample` helper. The runner and replay support are part of the
framework package, so these commands also work with an unpacked SDK containing
the package's declared paths. Each board project owns its simulator inputs and
firmware sources.

Zig fetches the framework's pinned Unicode tables on the first build. For an
offline build, use the package directory shipped with the checkout, for example
`zig build test --pkg-dir ../gui-framework/zig-pkg` from a sibling project or
`zig build test --pkg-dir ../../zig-pkg` from an in-tree project.

The repository-wide `zig build examples` command still builds the desktop
executables and thermostat image and runs their tests. `zig build embedded embedded-sim` covers the counter board.
