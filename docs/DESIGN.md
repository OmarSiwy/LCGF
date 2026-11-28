# Design

What is being built, the decisions already taken, and why. Read this before changing structure.
The initial implementation is preserved in the project history. [Archived prototype](https://github.com/OmarSiwy/LCGF/tree/b6c1319/prototype)

## Goal

A GUI framework in Zig that is lighter and faster than the frameworks in `docs/TARGETS.md`
while giving the application full control, down to the GPU pass. "Better" is not a matter of opinion
here: `docs/GATES.md` lists what is measured, against which frameworks, and by which tool. A claim
that no gate measures is not a claim this project makes.

## The frame, as data

```
Input ──► front end ──► Tree columns ──► layout passes ──► hit test / interaction
(host)    (runtime or    (SoA, u32        prepare, measure,   (one SIMD sweep,
          comptime)       indices)        fit, resolve,        no early exit)
                                          wrap, place,
                                          finalize                  │
                                                                    ▼
host GPU pass ◄── renderer ◄── DrawList (flat commands) ◄── paint (three sweeps)
```

Every arrow is plain data owned by the caller. There are no callbacks: text measurement, custom
drawing and platform effects (cursor, clipboard, IME position) cross the boundary as rows and
commands the host reads. The host owns the loop, the memory and the GPU objects. The window
layer, `lcgf_app`, is one such host, for an application that would rather not be one.

## Tiers

A tier may use the tiers before it and nothing after it.

| Tier | What | Directories |
|---|---|---|
| 0 | Plain data and free functions over columns. No allocator, no I/O, no OS, no GPU. | `src/core/`, `src/layout/`, `src/interact/`, `src/draw/`, `src/text/`, `src/anim/`, `src/a11y/` (tree only) |
| 1 | A front end that owns the columns and sequences the tier-0 passes. Two exist: runtime (`Context` / `Frame`) and comptime (`Ui(State, spec)`). | `src/runtime/`, `src/comptime/` |
| 2 | Conveniences written only against the public API of tiers 0 and 1: widgets, themes, reuse, animation helpers. | `src/widgets/`, `src/theme/` |
| outside | Renderers consume a `DrawList`. Shells produce `Input` and present frames. Neither is imported by tiers 0 to 2. | `src/render/*/`, `src/shell/*/` |
| 3 | The window layer, `lcgf_app`: an application in a desktop window in one call. It owns the shell, the device, the swapchain, the fonts and the pacing, and uses everything above it in this table, renderers and shells included. Nothing imports it. | `src/app/` |

Granularity rule (from the API guide): every tier-1 or tier-2 call must be replaceable by a few
tier-0 calls, and the test `tier 0 alone` in `src/layout/layout.zig` exercises that contract.

## The four rules, and how each is checked

**Data-oriented.** Per-node properties are columns (struct of arrays) grouped by the pass that reads
them; fields always read together are one row (`Look`, the child clip). Nodes, text runs and custom
draws refer to each other by `u32` index, never by pointer. Checked by: layout-size tests for every
`extern` and `packed` type, and the bytes-per-node number in the benchmark.

**SIMD.** Passes whose rows are independent are written
with `@Vector` over padded columns, with no scalar tail. Passes that follow parent links stay scalar,
because a child needs its parent's result. Checked by: tests at 4, 8 and 16 lanes against scalar
reference implementations.

**Branchless.** No data-dependent branch inside a per-row loop. Selects are masks, modes are
coefficients or table indices, filtering is "write always, advance by 0 or 1". What remains is loop
control and one coarse branch per reused subtree. Checked by: the branch census (`docs/CHECKS.md`),
which counts conditional jumps in the compiled passes.

**API design.** Five properties, from `.claude/skills/system-api-design/SKILL.md`: granularity (see
above), redundancy (one-call shortcuts exist for the common case), no coupling (nothing requires
hidden global state), no retention at the lowest tier (the caller owns all memory), and flow control
stays with the caller (no callbacks, no framework-owned loop). Write the usage code first: a new
public function arrives together with the test that uses it.

`lcgf_app` is the one place that owns a loop and calls the application back (`build`, `draw`,
`images`), and an application chooses it. Everything it does is a few public calls of the layers
under it (`Context`, the shells, the back end's `Setup.Window.begin` and `present`, `Surface`), so a
host that needs its own loop makes those calls itself.

## Two front ends over one core

**Runtime** (`Context`, `Frame`): the tree is rebuilt each frame by calling `open` / `leaf` / `close`.
Handles any data-driven UI. Signals and `Frame.reuse` let unchanged subtrees be copied instead of
rebuilt. See `src/runtime/context.zig` and `src/runtime/frame.zig`.

**Comptime** (`Ui(State, spec)`): the UI is a compile-time value. The current implementation lives in `src/comptime/`. The original Zig 0.17.1 probe established its storage model. [Archived probe](https://github.com/OmarSiwy/LCGF/blob/b6c1319/prototype/comptime_ui_probe.zig)

- Structure and style become read-only tables; only state, dynamic rectangles and a dirty mask are in
  RAM. The probe's 8-node UI needs 104 bytes.
- Index and mask types are the smallest that fit (`u4` indices for 8 nodes).
- The signal graph is resolved by the compiler: each state field has a constant mask of the nodes it
  affects, and a setter is one store plus one OR. No subscriber lists, no allocation.
- Mistakes are compile errors: duplicate ids, a binding to a missing or wrongly typed field, an
  unknown widget name (ids become a generated `Widget` enum).
- Only the widget kinds, shader features and glyphs the spec mentions are compiled in.
- Capacity is exact, so there are no limits to configure and no overflow path.

Its limits, which is why both front ends exist: signal *values* are runtime (only identity, type and
dependencies are comptime); lists of unknown length need a bounded dynamic region or the runtime
front end; changing the UI means recompiling; compile time and code size grow with the spec and have
their own budget lane (`ct-budget`).

Both front ends fill the same tier-0 columns and produce the same `DrawList`.

## Rendering

The core emits a `DrawList`: instanced quads (rounded-box SDF, clip as coverage, premultiplied
output), text runs, `canvas` batches (LCGF's own instanced primitives under a camera), and
`custom` commands that hand a rectangle back to the host. Back ends:

- **Software**: required. It is the floor for memory and the only option on microcontrollers.
- **Vulkan, Metal, Direct3D 12, GL ES, web**: thin native back ends. They exist because the overhead
  worth removing is the abstraction and validation layer above the GPU API, not the API.
- **wgpu**: the portable back end, and the route for applications that want raw wgpu. The host owns
  the device, queue and pass. The production interface documents five kinds of raw access. [wgpu backend](../src/render/wgpu/wgpu.zig)
- **`lcgf_render.gpu`**: custom drawing written once, in WebGPU's object model and WGSL, projected
  at compile time onto the selected back end's API (src/render/gpu/, each back end's `gpu.zig`).
  It is not a portability layer:
  - its types are the native handles, with public fields;
  - its calls compile to the native calls (ci/jobs/gpu-zero-cost.sh: instruction-identical to
    hand-written Vulkan);
  - nothing tracks state. The caller owns the memory (an `Arena`), a frame moves through fixed
    phases (upload, then passes), and textures rest in one layout between passes;
  - bind groups are structs reflected from the WGSL, so binding mistakes are compile errors.

  naga translates the WGSL when you build, or the translations are committed. It replaced the
  wgpu-native guest experiment (docs/research/custom-webgpu/), which needed a second device
  object model, a second submission per redraw and 4.57 MiB. docs/guide/gpu.md.
- **One per build.** `-Drender=auto|sw|vk|metal|d3d12|gles|web|wgpu` picks the back end the
  `lcgf_render` module exposes (src/render/select.zig); `auto` is the target's own API (Metal on
  Apple, Direct3D 12 on Windows, Vulkan on Linux and Android, web on wasm32, software on
  freestanding). Only that back end is compiled and nothing dispatches: its `.text` is
  byte-identical to a direct import (ci/jobs/render-select.sh). The host still owns device,
  queue and pass; for one that brings none, `Setup` makes them: `vk` (with `vk.setup.Window`,
  used by the Android shell and the X11 GPU window), `metal` (the iOS shell) and `sw` (the X11,
  Wayland and Win32 shells). Direct3D 12, GL ES, wgpu and web have none. A run-time fallback
  between GPU APIs (Vulkan, then GL ES) is left until a target needs it; it must initialise the
  second back end only after the first fails. docs/guide/backends.md says which to pick.
- **The window layer keeps the picture.** A window draws again only what changed, so a widget
  and a surface beside it never redraw each other. `vk.setup.Window` keeps one image of the window's
  size between frames; `begin` gives the frame's command buffer and upload phase, `present`
  draws the UI into the picture scissored to each damage rect, from rows that stay on the GPU
  until a new list replaces them, and copies the picture to the swapchain. The context records
  damage without culling the list (`Context.trackDamageWhole`), so the rows always describe
  the whole window. `sw.Setup.draw` does the same in software: the framebuffer is the picture.
- **An application's own GPU drawing is a `Surface`**: a texture the application renders with
  `lcgf_render.gpu` in `draw`, shown as an ordinary quad at its node's place in paint order, as
  a `<canvas>` is in WebGPU. Widgets and surfaces are drawn again independently: a widget
  frame runs `build` and never `draw`; a surface frame runs `draw` and redraws its rectangle
  from the rows already on the GPU, with no build and no upload of rows. A window that is not
  shown gives its frame up and owes the whole window. Inline custom drawing (`Frame.custom`,
  `drawUntilCustom`) stays below the window layer, for a host that owns its loop and its pass.
- **Where the window layer has a GPU.** Vulkan over X11 on Linux, the default there (a Wayland
  session through XWayland when `DISPLAY` is set). Its tests run on Mesa lavapipe in CI and
  pass on an RTX 5060. On that GPU a presented frame costs about the same CPU time to submit and
  present whatever it draws, so what the kept picture saves is the build, layout and paint a
  surface frame skips and the `draw` a widget frame skips (docs/plans/window.md, "Landed").
  On macOS the window layer runs on Metal in an AppKit window (src/app/gpu_macos.zig), its
  text from the text service over Core Text's faces; it compiles and links here but has not
  run on a Mac. Windows and native Wayland have no GPU window through `lcgf_app`.
  `LCGF_RENDER=sw`, no display, an X server that cannot be reached or no Vulkan device falls
  back to the software window (on macOS, which has none, the shell's own Metal window). Every application runs there: `draw` is
  never called and a `Surface` is not live (`Surface.live`), so its node paints its fill and
  `build` can show something else. A GPU build links libc on Linux (the loader is opened at
  run time); `-Drender=sw` does not. docs/plans/window.md is the plan; docs/guide/surface.md
  the guide.
- **Gompute** (CUDA / HIP compute kernels): measured and dropped. Lane render-gompute built it
  (C0418-C0425) and it lost to the Vulkan back end on every measure on an RTX 4060: frame time,
  resident and GPU memory, start-up, vendors, and presenting. docs/research/gompute.md has the
  numbers; Vulkan compute covers the offscreen effects it was meant for.

### An application's own drawing: three layers

Qt Quick, GTK 4, egui, Dear ImGui, iced, Slint, LVGL and the web platform each give an
application three ways to draw what their widgets cannot, and LCGF gives the same three:

| Need | Mechanism | LCGF's job | The application's job |
|---|---|---|---|
| Raw GPU drawing | `Surface` (`Frame.custom` for a host that owns its loop) | the texture, its place in paint order, independent redraw | passes, pipelines, WGSL |
| 2D drawing identical on every back end, software included | `Frame.canvas`: a batch command in the `DrawList` | the shader, its software twin, parity goldens | fill the columns, own the camera |
| No GPU at all | `lcgf_app.Image`: CPU pixels, filled with `src/draw/paths.zig` or the application's own code | show it and damage it | rasterize |

LCGF owns the second layer because application code names no back end only if the
application's 2D content is in the `DrawList`: anything drawn outside it is drawn with some back
end's API. So the canvas is one WGSL source (`src/render/shaders/canvas.wgsl`) and a Zig twin in
the software back end (`src/render/sw/canvas.zig`), held to the same pixels by the `canvas` and
`labels` goldens. A new canvas kind lands only with its software twin and a golden.

The canvas is general, not one application's: a row is 32 bytes plus its own colour (0 for its
layer's), the palette of layers is optional, a stroke is its layer's width in logical pixels or
the row's width in world units, a dashed layer holds its on and off lengths, and the canvas knows
no font (`protocol.Mono.canvasGlyphs` and `lcgf_app`'s labels write glyph rows). Its limits are
stated with it (src/draw/canvas.zig): polylines have no joins, a polygon tests every edge per
pixel, and there are no curves or gradients; an arbitrary path goes through src/draw/paths.zig.

`Surface` has no software fallback. Its pixels are defined by the application's shaders and
pipeline state, so running them takes an implementation of the GPU API and a shader compiler,
which is what a software driver (lavapipe, WARP) is. No framework ships one, and WebGPU makes a
fallback adapter optional. Where a software Vulkan driver is installed, a surface runs on it
unchanged.

## Code standard: which "clean code" rules apply

Adopted: names that say what a thing is for; functions that name one step of a pass; tests next to
the code; comments that say why, not what; extract shared code after the second use, not before; one
logical change per commit, and every commit builds and passes.

Rejected in tiers 0 and 1, because they cost what this project is trying to save: interfaces and
virtual dispatch for per-node behaviour; hiding data behind accessors; methods that process one
node at a time; splitting a batch loop into small per-row functions. Organise code by operation over
many rows, not by object.

See the [code standard](CODE_STANDARD.md) for implementation and review rules.

## Decisions that are settled

Do not reopen these inside a commit. If one looks wrong, say so in your report.

- Zig 0.18.0-dev.1151+8dfb7a7cc exactly (pinned in `flake.nix`; moved from 0.17.1 for its loop auto-vectorizer,
  `docs/ZIG_0_17_1.md`). No features from other builds.
- Tiers 0 to 2 depend on `std.simd`, `std.math`, `std.mem` and the parts of std that neither allocate
  nor touch the OS (`std.hash`, `std.fmt.comptimePrint`, `std.meta`, `std.testing` in tests): no libc,
  no allocator, no `std.Io`. (Widened from simd/math/mem only: the prototype's `Id` hashes with
  `std.hash.Fnv1a_32`.)
- The caller owns memory (one buffer, carved into columns) and the loop. `lcgf_app` owns them
  for an application that runs in it, through the same public calls.
- Ids are hashed from source location or name; state lives in the application, not in widgets.
- One `DrawList` format for every renderer. Renderers are generic over a small binding namespace.
- Accessibility is a column set (`role`, `value`) on the same tree, bridged outside the core.

## Numbers from the prototype

These historical measurements used one 2.1 GHz Xeon VM core, ReleaseFast and eight SIMD lanes. Current checks run against the production package. [Archived prototype](https://github.com/OmarSiwy/LCGF/tree/b6c1319/prototype) · [Production checks](CHECKS.md)

| What | Value |
|---|---|
| Full frame, 3,961 nodes and 1,320 text runs (build + layout + hit + paint) | 0.34 to 0.46 ms across runs |
| Memory per node of capacity, runtime front end | about 0.65 KB |
| RAM for an 8-node comptime UI | 104 bytes |
| Idle | `needsFrame()` is false and no work is done |
| Conditional jumps inside per-row loops | loop control only |
