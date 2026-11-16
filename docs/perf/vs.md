# LCGR beside other GUI libraries

The six scenes of `bench/scenes/` (form, list, text, springs, resize, idle) ported to each framework
under `bench/vs/<name>/`, and measured with the same probes: frame time over 3,000 frames,
resident memory and idle wake-ups from `tools/bench/probe.py`, and loaded bytes (text + rodata +
data) from `tools/bench/size.zig`. `bench/vs/measure.py` runs it all; `ci/jobs/vs-<name>.sh` runs it
for one framework beside the LCGR row (`nix develop -c ci/run.sh vs-clay`). No job is in `all`.

Every number here is from one machine (32 CPUs, Linux, no GPU used) and the medians of 5 runs; the
1-minute load average during the run is given with each table. Timings never compare across
machines, and differ by tens of percent between runs on a machine shared with other builds.

## What a frame is in each harness

| Row | Frame timed | Text | Notes |
|---|---|---|---|
| LCGR | `tools/bench/bench.zig`: begin + hit test, build, layout, paint into the draw list | monospace measure (0.6 em per byte), text runs are not split into glyphs | the reference row |
| Clay 0.14 | `Clay_BeginLayout`, declarations, `Clay_EndLayout` (layout and render commands) | the same monospace measure, word wrap by Clay | Clay has no widgets or animation: they are built from elements, springs are the prototype's step |
| Dear ImGui 1.93.0 | input, `NewFrame`, ImGui's own widgets, `Render` (vertex and index buffers), null back end | default font (ProggyClean) at 14 and 20 px, every glyph laid out into vertices | springs are the prototype's step (no animation API) |

None of these rows rasterises. Draw output per frame differs in kind (LCGR quads and text runs, Clay
render commands, ImGui vertices), so the `out=` counts in the harness output are not comparable
across rows.

## Frame time (median / p99, microseconds)

Each column was measured in its own `ci/run.sh vs-<name>` run, beside an LCGR row of that run;
the LCGR column here is from the Clay run (load 3.2 to 4.2 on 32 CPUs). LCGR in the ImGui run
(load 4.5 to 5.0): form 14.8, list 11.2, text 16.4, springs 201.2, resize 16.4 (medians).

| Scene | LCGR | Clay | Dear ImGui |
|---|---|---|---|
| form | 16.7 / 19.6 | 28.0 / 39.3 | 15.8 / 23.2 |
| list | 12.3 / 15.0 | 21.7 / 27.0 | 11.1 / 19.5 |
| text | 17.6 / 20.2 | 29.8 / 33.1 | 89.9 / 164.4 |
| springs | 219.8 / 226.5 | 112.3 / 161.4 | 52.8 / 90.4 |
| resize | 17.6 / 26.1 | 29.4 / 36.7 | 92.9 / 151.8 |
| idle: frames built of 3,000 polls | 2 | 3,000 | 3,000 |

## Memory, idle and size

| | LCGR | Clay | Dear ImGui |
|---|---|---|---|
| Resident after one idle frame | 8,048 KiB | 2,096 KiB | 3,844 KiB |
| Idle wake-ups per second | 0 | 0 | 0 |
| Loaded bytes (ReleaseSmall) + bss | 220,643 + 7,557,108 | 99,105 + 101,392 | 757,100 + 61,448 |

## What these numbers do and do not say

- The LCGR row is the benchmark tool itself: it carries two cores (the prototype builds the frame,
  the ported `src/` core lays it out and paints) and a static buffer for each, sized for 4,096 nodes.
  Its resident memory, bss and binary size are therefore upper bounds for LCGR, not its footprint;
  a real example program replaces them when one exists.
- Idle wake-ups: LCGR, Clay and Dear ImGui have no event loop of their own, so their harnesses
  block on stdin after the first frame, and zero is what any host that sleeps on input gets. The
  row that says something is "frames built": LCGR's `Context.needsFrame` skips all but two of the
  3,000 unchanged polls; Clay and ImGui have no such query (ImGui leaves idling to the application),
  so the host must detect "nothing changed" itself or build every poll.
- Springs: Clay has no animation; the harness steps the 1,000 springs in plain C (as
  `bench/vs/harness.h` does for every framework without one), while LCGR's time includes its
  animation table (`Frame.animate`: a slot lookup per call and the stepped spring columns).
- Text: Clay word-wraps and caches word widths across frames; LCGR's monospace wrap is arithmetic.
  Neither shapes text or emits glyph quads. ImGui lays out real glyph advances and writes four
  vertices per glyph (12,984 vertices in the text scene), work LCGR leaves to its renderer: that is
  most of ImGui's text and resize time.
- Form: ImGui's text fields are `InputText` widgets; LCGR's form scene draws a bordered box with a
  label (no editing state), so ImGui does a little more there.
- Clay culls render commands outside the window (73 of the text scene's elements); LCGR paints
  every node in the tree.
