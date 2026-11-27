# Changelog


## Unreleased — comprehensive styling branch

- Add typed style resolution, semantic tokens, scoped recipes and parts, combined states,
  system/contrast/locale policies, authoring/import tools and computed-style diagnostics.
- Extend common geometry across transforms, clip chains, input, text, custom drawing,
  accessibility and damage; add explicit participation, device-grid rounding and caller-owned hit targets.
- Add portable composed decorations, brushes/image sampling, vector imports, masks,
  isolated groups, filters/backdrop operations, projective planes and managed color conversion.
- Extend measured text/layout with intrinsic sizes, rich shaping/fallback, font generations,
  advanced grids, typography/publication helpers and optional HarfBuzz variable/color-font consumers.
- Extend cursor/native-material presentation and make animation-capacity failure observable
  without replacing unrelated controls.
- Preserve the 136-byte GPU Quad and 32-byte Look. CPU TextRun/CustomDraw are now 96 bytes;
  recompile consumers and update raw CPU-row serialization. Runtime Context capacity is 1004 bytes/node.
- Add the executable styling gallery, five-workload CPU benchmark and inventory evidence check.

See [the implementation guide](docs/styling/README.md), [capability profiles](docs/styling/coverage.md)
and [validation report](docs/styling/validation.md). Native platform and standards-conformance
boundaries are explicit; this is a development branch, not a versioned upstream release.

## Unreleased

- The framework is now named LCGF. Downstream packages use `.lcgf` in their manifest, `@import("lcgf")` in Zig and `lcgf_render` for the selected renderer. The browser integration is `lcgf.js`.

- Comptime front ends support bounded dynamic regions, shared geometry and ordered paint. Applications can mix runtime and comptime regions in the same draw list. [Comptime guide](docs/guide/comptime.md)
- Embedded builds support Q12.4 geometry, RGB565 and monochrome panels, single-scanline rendering and a fixed-panel integer firmware profile. The SPI simulator replays the board's counter example and checks the displayed pixels. [Package options](docs/release/package.md)
- Dependency builds can import the core and selected renderer without configuring the repository's benchmarks, example programs or documentation tests. [Package options](docs/release/package.md)
- `lcgf_app` draws on the GPU: a Linux build with the default back end (`vk`) opens the window as X11 with Vulkan, keeps the window's picture and redraws only inside each frame's damage. An `App` with `pub fn draw(*App, *lcgf_app.GpuFrame) !void` draws its own widgets, `lcgf_app.Surface`, through `lcgf_render.gpu`; a widget frame never calls `draw` and a surface frame never builds. `LCGF_RENDER=sw`, no `DISPLAY` or no Vulkan device falls back to the software window, where an `App` with `draw` gets `error.NoGpu`; naming `Surface`, `GpuFrame` or `draw` in a build without the GPU path is a compile error. Windows, macOS and native Wayland have no GPU window yet. [Surfaces](docs/guide/surface.md), [examples/surface](examples/surface/main.zig)
- Write an application with `lcgf_app.run` and leave `-Drender` at its default: the window layer falls back to software by itself. `-Drender=sw` is for microcontrollers, machines that must not load a GPU driver and the smallest static binary. On Linux an `lcgf_app` build links libc when its back end is a GPU one; a `-Drender=sw` build stays static. [Back ends](docs/guide/backends.md)
- `lcgf_app` draws text with real fonts at the window's scale: `Options.fonts` (font k is file k), else the system's default faces where the build can ask for them, else the bundled bitmap font. `Options.text` sizes the text service. macOS stays on the bitmap font. [Runtime guide](docs/guide/runtime.md#a-window-in-one-call), [text guide](docs/guide/text.md)
- `lcgf_app` takes an application's images through an optional `pub fn images(*App) []const lcgf_app.Image` (RGBA8, a size and a generation; at most `images_max`): `Style.texture` k + 1 is image k. It turns damage on, so an unchanged frame presents nothing and a changed one redraws only what changed. macOS draws every frame whole and takes no images yet.
- Canvas labels in real fonts, sharp at any zoom: `text.labels` in `lcgf_app` shapes a label with the text service's faces into canvas glyph rows that sample a distance atlas (`Glyphs.canvas`). `lcgf_app`'s own window does not run it yet.
- **Breaking:** the X11, Wayland and Win32 shells take the caller's glyphs and images: `presentWith(out, glyphs, images)` (Wayland also `presentWindowWith`). `present(out)` draws with the bundled bitmap font, and the `font` and `text_texture` fields are gone. Text drawn through `present` is letters, where it was boxes unless the host set those fields.
- **Breaking:** `x11.Window.refresh` is a per-window field read from RandR, not the constant 1/60 s, and display pacing follows it (a 120 Hz panel paces at 120 Hz). `x11.Connection.overrideScale` sets the scale; the screen's real size is read from RandR when the connection opens.
- **Breaking:** shorten a tree with `Tree.truncate(n)`, not by assigning `len`: a push writes only the fields a node sets, and `truncate` puts the dropped rows back to their defaults.
- **Breaking:** `vk.Setup.init` takes the canvas capacities (`vk.Setup.Canvas`, `.{}` for none). `vk.setup.Window` keeps the window's picture: `begin` and `present` split a frame around the application's own passes, `draw` stays the one-call form, and a frame the window does not take returns `error.NotShown`.
- Damage: `Context.trackDamageWhole` records the region and leaves the draw list whole, for a host that keeps the rows on the GPU. A text run that overflows its node damages where its glyphs reach. `ct_interop.compose` carries the union of both sides' damage instead of the whole window, with `ComptimeUi.recordDamage` on the comptime side.
- The bundled bitmap font has a cell for every byte from 32 to 255 (ASCII, Windows-1252, and the infinity sign at 0x81); `Mono.encode` turns UTF-8 into those bytes.
- A timer of 0 seconds fires on the next frame, not in the call that starts it: `Output.wake` is 0, so the host gets the frame it asked for.
- **Removed:** the HTML and CSS front end (`tools/lcgf-gen`, `addMarkup`) and the C ABI with the C++ and Rust bindings (`src/abi`, `tools/abi-gen`, `bindings/`). Write UIs with the runtime or comptime front ends in Zig.

## Maintaining the changelog

Add user-visible entries under **Unreleased** with the change that introduces them. Explain what a caller can do, which existing callers are affected and any migration needed. Link the guide, test or measured result that demonstrates it. Internal implementation changes need an entry when callers observe a behavior, performance, size, toolchain or compatibility difference.

Before a tag, compare the proposed revision to the previous release, review its dependency and compiler changes, and reconcile the entries with the actual diff. Rename the section to the released version and date, link the exact tag and comparison range, and start a new **Unreleased** section. The first release links the source tag directly. Publish the same notes with the tag, alongside the gate report for that revision. Mark unavailable or failing measurements explicitly. Apply the [compatibility policy](docs/release/compatibility.md) when classifying breaks or deprecations.
