# The bench on lcgr's front end

tools/bench now times lcgr's runtime front end end to end: `Context.begin` is begin+hit, the
scene building through `Frame` and the reference widgets (src/widgets/base.zig) is build, the
body of `Frame.end` split at each pass is layout, and `Frame.finish` is paint. Every scene of
bench/scenes/ builds against either core from one source: the build roots a second copy of the
directory with module `ui` set to tools/bench/src_ui.zig, which names lcgr's `Frame`,
`Input`, `Theme`, `Id`, `Color` and widgets. `--core=prototype` runs the old path.

What each core times:

| pass | `--core=src` (default) | `--core=prototype` |
|---|---|---|
| begin+hit | `lcgr.context.Context.begin` | prototype `Context.begin` |
| build | the scene on `lcgr.frame.Frame` and lcgr widgets | the scene on the prototype `Frame` and widgets |
| layout | `Frame.end`'s passes (`incremental.*Kept`, `flip.apply`, `finalize`) | lcgr tier-0 passes (`levels`, `coefs`) over columns copied untimed from the prototype |
| paint | `Frame.finish` (`paint.emit` plus sweeps and status) | `lcgr.paint.emit` only; the prototype's `finish` runs untimed |

First-frame draw-list check: with `--core=src` the first frame's draw list must equal the
prototype's own first frame of the same scene (prototype front end, layout and paint); with
`--core=prototype` it is the old check (lcgr paint of the copied tables against the prototype's
paint). Both hold for all seven scenes (rows, form, list, text, springs, resize, idle), and each
scene's sink (draw commands plus quads over all frames) is the same under both cores.

## Prototype against src, per pass

Alternated runs on one machine (i9-14900HX, 32 CPUs, not pinned), five rounds, each round every
scene under both cores in alternating order; the median of the five per-run medians, in
microseconds. Branch `bench-src` on 0bdea3f. Program: docs/perf/bench-src/alt.py.

```
nix develop -c zig build bench   # builds the exe; then, with its path from .zig-cache:
python3 docs/perf/bench-src/alt.py .zig-cache/o/<hash>/bench 5
```

| scene | pass | prototype us | src us | src/prototype |
|---|---|---:|---:|---:|
| rows | begin+hit | 2.0 | 1.8 | 0.90 |
| rows | build | 124.3 | 158.0 | 1.27 |
| rows | layout | 121.0 | 136.1 | 1.12 |
| rows | paint | 39.3 | 38.7 | 0.98 |
| rows | frame | 286.0 | 334.5 | 1.17 |
| form | begin+hit | 0.2 | 0.2 | 1.00 |
| form | build | 6.2 | 7.8 | 1.26 |
| form | layout | 6.1 | 6.9 | 1.13 |
| form | paint | 2.1 | 2.1 | 1.00 |
| form | frame | 14.9 | 17.1 | 1.15 |
| list | begin+hit | 0.1 | 0.1 | 1.00 |
| list | build | 5.1 | 6.5 | 1.27 |
| list | layout | 4.6 | 4.9 | 1.07 |
| list | paint | 1.7 | 1.8 | 1.06 |
| list | frame | 11.5 | 13.2 | 1.15 |
| text | begin+hit | 0.2 | 0.1 | 0.50 |
| text | build | 7.5 | 9.6 | 1.28 |
| text | layout | 6.1 | 5.9 | 0.97 |
| text | paint | 2.0 | 2.0 | 1.00 |
| text | frame | 15.8 | 17.6 | 1.11 |
| springs | begin+hit | 1.0 | 1.0 | 1.00 |
| springs | build | 155.8 | 28.3 | 0.18 |
| springs | layout | 31.4 | 30.8 | 0.98 |
| springs | paint | 11.3 | 14.9 | 1.32 |
| springs | frame | 200.2 | 74.5 | 0.37 |
| resize | begin+hit | 0.2 | 0.1 | 0.50 |
| resize | build | 7.5 | 9.6 | 1.28 |
| resize | layout | 6.1 | 5.9 | 0.97 |
| resize | paint | 2.0 | 1.9 | 0.95 |
| resize | frame | 15.8 | 17.6 | 1.11 |
| idle | begin+hit | 0.6 | 1.1 | 1.83 |
| idle | build | 11.6 | 15.7 | 1.35 |
| idle | layout | 11.9 | 14.2 | 1.19 |
| idle | paint | 3.4 | 3.6 | 1.06 |
| idle | frame | 26.8 | 34.5 | 1.29 |

Reading it:

- springs build is 5.5x faster on src: `Anims.slot` is O(1) in a steady frame (a2a356d,
  docs/perf/anim-slot/), where the prototype scans every id. This is the improvement the old
  bench could not show.
- build is about 27% slower on src in every widget scene (rows 158 against 124 us). Not
  investigated here; the per-node build cost now shows in the bench, so it is the next thing to
  look at.
- layout is 7 to 13% slower on rows, form and list: `Frame.end` runs the `*Kept` forms of the
  passes (memo-aware, `incremental.zig`), where the prototype path called `levels` and
  `coefs` directly; the difference is not split further here.
- idle builds two cold frames, so its row is noise.

tools/bench/baseline.json is re-recorded from `--core=src` (rows: frame 340.2 us median, against
334.5 in the table above).
