# Spring slot lookup

The program behind the numbers in commit a2a356d ("Make Anims.slot O(1) in a steady frame"), kept
so they can be reproduced. `zig build bench -- --scene springs` cannot measure this: tools/bench
builds its frames with `prototype/ui.zig`. `springs.zig` runs the same scene
(bench/scenes/springs.zig: a 40 x 25 grid of bars, 1,000 `Frame.animate` calls per frame,
targets flipping every 30 frames, 3,000 frames) on lcgf's `Context` and prints the median and p99
of the build only (`begin` to the last `close`; layout and paint are not timed).

| Build | Median build, three alternated runs | p99 |
|---|---|---|
| before (3001d5a: `slot` scans every id with `simd.find`) | 155.6, 156.6, 156.6 us | 161.1 to 161.6 us |
| after (a2a356d: `slot` tries the row after the last one first) | 28.7, 27.8, 28.1 us | 30.6 to 31.6 us |

Zig 0.18.0-dev.1151, ReleaseFast, `-mcpu native` (8 lanes), pinned to one core, Nov 2026.

Build and run from the repository root:

```
nix develop -c zig build-exe -O ReleaseFast -mcpu native --dep lcgf -Mmain=docs/perf/anim-slot/springs.zig \
    --dep build_options -Mlcgf=src/lcgf.zig -Mbuild_options=docs/perf/anim-slot/opts.zig -femit-bin=zig-out/springs
taskset -c 4 zig-out/springs
```

For "before", extract the old tree (`git archive 3001d5a src | tar -x -C OLD`) and pass
`-Mlcgf=OLD/src/lcgf.zig` instead; nothing else changes.

## Tweens

`transitions.zig` is the same harness for `Tweens.slot`: 250 colour swatches, each a
`Frame.transition` (four tweens: 1,000 `Tweens.slot` calls per frame), target colours flipping
every 30 frames, 3,000 frames. The sink (a sum of every colour shown) is the same before and
after, so the results are unchanged.

| Build | Median build, three alternated runs | p99 |
|---|---|---|
| before (26b0826: `Tweens.slot` scans every id) | 152.7, 152.0, 152.7 us | 157.1 to 233.3 us |
| after (the commit that adds this section: tries the row after the last one first) | 13.7, 12.3, 12.4 us | 15.3 to 20.6 us |

Build it as above with `-Mmain=docs/perf/anim-slot/transitions.zig`; for "before", extract
26b0826's `src` the same way.
