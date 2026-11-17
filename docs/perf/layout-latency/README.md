# Layout latency micro-benchmarks

The throwaway programs behind the numbers in commits C0119 to C0122 and C0849 (lane
layout-latency), kept so the numbers can be reproduced. micro.zig to micro3.zig were first measured
on Zig 0.17.1, micro4.zig on Zig 0.18.0-dev.1151; all on a loaded machine.

| File | Measured |
|---|---|
| `micro.zig` | resolve and place, prototype form against the K-coefficient form (C0118, C0119) |
| `micro2.zig` | level-order storage: one resolve sweep 33.8 -> 10.5 us, but building the order 13.5 us and copying rows 27.1 us per frame (C0121) |
| `micro3.zig` | prefetch of parent rows at distances 8, 16, 32: resolveK 18.0 -> 19.3 us, placeK 17.8 -> 20.5 us, slower (C0122, not adopted). Re-measured on Zig 0.18.0-dev.1151, min of three runs: resolveK 22.5 -> 23.7 us, placeK 17.3 -> 19.4 us at every distance, still slower |
| `micro4.zig` | resolve (both axes) + place against the lane's start (src/ at 99d3b1e^): start 138.7, coefs 108.3, levels 89.2 us min, 1.56x (C0849) |

Build one from the repository root, pinned to one core:

```
nix develop -c zig build-exe -O ReleaseFast -mcpu native --dep lcgf -Mmain=docs/perf/layout-latency/micro.zig \
    --dep build_options -Mlcgf=src/lcgf.zig -Mbuild_options=docs/perf/layout-latency/opts.zig -femit-bin=zig-out/micro
taskset -c 4 zig-out/micro
```

micro4.zig also needs the lane's start as module `lcgf_old`: `git archive 99d3b1e^ src | tar -x -C
OLD`, `sed -i 's/packed struct/bitpack struct/' OLD/src/core/*.zig` (the only change Zig 0.18
needs there), and a root `OLD/src/old_root.zig` exporting `mem`, `tree` and `layout`; then add
`--dep lcgf_old` to main and `--dep build_options -Mlcgf_old=OLD/src/old_root.zig` to the command.

`micro.tpl` is the template `micro.zig` was generated from. C0122 recorded the prefetch result
and kept no prefetch: it is slower at every distance on both Zig versions.
