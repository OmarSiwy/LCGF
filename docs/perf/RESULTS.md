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
(bench/vs/, docs/perf/vs.md for what a frame is in each). LCGR at main 3d4f32a (perf-gaps
branch merged); the other libraries at the versions in docs/perf/vs.md. Quiet run: load 4 to 6,
pinned, `measure.py --runs 3`.

| Scene | LCGR | Fastest other | Ratio | Gate |
|---|---|---|---|---|
| form, per poll | 0.1 us | LVGL 9.6.0, 1.6 us | 0.06x | met |
| text, per poll | 0.1 us | LVGL 9.6.0, 1.0 us | 0.10x | met |
| resize, per frame | 17.6 us | Clay 0.14, 29.4 us | 0.60x (0.57x in the gates run) | met |
| list, per frame | 12.2 us | Dear ImGui 1.93.0, 11.9 us | 1.03x | not met (within run-to-run spread) |
| springs, per frame | 75.4 us | Dear ImGui 1.93.0, 57.0 us | 1.32x | not met |
| Resident memory after one idle frame | 1,624 KiB | Clay, 2,076 KiB | 0.78x | met |
| Time to first frame | 0.47 ms | Clay, 0.45 ms | 1.04x | not met |
| Idle wake-ups per second | 0 | Clay, ImGui, egui, Iced, Slint, Qt Quick: 0 (LVGL 30) | | met |

form and text are timed per poll in every harness: each library decides for itself whether a
poll needs work. In these two scenes only the pointer moves; LVGL redraws nothing it does not
need to, and LCGR since 63e0c92 builds no frame for a pointer move over nodes that sense
nothing (908 of 3,000 polls built in form, 2 of 3,000 in text). list, springs and resize build
every frame in every harness.

The resize row is from the gates run of docs/perf/vs.md (load 3 to 5); the other rows from the
quiet run above.

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

Resident memory after the render-select fixes (commits e524dbb, 97974a9): the wgpu host's
instance is Vulkan-only (Metal on Apple), and the Vulkan back end's default ring is sized to a
frame of the default `Limits` (4096 quads, 16K glyphs: 5.6 MB host-visible instead of 13 MB).
`tools/bench/probe.py`, ReleaseFast, golden shell, one batch, MB = 1000 KiB; device only /
empty 800x600 frame / after the scenes drawn 2000 times:

| Driver | Vulkan, before | Vulkan, after | wgpu, before | wgpu, after |
|---|---|---|---|---|
| lavapipe (Mesa 26.3.0) | 74.0 / 79.3 / 98.8 | 74.0 / 79.3 / 98.8 | 122.2 / 128.0 / 154.1 | 76.6 / 85.3 / 111.5 |
| NVIDIA RTX 4060, 595.71.05 | 69.3 / 84.5 / 84.4 | 69.3 / 76.8 / 76.8 | 154.1 / 155.6 / 156.4 | 73.0 / 77.2 / 77.9 |

- The Vulkan-only instance takes 46 MB off wgpu at start-up on lavapipe and 81 MB on NVIDIA:
  its GL back end no longer loads an EGL driver it never uses. CPU per frame did not change
  (five runs each, load 3.7: lavapipe 23.0-24.6 against 21.9-24.8 us, NVIDIA 14.7-29.1 against
  14.8-21.4 us).
- On NVIDIA, native Vulkan is now 0.4 MB smaller than wgpu at an empty frame and 1.1 MB after
  drawing; before the ring was sized it was 7 MB larger. The margin is small: the NVIDIA
  driver's own share moved by up to 2 MB between batches of the same binary, and by 11 MB
  between batches hours apart, so compare within a batch. On lavapipe the ring's untouched
  pages were never resident, so nothing changed there; Vulkan stays 12.7 MB under wgpu after
  drawing (wgpu's GPU memory blocks are host memory on lavapipe).
- The CPU column above was not re-timed after these commits: the machine stayed above load 8
  (other builds), where timing is unreliable. Neither commit touches the per-frame CPU path
  except wgpu's instance, timed above.

Reproduce: `nix develop .#golden -c ci/run.sh vk-probe` (lavapipe); the NVIDIA runs are
described in docs/research/render-select.md.

## Size

| Build | Size | Commit |
|---|---|---|
| Layout only, wasm32, ReleaseSmall | 31,509 B (13,422 B gzipped) | 0fff7c1 (C0416) |
| `hello.wasm`, the smallest web example | 40,450 B | 0fff7c1 |
| `scenes.wasm`, all four render conformance scenes | 69,943 B | 0fff7c1 |
| Bare-metal example, Cortex-M7, ReleaseSmall, text / data / bss | 113,126 / 60 / 663,680 B | 60a7d2d (C0500) |
| Bare-metal example, RV32IMAC, ReleaseSmall, text / data / bss | 203,432 / 60 / 663,680 B | 60a7d2d |

For the wasm layout size, Clay states 15 kB for its own; Clay's wasm was not built here.

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
