# Why src was slower than the prototype, per pass

docs/perf/bench-src.md found lcgr's runtime front end 17% slower per frame than the prototype
path on the rows scene (334.5 against 286.0 us). This note gives the cause of each pass's gap,
what was fixed, and what is left with its cost measured.

Method: `bench --counters` (cycles and instructions per pass), `perf record -e instructions:u`
per symbol on both cores, and probe binaries that remove one suspect at a time. Numbers are
docs/perf/bench-src/alt.py, five alternated rounds, i9-14900HX, 32 CPUs, load 2.3 to 2.8,
median of the per-run medians, in us. Before = 9b7071d, after = this commit.

## Layout: fixed

The prototype path's layout is not the prototype's own: it times lcgr's fastest tier-0 passes,
`levels.build` + `levels.resolve` (level-order SIMD resolve, C0849) and `coefs.placeRows` +
`coefs.placeK`. `Frame.end` ran the incremental `*Kept` forms, whose resolve is the row-by-row
`layout.resolveSpan` even when nothing is kept. Pass by pass on rows (single pinned runs):

| sub-pass | prototype path | src before | src after |
|---|---:|---:|---:|
| resolve.x (prototype path: includes `levels.build`) | 27.3 | 28.8 | 26.7 |
| resolve.y | 17.5 | 28.6 | 17.3 |
| place | 20.8 | 22.6 | 22.6 |

Fix: `Context.levels` (a `levels.Levels`, 16 bytes per node of capacity: 874 -> 890, the test in
context.zig) and `Frame.end` builds it and resolves by level when `kept` is empty, the usual
frame; with kept subtrees it keeps `incremental.resolveKept`. One branch per frame
(`frame.resolve`). Sizes are the same bit for bit (levels.zig's test against `coefs.resolveK`,
and the bench's first-frame draw-list check against the prototype, still passing for all seven
scenes). src/devtools/timing.zig and tools/bench mirror `Frame.end` and changed with it.

Not adopted: `coefs.placeRows` + `placeK` for place, measured 22.6 -> 20.6 us on rows (pinned,
five alternated runs, noisy), for a 48-byte `Place` row per node (+5% bytes per node). Layout is
already at the prototype path's time without it.

## Build: the cost of the paint columns the prototype lacks

`--counters`, rows build per frame: prototype 1.18 M instructions, 471 k cycles; src 1.49 M,
597 k; IPC the same (2.5), L1D misses ~100 for both. Per symbol (`perf record -e
instructions:u`), the only build function that grew is `Tree.push` (+43%); the widgets,
`textStyled` and the scene functions match the prototype's.

`push` writes eight columns the prototype has not got: `border`, `uv`, `radii`, `opacity`,
`alpha`, `transform`, `world`, `clip_radii` (108 bytes per node; per-corner radii, opacity,
transforms and rounded clips, added after the port; docs/perf/bytes.md). Probe: the same binary
with `pushRow` skipping those eight columns (draw-list check off, since paint then reads stale
rows), three alternated rounds:

| scene | prototype | src | src, probe |
|---|---:|---:|---:|
| rows | 126.9 | 158.0 | 131.1 |
| form | 5.9 | 7.8 | 6.5 |
| list | 4.9 | 6.1 | 5.2 |
| text | 7.5 | 9.8 | 8.7 |

The columns are about 27 of rows' 34 us; what is left is under 4%. `push` is store-bound, not
instruction-bound: `noalias` on its style pointer, which removes the template's stack spills,
left docs/perf/build/push.zig at 68.2 us both ways. The extra stores are features, so they stay;
cutting them means changing which columns paint reads (alpha, world and clip_radii are defaults
that `draw.inherit` overwrites), which belongs to the draw lanes.

## Paint: bookkeeping the prototype path does untimed

src's paint is `Frame.finish`: `paint.emit` plus the anim, tween and timer sweeps and status.
The prototype path times `paint.emit` alone and runs its own `finish`, with the same
`Anims.sweep`, untimed. On springs (1,000 springs) a probe without the sweeps took src paint from
14.9 to 12.6 us (prototype path 11.3); on the other scenes paint is equal. Not a regression.

## Before and after

| scene | pass | prototype | src before | src after |
|---|---|---:|---:|---:|
| rows | build | 123.9 / 128.1 | 158.0 | 163.1 |
| rows | layout | 121.0 / 123.8 | 136.5 | 123.6 |
| rows | paint | 38.7 / 40.6 | 39.9 | 40.3 |
| rows | frame | 286.3 / 294.3 | 335.1 | 327.3 |
| form | layout | 6.0 / 6.0 | 6.9 | 6.1 |
| list | layout | 4.6 / 4.6 | 4.8 | 4.7 |
| text | layout | 6.1 / 6.1 | 5.9 | 6.2 |
| springs | layout | 31.2 / 31.3 | 30.8 | 31.8 |
| idle | layout | 12.0 / 11.7 | 13.9 | 11.6 |

(prototype: in the before run / in the after run.) src/prototype for layout went from 1.13 to
1.00 on rows and 1.15 to 1.02 on form. Build moves only with noise (+5 us on rows between these
two runs, inside the run-to-run spread of the probe table).
