# Changelog

## Unreleased

## 0.2.0 — 2026-11-27

The first tagged release: [v0.2.0](https://github.com/OmarSiwy/LCGF/releases/tag/v0.2.0).

### New

- Write a desktop application with `lcgf_app.run` from `main` and `lcgf.addApp` in build.zig, with `-Drender` left at its default. A dependent package gets the `lcgf_app` module (`dep.module("lcgf_app")`, `addApp`); examples/app is such a package. On Linux an `lcgf_app` build links libc when its back end is a GPU one; a `-Drender=sw` build stays static. `-Drender=sw` is for microcontrollers, machines that must not load a GPU driver and the smallest static binary. [Runtime guide](docs/guide/runtime.md#a-window-in-one-call), [back ends](docs/guide/backends.md)
- `lcgf_app` draws on the GPU: a Linux build with the default back end (`vk`) opens the window as X11 with Vulkan, keeps the window's picture and redraws only inside each frame's damage. An `App` with `pub fn draw(*App, *lcgf_app.GpuFrame) !void` draws its own widgets, `lcgf_app.Surface`, through `lcgf_render.gpu`; a widget frame never calls `draw` and a surface frame never builds. `LCGF_RENDER=sw`, no `DISPLAY`, an X server that cannot be reached or no Vulkan device falls back to the software window, where every `App` runs: `draw` is never called, a surface's node paints its fill, and `Surface.live()` is false so `build` can show something in its place. A build without the GPU path has `Surface` and `GpuFrame` too (never live); only `lcgf_app.gpu` is a compile error there. In a debug build, a `Frame.custom` node in an `lcgf_app` window, which draws nothing for it, is said once in the log. [Surfaces](docs/guide/surface.md), [examples/surface](examples/surface/main.zig)
- Three layers for what widgets cannot draw: `Surface` for raw GPU drawing, `Frame.canvas` for 2D content that draws the same on every back end, software included, and `lcgf_app.Image` for CPU pixels. [Design](docs/DESIGN.md)
- `lcgf_app` draws text with real fonts at the window's scale: `Options.fonts` (font k is file k), else the system's default faces where the build can ask for them, else the bundled bitmap font. `Options.text` sizes the text service. [Text guide](docs/guide/text.md)
- `lcgf_app` takes an application's images through an optional `pub fn images(*App) []const lcgf_app.Image`: straight RGBA8 `pixels`, or `alpha` (coverage, tinted by the node's fill), a size and a generation; at most `images_max`. `Style.texture` k + 1 is image k. A new generation, set in a frame the application asks for, redraws only the nodes that show the image (`damage.addTextures`); a change in the number of images or an image's size redraws the whole window, as does, on the GPU, a new generation in a surface's frame.
- The canvas row format is general: a row has its own colour (`Instances.colors`, on by default; `setColor`) over its layer's, the palette is optional (`CanvasOptions.palette` defaults to `Palette.none`, every row `Layer.default`), a stroke is its layer's width in logical pixels or the row's world-unit `.width`, and a dashed layer holds its on and off lengths (`Layer.of(.{ .dash = .{ on, off } })`). A changed row uploads 36 bytes to the GPU. The limits are stated in src/draw/canvas.zig: no joins between segments, a polygon tests every edge per pixel, no curves or gradients. [docs/plans/schemify.md](docs/plans/schemify.md) has a migration table.
- `lcgf_app` turns damage on: an unchanged frame presents nothing and a changed one redraws only what changed.
- `lcgf_app.Canvas`: a canvas whose camera and palette the application changes and `redraw()`s with no `build` on the GPU window, which draws the canvas node's rectangle again from the rows it already holds, uploading the camera and nothing of the UI's; a software window builds a frame for it. Also in a composed page and with labels. [Surfaces](docs/guide/surface.md)
- Canvas labels in real fonts, sharp at any zoom: an `App` with a field `labels: lcgf_app.Labels` gets the window's text service and a distance atlas (`Options.labels`) before its first `build`, and makes labels with `labels.label(&shapes, str, .{ .origin, .px })`. `Options.canvas` sizes the GPU window's canvas rows (4096 rows and 4096 polygon vertices by default).
- An `App` can draw its frame inside a page of its own: `pub fn page` lays out a compiled page (`ComptimeUi`) and returns the frame's region, and `pub fn compose` returns the composed list; the window draws only the union of both sides' damage.
- Damage: `Context.trackDamageWhole` records the region and leaves the draw list whole, for a host that keeps the rows on the GPU. A text run that overflows its node damages where its glyphs reach. `ct_interop.compose` carries the union of both sides' damage instead of the whole window, with `ComptimeUi.recordDamage` on the comptime side.
- `vk.setup.Window` keeps the window's picture: `begin` and `present` split a frame around the application's own passes, and `draw` stays the one-call form.
- `x11.Connection.overrideScale` sets the scale; the screen's real size is read from RandR when the connection opens; display pacing follows each window's refresh rate from RandR (a 120 Hz panel paces at 120 Hz).
- The bundled bitmap font has a cell for every byte from 32 to 255 (ASCII, Windows-1252, and the infinity sign at 0x81); `Mono.encode` turns UTF-8 into those bytes.
- Comptime front ends support bounded dynamic regions, shared geometry and ordered paint. Applications can mix runtime and comptime regions in the same draw list. [Comptime guide](docs/guide/comptime.md)
- Embedded builds support Q12.4 geometry, RGB565 and monochrome panels, single-scanline rendering and a fixed-panel integer firmware profile. The SPI simulator replays the board's counter example and checks the displayed pixels. [Package options](docs/release/package.md)
- Dependency builds can import the core and selected renderer without configuring the repository's benchmarks, example programs or documentation tests. [Package options](docs/release/package.md)
- Styling: typed style resolution, semantic tokens, scoped recipes and parts, combined states, system/contrast/locale policies, authoring/import tools and computed-style diagnostics; common geometry across transforms, clip chains, input, text, custom drawing, accessibility and damage, with explicit participation, device-grid rounding and caller-owned hit targets; composed decorations, brushes/image sampling, vector imports, masks, isolated groups, filters/backdrop operations, projective planes and managed color conversion; intrinsic sizes, rich shaping/fallback, font generations, advanced grids, typography/publication helpers and optional HarfBuzz variable/color-font consumers; cursor/native-material presentation, and animation-capacity failure that is observable without replacing unrelated controls. The styling gallery, a five-workload CPU benchmark and an inventory evidence check come with it. See [the implementation guide](docs/styling/README.md), [capability profiles](docs/styling/coverage.md) and [validation report](docs/styling/validation.md).

### Changed (incompatible)

- The framework is named LCGF. Downstream packages use `.lcgf` in their manifest, `@import("lcgf")` in Zig and `lcgf_render` for the selected renderer. The browser integration is `lcgf.js`.
- CPU `TextRun` and `CustomDraw` are 96 bytes: recompile consumers and update raw CPU-row serialization. The GPU `Quad` stays 136 bytes and `Look` 32. Runtime `Context` capacity is 1004 bytes a node.
- The X11, Wayland and Win32 shells take the caller's glyphs and images: `presentWith(out, glyphs, images)` (Wayland also `presentWindowWith`). `present(out)` draws with the bundled bitmap font, and the `font` and `text_texture` fields are gone. Text drawn through `present` is letters, where it was boxes unless the host set those fields.
- `x11.Window.refresh` is a per-window field read from RandR, not the constant 1/60 s.
- Shorten a tree with `Tree.truncate(n)`, not by assigning `len`: a push writes only the fields a node sets, and `truncate` puts the dropped rows back to their defaults.
- In ReleaseFast, `Tree.push`, `Frame.open` and `Frame.leaf` are `callconv(.@"inline")` (`tree.style_call`): they cannot be taken as run-time function pointers there.
- `lcgf_app`: `error.NoGpu` is gone. An `App` with `draw` runs in the software window too, where `Surface.live()` is false and `draw` is never called; branch on `live()` instead of the error.
- Canvas: `Instances.glyphs` is `protocol.Mono.canvasGlyphs` (`Instances.Text` is `Mono.Label`); `Options.marks`, `mark` and the `marks` column are `colors` (on by default) and `setColor`; the builders' `weight` and `dash = n` are gone (a layer per width, or a world-unit `.width`; a dashed layer); `Camera.zoom` and `Palette.zoom_scale` are gone (a layer width is logical pixels at every zoom); `View.of(cam, corner, px)` takes no palette. One `Instances` holds one kind of glyph, coverage or distance (a debug assertion). Each row carries 4 more bytes for its colour unless `.colors = false`.
- `ct_interop.region`, `fitRegion` and `canvas` with `.float = true` and a `.fill` size are a compile error that says to write `.pct(1)` or `.px(n)`; `Frame.custom` and `Frame.canvas` assert it in debug builds. Such a region was laid out 0 by 0 and `compose` returned `NoRegion`.
- `vk.Setup.init` takes the canvas capacities (`vk.Setup.Canvas`, `.{}` for none). A `vk.setup.Window` frame the window does not take returns `error.NotShown` instead of blocking.
- A timer of 0 seconds fires on the next frame, not in the call that starts it: `Output.wake` is 0, so the host gets the frame it asked for.

### Removed

- The HTML and CSS front end (`tools/lcgf-gen`, `addMarkup`) and the C ABI with the C++ and Rust bindings (`src/abi`, `tools/abi-gen`, `bindings/`). Write UIs with the runtime or comptime front ends in Zig.

### Known limits

- The GPU window is Vulkan over X11 on Linux (a Wayland session through XWayland when `DISPLAY` is set). Windows, macOS and native Wayland have no GPU window through `lcgf_app`: they draw in software, or with Metal on macOS.
- The composed path (`page` and `compose`) is tested on X11, in software and on Vulkan; on Wayland and Win32 it only compiles.
- macOS text is the bundled bitmap font, and the macOS window takes no application images yet.
- The canvas draws polylines without joins (a translucent stroke doubles where segments meet), tests every edge of a polygon per pixel, and has no curves or gradients; an arbitrary path goes through src/draw/paths.zig.
- A `Surface` draws only on the GPU window; the software window paints its node's fill.
- The examples other than examples/app and examples/surface still run on the software-only example host (`src/example/host.zig`, built with `-Drender=sw`). Read them for their UI code, not as the pattern for a build.
- The Metal back end is cross-built only; its device tests and goldens need a macOS runner (`ci/run.sh macos`, outside `all`).
- A canvas pan that comes from pointer input builds a frame, because input is handled in `build`: `Canvas.redraw` saves the build only for camera moves the program makes itself (an animation, follow, zoom to fit).
- A row of the canvas has one colour of its own, for both its stroke and its fill.
- Measurements on hardware: the GPU window was measured on an NVIDIA GeForce RTX 5060 at commit 71cae28e (docs/plans/window.md has the numbers and their conditions). At this tag the run could not be repeated: the display took about 30 of every 300 frames, on the earlier whole-redraw path as well, so the canvas redraw and the 100,000-row canvas have no hardware number. The GPU evidence for this tag is Mesa lavapipe.

## Maintaining the changelog

Add user-visible entries under **Unreleased** with the change that introduces them. Explain what a caller can do, which existing callers are affected and any migration needed. Link the guide, test or measured result that demonstrates it. Internal implementation changes need an entry when callers observe a behavior, performance, size, toolchain or compatibility difference.

Before a tag, compare the proposed revision to the previous release, review its dependency and compiler changes, and reconcile the entries with the actual diff. Rename the section to the released version and date, link the exact tag and comparison range, and start a new **Unreleased** section. The first release links the source tag directly. Publish the same notes with the tag, alongside the gate report for that revision. Mark unavailable or failing measurements explicitly. Apply the [compatibility policy](docs/release/compatibility.md) when classifying breaks or deprecations.
