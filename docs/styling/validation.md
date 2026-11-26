# Styling implementation validation

Recorded **2026-11-24**, using Zig **0.18.0-dev.1151+8dfb7a7cc**. Runtime, test, example and tool source is committed as **`b0ab2bd0e6b6a10c799a36d4117f49bf391ee2ef`** on `feat/comprehensive-styling`, based on upstream **`ed94db3da27882ef1c87d0dd15a382b4df39e2c2`**. Documentation, coverage and these measured results are committed immediately afterward. The delivery manifest identifies the complete final branch head.

## Result

The final combined Linux gate completed **49/49 steps** with **1,508 passing Zig tests**, **2 platform-specific skips**, and **no failures or crashes**. The skipped cases require Windows or macOS. The Python authoring tests also passed, as did the complete inventory-evidence check and formatting.

| Suite or check | Observed result |
|---|---:|
| Core styling/layout/input/text/render tests | 1,428 passed |
| HarfBuzz adapter and actual font consumers | 13 passed |
| Wayland protocol/cursor fixtures | 31 passed |
| OpenGL ES backend/shader/prepared-texture checks | 14 passed |
| AccessKit C bridge | 6 passed, 2 OS-specific skips |
| Executable documentation examples | 16 passed |
| Documented Zig snippets | 30 checked against compiled examples |
| Expected compile-error examples | 26 checked |
| Python token importer/compiler regressions | 8 passed |
| Research inventory groups with source and named evidence | 158/158 validated |
| Zig formatting, Web shell syntax, Git whitespace check | Passed |

The GL ES log intentionally contains an undeclared `nope` shader diagnostic: the negative shader-compilation test checks that invalid shader source is rejected. Its containing suite reports success. This is not a failed final build.

The [coverage profiles](coverage.md) state what each consumer does and its boundaries; a profile is not a claim of standards conformance.

## Meaningful combined behaviors exercised

The checks include semantic token identity when two roles initially share the same color; transparent/zero/inherit precedence; simultaneous selected, hovered and keyboard-focus states; runtime/compile-time recipe behavior; and invalid, required and busy state exported through the real AccessKit C bridge.

Geometry checks cover transformed text/custom paint, rounded ancestor clipping, old/new damage extents, layered hit order, larger input targets, per-contact capture, inactive compile-time choice alternatives and fractional device-grid rounding. Captured touches are cancelled when their owner disappears or becomes ineligible, including an omitted lift event and a disable/re-enable sequence.

Text checks exercise actual shaping and metrics, paint-only spans, cluster-safe fallback/editing, bidi, whitespace/tailored breaking, named grids, emphasis, baselines/edge trim, font generation keys and optional HarfBuzz features. HarfBuzz fixtures cover CFF/CFF2, variations, color palettes, COLRv1 paint operations, bitmap color glyphs and the declared plain/gzip SVG-glyph profile.

Paint checks combine gradients, asymmetric borders, elliptical corners, shadow/outline bounds, image placement and sampling, vectors, completed-group opacity, masks, filters and backdrop source invalidation. Borrowed image/coverage inputs cannot alias outputs that would clear or overwrite them. Failure tests check the entire destination and scratch buffers remain unchanged when an alias is rejected.

The final component regressions use real input and emitted rows: radio arrows/selection, two range thumbs, spinner phase and wake deadlines, menu submenu navigation, styled accelerator/indicator/separator content, tooltip arrows and focused help, breadcrumb activation, popover custom content and toast timing. Hidden parts cancel action before native behavior runs. Composite compile-time failures preserve exact inert row topology and native IDs, keep a later button usable, and recover on the next valid frame. Hidden/collapsed ancestors and reduced motion suppress spinner wakes.

## Renderer comparison and native platforms

The prepared-paint fixture renders a gradient, asymmetric patterned border, shadow, outline and elliptical corners; overlaps another opaque child; applies a gradient mask and isolated group opacity; exports straight-alpha RGBA; and uploads the result through the ordinary image-texture path. The emitted quad also carries translation and opacity. Both ES2 and ES3 backend paths are compared with stock software output on transparent and opaque backgrounds, with a maximum permitted **2/255 error per channel**. Nonempty translucent color and outside-border paint assertions prevent an empty image from passing.

The actual driver was **Mesa 25.0.7-2+deb13u1, llvmpipe LLVM 19.1.7**, through EGL 1.5 surfaceless contexts. Mesa reported OpenGL ES 3.2 for both requested minimum context versions; the tests exercised the distinct ES2 and ES3 renderer/shader routes. This is real driver execution on a software implementation, not physical-GPU validation. Exact observations are in [renderer-host.json](renderer-host.json).

| Native target | Build result | Execution boundary |
|---|---|---|
| Windows x86-64 | 5/5 build steps; tests compile and link | No Windows desktop or runtime session |
| macOS arm64 | 6/6 build steps; tests compile and link | No macOS desktop or runtime session |
| Wayland | 31 passing protocol fixtures | No claim of an interactive desktop/compositor session |
| Web shell | `node --check` passed | No browser-native rendering or DOM accessibility audit |

Native material/cursor fidelity, assistive-technology interaction and physical display color behavior still require the relevant hosts. HDR conversion is implemented as explicit color/output operations; HDR swapchain negotiation, ICC integration and display headroom remain host responsibilities. Projective plane painting is implemented; retained depth-aware preserve-3D remains a separately declared host capability.

## Rendered gallery

[gallery.png](gallery.png) is a **1000×800** image generated by [the public Zig caller](../../examples/styling/gallery.zig). It was visually inspected for clipping, layout and legibility, and regenerated from the final source. The output hash remained unchanged after the lifecycle/alias corrections.

It demonstrates layered gradients and edges, image fit/tiling, corner contours, SVG/vector strokes, projective textured planes, clipping, isolated groups and backdrop filtering. It is output from the implementation, not an artwork mockup.

## Measured CPU workloads

[benchmark.json](benchmark.json) contains phase timings, first measured frames, warm percentiles, damage bounds, draw command counts, storage/pass costs and output checksums. [benchmark-host.json](benchmark-host.json) records the source commit, host and methodology. The executable is [examples/styling/bench.zig](../../examples/styling/bench.zig).

Host: **Intel Xeon Platinum 8573C**, Linux x86-64. The process was **not pinned**, and the machine was **not isolated**. These measurements use ReleaseFast and full software framebuffer redraws at scale 1. Each scene records one first measured frame and 128 subsequent frames. The first frame is not a cold process launch or a cold OS/CPU-cache measurement. The dense/theme/sparse workloads are box controls without text labels; complex shaping is functionally checked separately and is not timed in this table.

| Workload | Pixels | Nodes | Median ms | p95 ms | p99 ms |
|---|---:|---:|---:|---:|---:|
| Dense static controls | 1280×720 | 769 | 1.973 | 4.447 | 4.836 |
| Theme switch each frame | 1280×720 | 769 | 2.010 | 3.907 | 4.712 |
| Eight active animations | 1280×720 | 769 | 2.277 | 5.217 | 7.090 |
| Scrolling/zooming technical canvas | 1280×720 | 286 | 4.640 | 7.999 | 9.928 |
| Gradient/blur/filter/blend panel | 320×180 | 0 | 6.759 | 11.188 | 13.964 |

The technical canvas changes dock width, scroll and zoom; the theme scene changes its semantic palette each frame; the sparse-motion scene animates eight of 768 controls. Static-scene warm damage is zero, while theme changes cover a large area. Raster timing still redraws the entire framebuffer, so an application's damage-aware presentation policy does not hide raster cost in these numbers. Damage is the clamped union bounding-box area, not an exact changed-pixel count.

The effects panel executes **8 full-surface passes** and reports **1,451,776 bytes** of surface/kernel storage (about **1.38 MiB**). It is a 320×180 workload, not a full-HD filter benchmark. The source contains no allocation calls inside the timed paths; setup and JSON export are outside them. This allocation statement comes from source/ownership inspection, not allocator instrumentation.

No equivalent upstream benchmark was run. These results establish reproducible workload observations and costs on this host, not a speedup, regression percentage, latency guarantee or exhaustive performance result. Shared-host scheduling affects the upper percentiles; the full recorded run is retained without selecting a faster repeat.

## Memory and compatibility

| Representation | Current | Upstream/reference |
|---|---:|---:|
| GPU `Quad` | 136 B | 136 B |
| Compact `Look` | 32 B | 32 B |
| Runtime context capacity per node | 1004 B | 924 B at the pinned upstream baseline |
| CPU `TextRun` | 96 B | Intentional CPU-row layout change |
| CPU `CustomDraw` | 96 B | Intentional CPU-row layout change |

The context increase is **80 bytes per node of capacity**, about **8.66%**, covering two generations of extra paint metadata. The benchmark's 1,024-node context is **1,056,896 bytes**, including its other fixed limits. Prepared surfaces, style pools/caches, hit-target entries and extended text/layout storage are separate caller-owned budgets. Recompile CPU consumers and update any raw serialization of text/custom rows. Source callers using named fields receive the documented defaults.

## Reproduce

```sh
zig build test harfbuzz wayland gles accesskit docs styling-check fmt -Drender=sw -j2 --summary all
zig build win32-build -Dtarget=x86_64-windows -Drender=sw -j2 --summary all
zig build macos-build -Dtarget=aarch64-macos -Drender=sw -j2 --summary all
zig build styling-gallery -Drender=sw -Dgallery-output=docs/styling/gallery.png
zig build styling-bench -Drender=sw -- docs/styling/benchmark.json
node --check src/shell/web/shell.js
git diff --check
```

Use the pinned toolchain and dependency manifest. The optional native/GL steps need their stated host libraries; cross-compilation is distinct from execution.
