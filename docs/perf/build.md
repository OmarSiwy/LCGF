# Building rows (C0800)

`Tree.push` turned the style into its row column by column, interleaving the arithmetic with
stores to about 50 columns. It now builds the whole row first (`tree.Template.from`) and copies it
(`Tree.pushRow`), one store per column in column order; a caller whose style is fixed (a widget,
the comptime front end) builds the template once, even at comptime, and calls `pushRow`.

Micro-benchmark `docs/perf/build/push.zig`: the bench scene's tree (330 rows of 12 nodes, 3,961
rows) from seven runtime styles, 4,000 reps alternated; median per frame; five process runs each,
alternated, pinned to CPU 4 (P-core, i9-14900HX), load average 4.2 to 4.9 on 32 CPUs:

```
nix develop -c zig build-exe -O ReleaseFast -mcpu native --dep lcgr -Mmain=docs/perf/build/push.zig \
    --dep build_options -Mlcgr=src/lcgr.zig -Mbuild_options=docs/perf/build/opts.zig -femit-bin=zig-out/push
taskset -c 4 zig-out/push
```

| variant | medians of 5 runs (us per 3,961 nodes) | median | ns per node |
|---|---|---|---|
| before: push (030d725) | 73.4 74.0 75.9 77.4 80.0 | 75.9 | 19.2 |
| after: push (template, then copy) | 67.8 67.8 67.8 67.8 67.8 | 67.8 | 17.1 |
| after: pushRow, template once per style | 67.7 67.8 67.8 67.8 67.9 | 67.8 | 17.1 |

-11%. Building the template per node costs nothing measurable next to the copy: the time is the
stores (about 400 bytes per node into ~50 columns, 1.6 MB per frame, more than L1). A probe that
skipped six of the paint columns push writes with constants (`world`, `transform`, `clip_radii`,
`alpha`, `uv`, `radii`, 92 bytes) took the median from 76 to 67 us on its own: bytes per node, not
arithmetic, is what is left (C0804).

Census: `p_tree_push` went from 163 to 253 instructions (the template is built on the stack, then
copied), 0 jumps before and after; `p_tree_push_row` is 162 instructions, 0 jumps.

`tools/bench`'s `build` pass still times the prototype's `Tree.push` (frames are built with
prototype/ui.zig until the runtime front end has the widgets the scene uses), so it does not move:
the micro-benchmark is the measurement.
