# Examples

An application is written against `lcgf_app`: `lcgf_app.run` from `main`,
`lcgf.addApp` in build.zig, and `-Drender` left at its default. `lcgf_app` draws on
the GPU where it has a window for it (Vulkan over X11 on Linux) and falls back to
software by itself, and application code names no back end. Every desktop program
here is written that way:

| Program | What it demonstrates |
|---|---|
| [app](app/main.zig) | The hello window in one call, for any desktop target (`zig build app-example` at the checkout root) |
| [surface](surface/main.zig) | A button beside rings a WGSL shader draws into a `Surface` (`zig build surface-example`; Linux, Vulkan) |

## Standalone example projects

Each directory is a Zig application with its own build script, package manifest,
sources and headless tests. Use the repository's pinned Zig
`0.18.0-dev.1151+8dfb7a7cc`, available through `nix develop` at the checkout root.

| Project | What it demonstrates |
|---|---|
| [hello](hello/) | A centered greeting and a button |
| [counter](counter/) | Signals, derived values and frame reuse |
| [form](form/) | Text editing, validation and submission |
| [list](list/) | Visible rows of a 100,000-item list |
| [dashboard](dashboard/) | Bar and line charts on a `Frame.canvas` |
| [viewport](viewport/) | A sphere behind UI controls: a shader in a `Surface`, or a CPU `lcgf_app.Image` |
| [texture](texture/) | A second UI drawn on the CPU into an `lcgf_app.Image`, shown on a tilted card |
| [viper](viper/) | VIPER: entity, interactor, presenter, view and router files |
| [mvp](mvp/) | MVP: one model, a passive view and a stateless presenter |
| [mvvp](mvvp/) | MVVP, a project-defined Model-View-ViewModel-Presenter hybrid |
| [mvvm](mvvm/) | MVVM: a view bound to ViewModel commands |
| [mvvm-c](mvvm-c/) | MVVM-C: a coordinator owns navigation |
| [mcu](mcu/) | A thermostat replay and Cortex-M7 image |
| [embedded](embedded/) | A simulated SPI counter board and two firmware targets |

From a project directory, `zig build` installs the application, `zig build run`
opens its window and `zig build test` runs its headless checks. The desktop
projects' build.zig is examples/app's: LCGF as a dependency with the default back
end, `lcgf.addApp`, and a test of the same module with `lcgf_replay`, which plays
recordings into the `App` through the headless shell and checks what it built and
drew ([runtime guide](../docs/guide/runtime.md#testing-it-without-a-window)).
`LCGF_APP_SECONDS=1` closes a window after a second and `LCGF_RENDER=sw` forces the
software window. For interactive timing at large window sizes, run
`zig build run -Doptimize=ReleaseFast` in the example directory.

What the widgets cannot draw goes through the three layers of docs/DESIGN.md:
`dashboard` uses `Frame.canvas`, `viewport` a `Surface` (and an `lcgf_app.Image`
where the window has no GPU), `texture` an `lcgf_app.Image`. `texture` rasterizes its
inner UI with `render_sw` itself, since `lcgf_app` has no call that draws a list into
an application's pixels. `mcu` and `embedded` use `-Drender=sw` because they target
microcontrollers, which is what it is for; the board projects run on a host
simulator, and their READMEs list the firmware targets and options. The styling
directory renders a PNG gallery and a CPU benchmark (`zig build styling-gallery`,
`styling-bench`), not a window.

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
framework revision that ships these projects. The window layer (`lcgf_app`) and
the replay support (`lcgf_replay`) are modules of the framework package, so these
commands also work with an unpacked SDK containing the package's declared paths.
Each board project owns its simulator inputs and firmware sources.

Zig fetches the framework's pinned packages on the first build, into `zig-pkg/`
at the root of the checkout (not tracked). For an offline build, fill it once
while online with `zig build --fetch` in the framework checkout, then point
other projects at it, for example
`zig build test --pkg-dir ../gui-framework/zig-pkg` from a sibling project or
`zig build test --pkg-dir ../../zig-pkg` from an in-tree project.

`ci/run.sh examples` runs `zig build examples` (the thermostat's test and its
Cortex-M7 image) and `install test` in every project. `ci/run.sh examples-x11`
runs each desktop project's window for a second on Xvfb, on the GPU (lavapipe) and
with `LCGF_RENDER=sw`. `zig build embedded embedded-sim` covers the counter board.
