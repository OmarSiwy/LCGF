# Software rendering and subtree reuse

The final software measurements show lower complete-frame raster cost, large
savings for local retained updates, and faster valid subtree reuse. Fully
rebuilt layout/text controls remain approximately level. The evidence below
was collected **before the architecture lab was packaged as an upstream
example**. Every one of the measured candidate's 509 files under `src/` matches
the production source imported with this change. Example build integration and
benchmark metadata were subsequently updated; these are **archived measurements,
not new timings of the packaged PR build**. See the
[provenance record](../../bench/software/provenance.json) and
[evidence inventory](../../bench/software/README.md).

## Comparison and method

**Previous** means commit `ed94db3da27882ef1c87d0dd15a382b4df39e2c2` plus
[reference patches 01–03](../../bench/software/reference-patches/README.md):
input-identity, Mono-wrap, and initial software-raster optimizations. It already
includes those improvements. **Current** means the final renderer, retained
host, and reuse implementation. Full-versus-incremental results compare two
paths in that same current implementation.

The machine was an Intel Xeon Platinum 8573C running Linux x86_64. Builds used
Zig `0.18.0-dev.1151+8dfb7a7cc`, ReleaseFast, generic `x86_64`, and four SIMD
lanes. Five process runs per case were pinned to logical CPU 2. Affinity did not
provide exclusive CPU isolation. Paired process order alternated, architecture
and size order rotated, and reuse order reversed between runs; five repeats
leave one extra initial-order run. No timing outliers were discarded.
[Static environment](../../bench/software/results/static/environment.json),
[retained environment](../../bench/software/results/retained/environment.json),
and both directories' command logs preserve the exact run setup and executable
hashes.

Tables report the median of five run medians. Brackets give their minimum and
maximum, not confidence intervals. Raw values are nanoseconds; aggregate
p95/p99 values in the JSON are medians of per-run percentiles, not pooled tails.
Static drawing uses 100 warmups and 101 samples; UI samples average eight
frames, idle samples average 1,000 scheduler calls, and architecture cases use
501 samples. Core/reuse cases use 100 warmups and 1,001 measured frames.
Incremental cases use 32 warmups and 101 measured frames. Storage setup and
output checking are outside timing. The
benchmark guide (`examples/architecture-lab/docs/BENCHMARKS.md` at `e0ad0404`) defines
each timing boundary.

These are CPU wall-time measurements. They exclude X11 transfer,
server/compositor work, GPU execution, vsync, input-to-display latency, and
power. They do not establish the same gains on another ISA or font workload.

## Complete CPU software frames

The application stores 100,000 records and builds only its visible UI: 59 nodes
in the three 800×600 logical-size cases and 93 at 1920×1080. All paired
previous/current runs have matching scene dimensions and pixel hashes. Full CPU
frame time includes UI preparation, glyph preparation, and complete software
drawing. Source: [static summary](../../bench/software/results/static/summary.json).

| Physical size / scale | Previous, ms | Current, ms | Median reduction |
|---|---:|---:|---:|
| 800×600 / 1× | 4.427 [4.339–4.472] | 3.673 [3.605–3.711] | 17.0% |
| 1920×1080 / 1× | 8.705 [8.635–8.826] | 7.485 [7.374–7.854] | 14.0% |
| 1600×1200 / 2× | 14.802 [14.661–14.819] | 12.656 [12.391–14.030] | 14.5% |
| 1000×750 / 1.25× | 17.185 [16.929–17.661] | 6.275 [6.142–8.588] | 63.5% |

The fractional-scale result reflects specialized coverage sampling and proven
opaque interiors, while contours retain the reference shader. A separate
[borderless-interior ablation](../../bench/software/results/borderless-ablation/summary.json)
changed only the current renderer's zero/subthreshold-border eligibility,
helper name, and tests. At 1000×750 / 1.25× it reduced full CPU frames from
10.072 [9.987–10.479] to 6.192 [6.069–8.719] ms, or 38.52%, with matching
pixels. Its 800×600 control changed by only 1.50%, with overlapping ranges and
a 6.476 ms candidate run median; that small difference is inconclusive.

The 3,961-node full-build controls provide no broad layout-speedup claim:
no-wrap preparation changed from 328.166 to 332.710 µs (1.38% slower), and
all-wrap preparation from 340.131 to 341.542 µs (0.41% slower), with overlapping
run ranges. Architecture warm-UI medians span 5.382–5.490 µs; changed-filter
medians span 224.296–224.948 µs across VIPER, MVP, MVVP, MVVM, and MVVM-C. Their
shared projection rebuild dominates the small orchestration differences.
[Control and architecture evidence](../../bench/software/results/static/summary.json).

## Retained drawing and correct reuse

For each changing input, one prepared UI output feeds both current draw paths.
Their complete framebuffers are compared byte for byte after every warmup and
measured frame: 133 checks per scenario, size, and run. Every changing scenario
changes pixels. The table shows the 800×600 / 1× case; the
[retained summary](../../bench/software/results/retained/summary.json) includes
1000×750 / 1.25× and 1920×1080 / 1×, full-path ranges, counters, and hashes.

| Scenario | Forced full draw, µs | Incremental draw, µs [range] |
|---|---:|---:|
| Unchanged | 3,609.758 | 1.560 [1.515–1.824] |
| Hover | 3,658.676 | 109.669 [109.517–109.945] |
| Selection | 3,887.017 | 2,952.293 [2,905.189–2,970.729] |
| Scroll | 3,630.448 | 1,749.016 [1,734.932–1,770.982] |
| Theme | 3,633.085 | 3,647.053 [3,583.122–3,710.024] |
| Navigation | 3,637.723 | 3,653.438 [3,612.073–3,718.348] |
| Sidebar | 3,542.637 | 3,282.997 [3,246.502–3,311.719] |
| Explicit invalidation | 3,637.688 | 3,644.835 [3,567.706–3,677.126] |

Unchanged and hover frames retain glyphs; local damage skips pixel work. Broad
changes approach full drawing and can pay extra comparison cost. These columns
exclude shared UI preparation and preceding scripted state mutation. An
unchanged draw is measured after a frame was requested and built; the desktop
scheduler still waits when no frame is needed. Hover's mean calculated pixel
payload is 6,800 bytes versus a 1,920,000-byte full framebuffer (99.65% less).
That is damage area × four bytes, excluding protocol overhead, and is not a
measured X11 latency or bandwidth improvement.

Reuse timing covers `Context.begin`, public construction/`Frame.reuse`, and
`Frame.end`; it excludes rasterization. Every observed frame checks output
hashes, dimensions, and cumulative updates against full rebuilding. Current
unchanged reuse improves over valid previous reuse by 45.5% at 993 nodes and
37.4% at 3,963 nodes. Current costs against its own full-build control are:

| Nodes / workload | Current full rebuild, µs | Current reuse, µs [range] | Reduction |
|---|---:|---:|---:|
| 993 / unchanged | 77.415 | 20.225 [20.132–21.474] | 73.9% |
| 995 / mixed updates | 79.341 | 42.944 [42.909–43.155] | 45.9% |
| 3,963 / unchanged | 340.760 | 111.773 [110.497–114.221] | 67.2% |
| 3,965 / mixed updates | 350.526 | 217.231 [210.175–224.029] | 38.0% |

**Previous mixed-update reuse timings are invalid and excluded.** At both
sizes, 1,093 of 1,101 checked frames differ, starting at step 8; previous reuse
loses all 137 timer fires and 17 keyboard activations observed by full rebuild.
Current reuse preserves those updates with zero mismatched frames. Ancestor
layout changes produce smaller previous/current gains, approximately 3–4%,
because changed geometry requires normal finalization. Source:
[reuse validity and timings](../../bench/software/results/retained/summary.json).

## Memory and ownership

These values describe explicit storage capacities, not resident-set memory.
The core, reuse, and retained-draw paths add no per-frame allocation.

| Storage | Previous | Current |
|---|---:|---:|
| Application context: 384 nodes, 160 text runs | 418,752 B | 419,456 B (+704 B) |
| Large core/reuse fixture context | 4,376,960 B | 4,381,312 B (+4,352 B) |
| Retained host owner + snapshot arena | Absent | 80,600 B additional |
| VIPER application value | 700,072 B | 700,072 B |
| 144×108 monochrome atlas | 62,208 B RGBA | 15,552 B Alpha8 (75% less) |

The retained total is a 216-byte owner plus 80,384-byte snapshot arena.
Context metadata adds one byte per node, four per timer, and twelve per memo
before alignment. Existing desktop glyph storage is another 1,672,448 bytes:
12,288 136-byte quads and two 160-entry `u32` span arrays. Framebuffers add
`4 × Framebuffer.len(width, height)` bytes, including vector stride padding;
the X11 server owns a separate backing pixmap. The old RGBA atlas expansion was
compile-time work, so Alpha8 saves representation bytes, not a per-frame atlas
conversion. Sources: [raw context metadata](../../bench/software/results/static/800x600-candidate-0.json),
[retained metadata](../../bench/software/results/retained/summary.json),
example storage (`examples/architecture-lab/src/platform/x11.zig` at `e0ad0404`), and
[atlas source](../../src/example/font.zig).

Retained rendering requires persistent, exclusively owned pixel/glyph/snapshot
storage; external writes require `invalidate()`. Storage, dimensions, scale,
format, or background changes force full drawing. Unsupported drawing effects,
images, and insufficient capacity retain full-render fallbacks. The
software optimization guide (`examples/architecture-lab/docs/SOFTWARE_OPTIMIZATION_GUIDE.md` at `e0ad0404`)
documents these contracts and the SIMD/data-layout changes.

## Run a new measurement

The architecture lab was later split into one example per architecture (`examples/viper`,
`mvp`, `mvvp`, `mvvm`, `mvvm-c`), which carry no benchmark harness. The harness below is
the lab at commit `e0ad0404`: `git worktree add lab e0ad0404`, then work in
`lab/examples/architecture-lab`.

Use the architecture lab (`examples/architecture-lab/README.md` at `e0ad0404`) and its
benchmark commands (`examples/architecture-lab/docs/BENCHMARKS.md` at `e0ad0404`). From
that example directory, build before timing:

```sh
zig build bench-build incremental_bench-build reuse_bench-build \
  -Doptimize=ReleaseFast -Dcpu=x86_64 -j2 --prefix out/current
out/current/bin/incremental_bench 101 800 600 1
out/current/bin/reuse_bench
```

For previous/current comparisons, reconstruct the reference with the
[three original patches](../../bench/software/reference-patches/README.md),
then build the same packaged benchmark source against each selected checkout.
Use `tools/measure.py` and `tools/measure_retained.py` with separate reference
and current executable paths, matching compiler/target/lanes/settings, and
available CPU affinity. Save the new commands, binary hashes, raw runs, and
summaries separately. The archived JSON retains its historical paths and
labels; newer harness metadata is not retroactively inserted into that evidence.
