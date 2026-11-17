# LCGF performance results

The measured numbers, in one place, with the conditions they were taken under and the commit
that produced each one. Every number here comes from a tool in docs/CHECKS.md and can be
reproduced with the command given under it. Where LCGF is not the fastest, this file says so.

Machine for every number below unless a section says otherwise: Intel Core i9-14900HX
(32 hardware threads), 31 GiB RAM, Linux 7.0.10, Zig 0.18.0-dev.1151+8dfb7a7cc, ReleaseFast,
benchmark pinned to one CPU. Timings are medians. "Load" is the 1-minute load average during
the run; above about 8 (a quarter of the CPUs) timings on this machine inflate by up to 40%.

## Hosted release comparison, 2026-11-17

On GitHub's Linux runner, the eight-framework benchmark at `d9013ce` put LCGF
ahead on the form, text and resize scenes and on resident memory. Three targets
still missed. The CI job passed its regression checks. Each target below compares
the two frameworks in the same run. [Full comparison log](https://github.com/OmarSiwy/LCGF/actions/runs/44192098538/job/134423947139)

| Measurement | LCGF | Fastest or smallest other framework | Target |
|---|---:|---:|---|
| List frame | 15.6 µs | Dear ImGui, 15.4 µs | Open |
| Springs frame | 99.0 µs | Dear ImGui, 75.3 µs | Open |
| First frame | 0.49 ms | Clay, 0.48 ms | Open |
| Idle resident memory | 396 KiB | Clay, 416 KiB | Met |

The November 16 owner-machine run below remains the recorded regression baseline.
The release plan requires pushed, verified tags for the two early milestones and
three months of passing gate evidence for 1.0. [Milestone criteria](../../plan/plan.json)

## Against other GUI libraries

The same five scenes built in eight libraries, each through its own API, on the CPU, no window
(bench/vs/, docs/perf/vs.md for what a frame is in each). LCGF at perf-gaps dd2b77f; the other
libraries at the versions in docs/perf/vs.md. One `ci/run.sh gates-vs` run, every harness pinned
to the same CPU, medians of 5 runs (first frame: 11 starts), load 3.0 to 5.2. These are the
values in bench/gates/recorded.json.

| Row | LCGF | Best other | Ratio | Gate |
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

Against Clay, LCGF is faster on every frame row and smaller in bytes and wasm; resident memory
and first frame are within 4% of Clay's, on Clay's side. How each row is made fair:

- The LCGF row is `bench/vs/lcgf/main.zig`: harness.h's driver over LCGF's frame and nothing
  else, a static binary without libc (until d94b562 it was the per-pass benchmark, carrying the
  prototype core: 280 KB loaded and 11.8 MB bss).
- Every harness sizes its tables for the scene (harness.h `vs_capacity`), Clay through
  `Clay_SetMaxElementCount`.
- Clay's resident memory and first frame are measured on a static musl build, so neither row
  pays for a dynamic C library (with glibc Clay is 2,000 KiB and 0.45 ms); its frames stay on
  glibc, its fastest, and its size on the dynamic build, its smallest.
- The wasm row builds Clay's layout of the same three-box frame the same way as LCGF's
  (bench/vs/clay/layout.c; `zig build vs-clay`). Clay's README states 15 kB; 0.14 builds to
  72,011 B here, 76,530 B with its whole API exported as its website builds it.

What is left against Clay is LCGF's working set: after one frame of the 200-node form at
capacity 256 it touches about one page per column of the current tree, the shared layout
scratch and the second generation's default extras row, plus the draw list (136 bytes a quad)
and text rows. Clay's single arena touches about 136 KB, LCGF's columns about 200 KB; LCGF's
code pages are fewer (128 against 204 KB). Closing it needs fewer bytes per node or one tree
generation, a tree and layout change.

form and text are timed per poll in every harness: each library decides for itself whether a
poll needs work. In these two scenes only the pointer moves; LVGL redraws nothing it does not
need to, and LCGF since 63e0c92 builds no frame for a pointer move over nodes that sense
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
| LCGF row against Clay: resident, first frame, size | 1,624 KiB, 0.47 ms, 280,235 + 11.8 MB bss | 436 KiB, 0.32 ms, 59,755 + 34,176 B (Clay static 420 KiB, 0.31 ms; Clay 99,198 + 101,296 B) | d94b562: the LCGF row does only what Clay's harness does; capacities per scene and a static Clay for both sides |

Springs is the gap left: its profile is flat (Tree.push 26%, paint 16%, the scene's animation
15%, level resolve 13%); ImGui places each bar in one pass, LCGF runs its full flex layout over
every node. docs/perf/vs.md has the breakdown.

## GPU back end: native Vulkan against wgpu-native

The Vulkan back end (src/render/vk) and the wgpu back end over wgpu-native v29, the same scenes,
ReleaseFast, offscreen targets. Source: docs/research/render-select.md (commit 13061c1), which
re-measured C0389's numbers and corrected two of them.

CPU time per frame (medians):

| Driver | LCGF Vulkan | wgpu-native | Ratio |
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
