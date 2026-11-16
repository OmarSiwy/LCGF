# LCGR performance results

The measured numbers, in one place, with the conditions they were taken under and the commit
that produced each one. Every number here comes from a tool in docs/CHECKS.md and can be
reproduced with the command given under it. Where LCGR is not the fastest, this file says so.

Machine for every number below unless a section says otherwise: Intel Core i9-14900HX
(32 hardware threads), 31 GiB RAM, Linux 7.0.10, Zig 0.18.0-dev.1151+8dfb7a7cc, ReleaseFast,
benchmark pinned to one CPU. Timings are medians. "Load" is the 1-minute load average during
the run; above about 8 (a quarter of the CPUs) timings on this machine inflate by up to 40%.

Last measured: 2026-11-16.

## Against other GUI libraries

The same five scenes built in eight libraries, each through its own API, on the CPU, no window
(bench/vs/, docs/perf/vs.md for what a frame is in each). LCGR at perf-gaps dd2b77f; the other
libraries at the versions in docs/perf/vs.md. One `ci/run.sh gates-vs` run, every harness pinned
to the same CPU, medians of 5 runs (first frame: 11 starts), load 3.0 to 5.2. These are the
values in bench/gates/recorded.json.

| Row | LCGR | Best other | Ratio | Gate |
|---|---|---|---|---|
| form, per poll | 0.1 us | LVGL 9.6.0, 0.7 us | 0.14x | met |
| text, per poll | 0.1 us | LVGL 9.6.0, 1.0 us | 0.10x | met |
| resize, per frame | 16.7 us | Clay 0.14, 34.3 us | 0.49x | met |
| list, per frame | 11.6 us | Dear ImGui 1.93.0, 11.0 us | 1.05x | not met |
| springs, per frame | 74.6 us | Dear ImGui 1.93.0, 52.6 us | 1.42x | not met |
| Resident memory after one idle frame | 436 KiB | Clay (static, musl), 420 KiB | 1.04x | not met |
| Time to first frame | 0.32 ms | Clay (static, musl), 0.31 ms | 1.03x | not met |
| Loaded bytes + bss, ReleaseSmall | 59,755 + 34,176 B | Clay, 99,198 + 101,296 B | 0.60x / 0.34x | met (not a gate) |
| Layout alone, wasm32, ReleaseSmall | 32,146 B (13,698 gzipped) | Clay, 72,011 B (26,331 gzipped) | 0.45x | met (not a gate) |
| Idle wake-ups per second | 0 | Clay, ImGui, egui, Iced, Slint, Qt Quick: 0 (LVGL 30) | | met |

Against Clay, LCGR is faster on every frame row and smaller in bytes and wasm; resident memory
and first frame are within 4% of Clay's, on Clay's side. How each row is made fair:

- The LCGR row is `bench/vs/lcgr/main.zig`: harness.h's driver over LCGR's frame and nothing
  else, a static binary without libc (until d94b562 it was the per-pass benchmark, carrying the
  prototype core: 280 KB loaded and 11.8 MB bss).
- Every harness sizes its tables for the scene (harness.h `vs_capacity`), Clay through
  `Clay_SetMaxElementCount`.
- Clay's resident memory and first frame are measured on a static musl build, so neither row
  pays for a dynamic C library (with glibc Clay is 2,000 KiB and 0.45 ms); its frames stay on
  glibc, its fastest, and its size on the dynamic build, its smallest.
- The wasm row builds Clay's layout of the same three-box frame the same way as LCGR's
  (bench/vs/clay/layout.c; `zig build vs-clay`). Clay's README states 15 kB; 0.14 builds to
  72,011 B here, 76,530 B with its whole API exported as its website builds it.

What is left against Clay is LCGR's working set: after one frame of the 200-node form at
capacity 256 it touches about one page per column of the current tree, the shared layout
scratch and the second generation's default extras row, plus the draw list (136 bytes a quad)
and text rows. Clay's single arena touches about 136 KB, LCGR's columns about 200 KB; LCGR's
code pages are fewer (128 against 204 KB). Closing it needs fewer bytes per node or one tree
generation, a tree and layout change.

form and text are timed per poll in every harness: each library decides for itself whether a
poll needs work. In these two scenes only the pointer moves; LVGL redraws nothing it does not
need to, and LCGR since 63e0c92 builds no frame for a pointer move over nodes that sense
nothing (908 of 3,000 polls built in form, 2 of 3,000 in text). list, springs and resize build
every frame in every harness.

Reproduce: `nix develop .#vs -c ci/run.sh gates-vs` (builds all eight harnesses and measures
them in one run; bench/gates/README.md is the published gate table).

### How the gaps closed (perf-gaps branch)

| Gate | Before | After | What changed |
|---|---|---|---|
| form against LVGL | 22.6x | 0.06x | 63e0c92: no frame for pointer moves over nodes that sense nothing |
| text against LVGL | 17.9x | 0.10x | same |
| Resident memory against Clay | 12,104 KiB, 5.66x | 1,624 KiB, 0.78x | 01c5d19 (harness: no differential check in the idle probe), 411f77f (`Carver.zeroed`: untouched capacity never becomes resident), 3d4f32a (no 256 KB signal stack) |
| Time to first frame against Clay | 2.90 ms | 0.47 ms | same three commits |
| Benchmark binary bss | 13.86 MB | 11.81 MB | 661c4e1, 3d4f32a |
| LCGR row against Clay: resident, first frame, size | 1,624 KiB, 0.47 ms, 280,235 + 11.8 MB bss | 436 KiB, 0.32 ms, 59,755 + 34,176 B (Clay static 420 KiB, 0.31 ms; Clay 99,198 + 101,296 B) | d94b562: the LCGR row does only what Clay's harness does; capacities per scene and a static Clay for both sides |

Springs is the gap left: its profile is flat (Tree.push 26%, paint 16%, the scene's animation
15%, level resolve 13%); ImGui places each bar in one pass, LCGR runs its full flex layout over
every node. docs/perf/vs.md has the breakdown.

## GPU back end: native Vulkan against wgpu-native

The Vulkan back end (src/render/vk) and the wgpu back end over wgpu-native v29, the same scenes,
ReleaseFast, offscreen targets. Source: docs/research/render-select.md (commit 13061c1), which
re-measured C0389's numbers and corrected two of them.

CPU time per frame (medians):

| Driver | LCGR Vulkan | wgpu-native | Ratio |
|---|---|---|---|
| NVIDIA RTX 4060 Laptop GPU (driver 595.71.05) | 5.8 us | 16.1 us | 2.8x less |
| Mesa 26.3 lavapipe (software Vulkan) | 5.3 to 7.0 us | 34.6 to 44.8 us | about 6x less |

Whole frame on the RTX 4060, until the GPU is done: 36 us against 54 us.

Where wgpu's extra CPU goes (lavapipe, perf): allocation and object lifetimes 34% (a staging
buffer per buffer write, GPU memory blocks, reference counts), wgpu-core's pass replay, submit
and cleanup 24%, tracking and validation code 17%, extra driver calls 14%, back-end dispatch
3.7%, the C layer and locks 3.1%.

Resident memory, not yet in LCGR's favour everywhere:
- wgpu as LCGR's wgpu host creates it today (every back end) starts its GL back end too, even
  when it draws with Vulkan: +49 MB on lavapipe and +85 MB on NVIDIA over native Vulkan. A
  Vulkan-only wgpu instance is +3.3 MB at start-up and +13 MB after drawing.
- On NVIDIA, after drawing, native Vulkan is 5.8 MB larger than wgpu: its default capacities
  map 13 MB more host-visible memory. Sizing that is open work; until then, do not claim lower
  memory than wgpu on hardware.

Reproduce: `nix develop .#golden -c ci/run.sh vk-probe` (lavapipe); the NVIDIA runs are
described in docs/research/render-select.md.

## Size

| Build | Size | Commit |
|---|---|---|
| Layout only, wasm32, ReleaseSmall | 32,146 B (13,698 B gzipped); Clay 0.14 built alike 72,011 B | 0fff7c1 (C0416), dd2b77f |
| `hello.wasm`, the smallest web example | 40,450 B | 0fff7c1 |
| `scenes.wasm`, all four render conformance scenes | 69,943 B | 0fff7c1 |
| Bare-metal example, Cortex-M7, ReleaseSmall, text / data / bss | 113,126 / 60 / 663,680 B | 60a7d2d (C0500) |
| Bare-metal example, RV32IMAC, ReleaseSmall, text / data / bss | 203,432 / 60 / 663,680 B | 60a7d2d |

Clay's layout-alone wasm is built by `zig build vs-clay` (bench/vs/clay/layout.c).

Reproduce: `nix develop .#web -c ci/run.sh web-size`, `nix develop -c ci/run.sh baremetal`.

## Exactness

Not speed, but the numbers behind "every back end draws the same frame":

- Every render conformance scene matches its golden image at 0 pixels off on wgpu, Vulkan,
  GL ES 3, GL ES 2, the software renderer, WebGPU and the 2D canvas in headless Chromium 157,
  and Direct3D 12 under Wine (vkd3d on lavapipe). Metal is built but has not run on a device.
- Widget pages: 127 golden frames at 0 pixels off (`ci/run.sh widget-golden`).
- Bidirectional text: 45,832 lines of Unicode's BidiCharacterTest laid out in the file's
  visual order with its levels (7d498b9, C0850; `zig build text-conformance`).
- Accessibility: the Orca screen reader announces the example on Linux (f08db3d, C0739;
  `ci/run.sh accesskit-linux`).

## Updating this file

Re-measure on a quiet machine (load below 8), pinned, and replace a row only with a newer
measurement from the same tool. Keep rows that are not met; move a row to "met" only when the
gates run shows it.
