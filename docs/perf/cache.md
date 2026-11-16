# Cache misses per pass (C0799)

Hardware counters per pass of `tools/bench`, user space only, means per built frame:

```
nix develop .#bench -c ci/run.sh perf-cache        # every scene, plus perf stat per run
taskset -c 2 zig build bench -- --counters [--scene NAME]
```

`--counters` opens one perf_event_open group (cycles, instructions, L1D read misses, last-level
read misses) and reads it at every timestamp the frame loop already takes. Each read is a syscall:
its kernel half is not counted, but it evicts a few L1 lines, so a short pass carries a few dozen
extra misses (measure: 88 misses for 2,487 instructions). `perf stat` over the same run is the
cross-check that the events count on this core (`ci/jobs/perf-cache.sh`).

Machine: Intel i9-14900HX (hybrid; pinned to CPU 2, a P-core: 48 KB L1D, 2 MB L2, 36 MB L3),
Zig 0.18.0-dev.1151, ReleaseFast, 8 lanes. Load average 2.5 to 4.5 on 32 CPUs. One run per scene;
two runs of `rows` agreed within 2% on cycles and instructions (L1D misses: 30.9k and 20.3k per
frame, the syscall share moves).

## rows (3,961 nodes, 1,320 text runs)

```
counters       cycles      insns   L1D miss   LLC miss        IPC   L1D/node
begin+hit        6827      24797        154          0       3.63       0.04
build          473314    1180510         63          0       2.49       0.02
layout         572147    1177693      15071          0       2.06       3.80
paint          189100     462136       5047          0       2.44       1.27
frame         1241388    2845137      20336          1       2.29       5.13
measure          1013       2487         88          0       2.46       0.02
prepare         13049       7029         96          0       0.54       0.02
fit.x           78669     139272        679          0       1.77       0.17
resolve.x      103447     242745       4803          0       2.35       1.21
wrap             5430      13961        546          0       2.57       0.14
fit.y           78120     139272        276          0       1.78       0.07
resolve.y       67034     158720       4695          0       2.37       1.19
place           78940     254661       3539          0       3.23       0.89
finalize       146444     219546        351          0       1.50       0.09
```

perf stat, whole run (3,000 frames plus the untimed copies, flex and incremental runs): 13.2 G
cycles, 31.0 G instructions, 196 M L1D misses, 26 k LLC misses.

## Other scenes (frame totals per built frame)

| scene | nodes | cycles | insns | IPC | L1D miss | L1D/node | LLC miss | largest pass |
|---|---|---|---|---|---|---|---|---|
| form | 200 | 64,913 | 145,336 | 2.24 | 1,243 | 6.21 | 0 | layout 28,966 cycles |
| list | 144 | 47,941 | 113,739 | 2.37 | 405 | 2.82 | 0 | layout 22,055 |
| text | 184 | 73,949 | 161,210 | 2.18 | 455 | 2.47 | 0 | layout 31,709 |
| springs | 1,042 | 802,275 | 3,028,120 | 3.77 | 2,406 | 2.31 | 0 | build 590,897 (2.59 M insns) |

## What it says

- **Misses are not where the time goes.** At 3,961 nodes every column fits in L2 + L3; last-level
  misses are 0 or 1 per frame and L1D misses are under 6 per node per frame. A miss to L2 costs
  about 15 cycles: 20 k of them are at most 0.3 M of the frame's 1.24 M cycles, and the hardware
  prefetcher hides most of that for the sequential column sweeps.
- The misses there are sit in the parent-following passes: `resolve.x`, `resolve.y` and `place`
  have 70% of layout's L1D misses (they read the parent's row, a gather). `fit` and `finalize`
  stream.
- **The cost is instructions and dependency chains.** `build` runs 298 instructions per node
  (prototype `Tree.push` and widgets, C0800). `finalize` (IPC 1.50), `fit` (1.77) and `prepare`
  (0.54, a store-bound fill) are latency- or store-bound, not miss-bound (C0805).
- **springs**: `build` is 74% of the frame, 2.59 M instructions for 1,000 `animate` calls, at IPC
  4.4: the linear SIMD id search per call (O(n^2), about 500 k compares per frame), not memory.
- Paint: 1.27 L1D misses per node, IPC 2.44; the 136-byte `Quad` (C0801, C0804) costs stores, not
  read misses.

So the data-layout commits that follow are judged by cycles and instructions per pass, with these
miss counts as the check that a change does not move a pass from compute-bound to miss-bound.
