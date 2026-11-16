# Vectorised quad emission (C0802): measured, not adopted

Paint's sweep 1 (`src/draw/paint.zig`) turns each node into a candidate quad and three candidate
ops, writing always and advancing by 0 or 1. The variant tried (`docs/perf/paint/vector-sweep.patch`,
unordered paint only): per block of `simd.lanes` rows, the visibility, has-quad, has-text and
has-custom flags as one vector compare each, the rect columns as four vector loads, then the
block's quads and ops written lane by lane with those flags (the AoS `Quad` row is written per
node either way).

`zig build bench` (rows scene, 3,961 nodes), five alternated runs of each binary, pinned to CPU 2
(P-core, i9-14900HX), load average 5.3 to 5.8 on 32 CPUs:

| | paint runs (us) | median | `--counters` cycles | instructions | IPC |
|---|---|---|---|---|---|
| scalar sweep (564f973) | 35.4 37.6 37.6 38.5 38.6 | 37.6 | 135,656 | 434,412 | 3.20 |
| vectorised flags | 37.2 37.4 37.6 38.7 53.4 | 37.6 | 130,842 | 370,970 | 2.84 |

15% fewer instructions, 3.5% fewer cycles, no change in wall time. Not adopted: a second code path
for the unordered case is not worth a gain the timer does not see.

Where paint's time is: with the quad stores removed (a probe, output wrong) paint takes 19.5 to
20.7 us instead of 35.6, so about 16 us of it is writing 3,961 136-byte quads (538 KB a frame,
more than L1). Writing 96-byte quads (no `xform`, `clip_radii`) took paint from 35.6 to about
33.8 us. The lever is bytes per quad, not the instruction count of the sweep: C0804.
