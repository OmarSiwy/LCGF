# Why src was slower than the prototype, per pass

docs/perf/bench-src.md found lcgf's runtime front end 17% slower per frame than the prototype
path on the rows scene (334.5 against 286.0 us). This note gives the cause of each pass's gap,
what was fixed, and what is left with its cost measured.

Method: `bench --counters` (cycles and instructions per pass), `perf record -e instructions:u`
per symbol on both cores, and probe binaries that remove one suspect at a time. Numbers are
docs/perf/bench-src/alt.py, five alternated rounds, i9-14900HX, 32 CPUs, load 2.3 to 2.8,
median of the per-run medians, in us. Before = 9b7071d, after = this commit.

## Layout: fixed

The prototype path's layout is not the prototype's own: it times lcgf's fastest tier-0 passes,
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
scenes). src/devtools/timing.zig and bench/micro mirror `Frame.end` and changed with it.

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

## Build, second step: the paint extras as a side table

The eight paint columns above (108 bytes per node, mostly defaults) are gone from `Tree.Columns`.
In their place:

- `Tree.Extras`, a side table on the tree: one row per node whose style has a non-default
  `border`, `uv`, `radii`, `opacity` or `transform`, or `clip` (a clipping node's rounded clip
  is its own), appended by `push` in node order. Row 0 holds the defaults. Its columns: the
  node, the five style extras, and `alpha`, `world`, `clip_radii`, which `draw.inherit` writes.
- Two u32 link columns: `extra` (the node's own row, or 0) and `scope` (the row whose inherited
  opacity and transform the node takes: its own, else its parent's `scope`). A node without a
  row inherits exactly its scope row's values: opacity 1 and the identity transform change
  nothing, and only a clipping node changes the clip it hands down.
- `draw.inherit` sweeps the extras rows only, and `paint.emit` (and `emitLayered`) runs it
  first, so every paint is after inherit. Readers: paint, `layout.finalize` (border),
  `damage.hashNodes`, devtools `quadsOf`; `Frame.reuse` copies a subtree's extras rows and
  rebases both links (a scope that pointed outside the copy becomes the new parent's).

`push` computes whether the style has an extra with one 4-lane mask and one reduce (a 6-lane
compare of the transform lowered to a lane-by-lane extract, 25 instructions), then writes the row
behind one branch, taken by the few nodes that have one. With `noalias` on the style the loads of
the extras move inside that branch. Measured (rows build, pinned, three alternated runs each, us):

| variant | build |
|---|---:|
| before (eight columns per node) | 160-163 |
| side table, every node's extras written to a spare row, no branch | 165-167 |
| the same, folded mask, `noalias` | 156-158 |
| side table, extras behind one branch, `noalias` (adopted) | 147-150 |
| that, plus `Frame.open`/`leaf` inlined (styles fold at the call site; not adopted: code size at every call site) | 139-142 |
| probe: no extras at all (lower bound) | 131-134 |

The branch is the census change in `p_tree_push`/`p_tree_push_row` (jcc 0 -> 1). The rest of
the census changes are loops: `p_paint`/`p_paint_layered` inline the three inherit sweeps (jcc
8 -> 14, back 4 -> 6, one loop guard), `p_inherit_opacity`'s loop unrolls differently (one
remainder test), `p_reuse` copies and rebases the extras rows (jcc 39 -> 49). No new jump tests a
column value.

Bytes per node of capacity (the context.zig pin): 890 -> 914. Each tree generation is 276 bytes
a row (376 - 108 + 8) plus a 112-byte extras row per node of capacity; the extras table is sized
for every node to have a row, so it saves nothing yet. A smaller limit on extras rows (most
frames use a few) would make it a saving; that needs an overflow report, not done here.

Results are the same: the bench's first-frame draw list equals the prototype's in all seven
scenes; `ci/run.sh all` (sw-golden included) and the golden, widget-golden, draw-golden,
conformance, wgpu and vk jobs pass at 0 px. One behaviour change: `Frame.end`'s paint now runs
`inherit`, so nested opacity, transforms and rounded clips apply in the runtime front end, where
before only a caller who ran `inherit` by hand got them; no golden scene depended on the old way.

Alternated, pinned to CPU 12, five rounds, program docs/perf/bench-src/alt2.py, before =
f03e7cf, after = this commit. The machine was loaded (load average 10 on 32 CPUs, every number
about 40% above the quiet runs above), so read the ratios:

| scene | pass | prototype | src before | src after | after/prototype |
|---|---|---:|---:|---:|---:|
| rows | build | 175.8 | 237.1 | 204.2 | 1.16 |
| rows | paint | 53.7 | 55.2 | 55.1 | 1.03 |
| rows | frame | 396.9 | 467.9 | 433.0 | 1.09 |
| form | build | 8.3 | 10.9 | 9.6 | 1.16 |
| form | paint | 2.8 | 2.8 | 3.0 | 1.05 |
| list | build | 6.5 | 8.3 | 7.8 | 1.19 |
| list | paint | 2.2 | 2.2 | 2.1 | 0.93 |
| text | build | 10.2 | 13.4 | 12.2 | 1.20 |
| text | paint | 2.8 | 2.8 | 2.8 | 1.02 |
| springs | paint | 15.3 | 18.5 | 17.6 | 1.15 |

Rows build went from 1.35 to 1.16 times the prototype's. What is left: the two link columns and
the extras test (about 30 instructions a node next to the no-extras probe), and the template
`push` builds on the stack (`p_tree_push` 276 instructions against the prototype's ~200).
Inlining `push` into `Frame.open` folds the test away for literal styles (another ~8 us on rows)
at the cost of code at every call site.
