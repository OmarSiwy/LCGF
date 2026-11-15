# Layout latency micro-benchmarks

The throwaway programs behind the numbers in commits C0119 to C0121 and the unfinished C0122
(lane layout-latency), kept so the numbers can be reproduced. They were measured on Zig 0.17.1 on
a loaded machine; re-measure on the current Zig before building on them.

| File | Measured |
|---|---|
| `micro.zig` | resolve and place, prototype form against the K-coefficient form (C0118, C0119) |
| `micro2.zig` | level-order storage: one resolve sweep 33.8 -> 10.5 us, but building the order 13.5 us and copying rows 27.1 us per frame (C0121) |
| `micro3.zig` | prefetch of parent rows at distances 8, 16, 32: resolveK 18.0 -> 19.3 us, placeK 17.8 -> 20.5 us, slower (C0122, not adopted). Re-measured on Zig 0.18.0-dev.1151, min of three runs: resolveK 22.5 -> 23.7 us, placeK 17.3 -> 19.4 us at every distance, still slower |

Build one from the repository root, pinned to one core:

```
nix develop -c zig build-exe -O ReleaseFast -mcpu native --dep lcgr -Mmain=docs/perf/layout-latency/micro.zig \
    --dep build_options -Mlcgr=src/lcgr.zig -Mbuild_options=docs/perf/layout-latency/opts.zig -femit-bin=zig-out/micro
taskset -c 4 zig-out/micro
```

`micro.tpl` is the template `micro.zig` was generated from. C0122 recorded the prefetch result
and kept no prefetch: it is slower at every distance on both Zig versions.
