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
commands the host reads. The host owns the loop, the memory and the GPU objects.

## Tiers

A tier may use the tiers before it and nothing after it.

| Tier | What | Directories |
|---|---|---|
| 0 | Plain data and free functions over columns. No allocator, no I/O, no OS, no GPU. | `src/core/`, `src/layout/`, `src/interact/`, `src/draw/`, `src/text/`, `src/anim/`, `src/a11y/` (tree only) |
| 1 | A front end that owns the columns and sequences the tier-0 passes. Two exist: runtime (`Context` / `Frame`) and comptime (`Ui(State, spec)`). | `src/runtime/`, `src/comptime/` |
| 2 | Conveniences written only against the public API of tiers 0 and 1: widgets, themes, reuse, animation helpers. | `src/widgets/`, `src/theme/` |
| outside | Renderers consume a `DrawList`. Shells produce `Input` and present frames. Neither is imported by tiers 0 to 2. | `src/render/*/`, `src/shell/*/` |

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
output), text runs, and `custom` commands that hand a rectangle back to the host. Back ends:

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
- **C++ and Rust** reach the comptime front end through two seams, not a C++ or Rust binary
  interface. Above the first, `lcgf-gen` runs the same `plan` (src/abi/plan.zig) that Zig runs at
  comptime, and writes tables and inline code in the user's language. Below the second, the
  prebuilt liblcgf reads those tables through a few `extern "C"` calls per frame (src/abi/lcgf.h).
  The tables carry a version and a layout hash. Draw lists match Zig's byte for byte
  (ci/jobs/bindings.sh). The table logic exists once: `ComptimeUi` pushes its rows from the same
  plan, made at comptime, through the same `plan.emit` the seam's frame calls; only its walk of
  the spec (regions, custom widgets with Zig code) is its own. The runtime front end crosses too
  (src/abi/runtime.zig): C++ and Rust make each row from its style themselves (folded at compile
  time when the style is constant) and store it into the frame's columns inline, so a runtime
  UI costs what it costs in Zig; the other calls are one direct call each. Static UIs cross
  as well (src/abi/ct.zig): `lcgf-gen --static` makes the comptime pipeline's tables (fold,
  constant columns, paint templates) with the functions `ct_layout` and `ct_paint` call at
  comptime (src/comptime/tables.zig) and writes them as compile-time constants, and the
  tier-0 passes, the paint and the hit test are ported to C++ templates (lcgf/ct.hpp) and
  Rust generics (lcgf::ct) compiled against them, so the compiler folds them as Zig's does.
  Draw lists and events match Zig's byte for byte; Rust and clang run at Zig's speed or
  faster. liblcgf runs the same tables through its own frame too (`SeamUi`). The GPU projection is written per language on Vulkan, GL ES 3, wgpu-native, Metal
  and Direct3D 12. docs/guide/bindings.md.
- **One per build.** `-Drender=auto|sw|vk|metal|d3d12|gles|web|wgpu` picks the back end the
  `lcgf_render` module exposes (src/render/select.zig); `auto` is the target's own API (Metal on
  Apple, Direct3D 12 on Windows, Vulkan on Linux and Android, web on wasm32, software on
  freestanding). Only that back end is compiled and nothing dispatches: its `.text` is
  byte-identical to a direct import (ci/jobs/render-select.sh). The host still owns device,
  queue and pass; for one that brings none, `Setup` (vk, metal, sw) holds what the shells made.
  A run-time fallback (Vulkan, then GL ES) is left until a target needs it; it must initialise
  the second back end only after the first fails. docs/guide/backends.md says which to pick.
- **Gompute** (CUDA / HIP compute kernels): measured and dropped. Lane render-gompute built it
  (C0418-C0425) and it lost to the Vulkan back end on every measure on an RTX 4060: frame time,
  resident and GPU memory, start-up, vendors, and presenting. docs/research/gompute.md has the
  numbers; Vulkan compute covers the offscreen effects it was meant for.

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
- The caller owns memory (one buffer, carved into columns) and the loop.
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
