# Dependency chains of the scalar sweeps (C0805)

docs/perf/cache.md showed the passes are latency- and instruction-bound, not miss-bound. Each
sweep that cannot be SIMD (a row needs its parent's or a sibling's result) runs at the speed of
its loop-carried chain: the instructions from one row's load of a carried value to the store the
next row loads. Every scalar sweep the frame runs, its chain, and what was done:

| sweep | carried value | chain before | change | result |
|---|---|---|---|---|
| `layout.finalize` | `child_clip[parent]` -> `child_clip[i]` | root select, max, NaN fix-up, select | root row seeded, clip/no-clip select moved to the other operand: one max | 38.1 -> 16.0 us |
| `layout.fit` (fold into parent) | `fit[p]` across siblings | max + NaN fix-up, sub, mul, add | sum and max side by side, `<` + select (one maxss), select by direction | 21.8 -> 16.9 us (x), 21.6 -> 16.6 (y) |
| `inherit.transform` | `world[parent]` | root select, compose | root row seeded with the identity | 15.09 -> 13.00 us |
| `inherit.clip` | `clip_radii[parent]` | root select, select | root row seeded square | 6.45 -> 5.54 us |
| `inherit.opacity` | `alpha[parent]` | select, mul | seeding the root measured slower (3.0 -> 3.5 us), kept | 3.22 us |
| `levels.resolve`, `used[p] +=` | `used[p]` across sibling lanes | load, add, store per lane | tried: gather once, segmented scan in registers, scatter | no gain (27.7 -> 28.5 us) and not bit-exact with `coefs.resolveK` (its test fails): not adopted |
| `coefs.placeK` | `cursor[p]` across siblings | load, add, store | tried: select by direction for `in_flow` (off the chain) | 21.1 -> 20.9 us, noise: not adopted |
| `paint.encode` | open command's `first`, `count` | reloaded from the row just stored | tried: kept in registers | 38.8 -> 38.7 us, noise: not adopted |
| paint sweep 1 | write indices `q`, `o` | one add each | none needed | |
| `layout.applyText`, `wrap`, `textAvail` | none (scatters, no carried value) | | none | |

The rule the changes share: a root that is its own parent reads its own row before writing it,
so seeding that row with "what the parent of the root would give" deletes the per-row `i == 0`
select from the chain (and, written unconditionally, adds no jump: row 0 exists at any capacity).
And a select whose other operand is computed off the chain costs one blend on it, where the
coefficient form (`a + k * (b - a)`) costs three dependent operations.

## Numbers

`zig build bench` (rows scene, 3,961 nodes), the C0804 binary (2390d17) and this one alternated,
five runs each, pinned to CPU 2 (P-core, i9-14900HX), load average 3.6 to 4.7 on 32 CPUs, medians:

| pass | before runs | median | after runs | median |
|---|---|---|---|---|
| fit.x | 21.7 21.7 21.8 21.9 22.1 | 21.8 | 16.8 16.8 16.9 16.9 16.9 | 16.9 (-22%) |
| fit.y | 21.6 21.6 21.6 21.7 21.8 | 21.6 | 16.6 16.6 16.6 16.6 16.7 | 16.6 (-23%) |
| finalize | 38.1 38.1 38.1 38.1 38.2 | 38.1 | 16.0 16.0 16.0 16.1 16.4 | 16.0 (-58%) |
| layout | 158.5 158.7 158.8 158.9 159.6 | 158.8 | 120.0 120.2 120.4 122.8 124.4 | 120.4 (-24%) |
| frame | 355.5 356.1 357.7 359.0 361.0 | 357.7 | 285.6 286.5 286.6 289.0 292.5 | 286.6 (-20%) |

(The after binary also carried the `paint.encode` variant, dropped afterwards: paint 38.8 -> 38.7.)

The inherit sweeps are not in the bench; `docs/perf/chains/inherit.zig` times them on the bench's
tree shape with clipping, translucent and transformed nodes, the HEAD tree against this one, five
alternated runs, medians of 4,000 reps:

| sweep | before runs (us) | median | after runs (us) | median |
|---|---|---|---|---|
| opacity | 2.99 3.00 3.22 3.22 3.31 | 3.22 | 3.21 3.22 3.22 3.23 3.23 | 3.22 (unchanged code) |
| transform | 14.79 14.81 15.09 15.11 15.11 | 15.09 | 12.99 13.00 13.00 13.01 13.03 | 13.00 (-14%) |
| clip | 5.91 5.97 6.45 6.48 6.52 | 6.45 | 5.42 5.45 5.54 5.54 5.65 | 5.54 (-14%) |

Census (`ci/run.sh census-src`): every pass within bench/census/baseline-src.json; `p_fit` 4 jcc,
`p_finalize` 3, `p_inherit_transform` and `p_inherit_clip` 2, as before. The bench's differential
check (src paint against the prototype's draw list) passes, so the layout results are unchanged.
