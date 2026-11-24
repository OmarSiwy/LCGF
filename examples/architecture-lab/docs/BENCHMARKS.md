# Measuring the architecture lab

The tools answer separate questions: how much application preparation costs,
how much complete software drawing costs, when retained pixels save work, and
whether reused subtrees preserve both output and application updates.

This example uses the framework checkout selected by its single `lcgf`
dependency. It does not include baseline or previous framework snapshots.
Measure identified source revisions with the same application and compiler
configuration, then compare the resulting executables.

## Build before timing

From the example directory, use the exact Zig version in `.zigversion`:

```sh
zig build bench-build incremental_bench-build reuse_bench-build \
  -Doptimize=ReleaseFast -Dcpu=x86_64 -j2 --prefix out/current
```

An optional `-Drevision=COMMIT_SHA` labels application reports. If the source
contains uncommitted changes, record those separately rather than labelling it
as a clean commit. The default label is `working-tree`. Keep CPU target,
architecture, optimization mode, vector width, compiler, and scene settings
identical between compared builds. `x86_64` is the generic target used by the
example reproduction commands; choose a matching target for another machine.

Stop other builds and benchmark processes before collecting timing data. On
Linux, `--cpu N` in the Python runners selects one logical CPU allowed by the
current affinity mask. Affinity does not provide exclusive CPU isolation.
Retain run ranges and outliers on shared machines.

## Metric boundaries

| Metric | Timed work |
|---|---|
| `ui` / architecture `warm_ui` | Begin a frame, construct the application, and finish layout/draw-output preparation. |
| Architecture `changed_filter_ui` | Commit a filter change and prepare a frame, including the 100,000-record projection rebuild. |
| `software_draw` | Unconditional host drawing: glyph preparation, clear, and full software rasterization. |
| `full_cpu_frame` | UI preparation plus complete software drawing. |
| `idle_scheduler` | Repeated scheduler checks after the context settles. |
| Core scene `frame` | The public frame pipeline on a larger layout/text scene. |
| Dynamic `full_draw` / `incremental_draw` | Render the same prepared output fully or through retained damage tracking. |
| Dynamic `ui` | Shared UI preparation; the preceding scripted input/state mutation is outside this interval. |
| Reuse `full_rebuild.frame` / `retained.frame` | Context begin, public construction/reuse, and frame completion; excludes rasterization and presentation. |

These measurements exclude X11 transport, the display server/compositor,
GPU execution, display/vsync, input-to-display latency, and power. Static UI
and idle samples average batches; inspect `iterations_per_sample` before
interpreting their percentile fields as individual-operation latency.

The application stores 100,000 records but constructs only the visible UI.
It does not create a widget for each stored record. Warm projection samples
and changed-filter samples are different workloads and must remain separate.

## Static and architecture comparisons

Build `bench` and `core_bench` for a reference and candidate revision into
separate output directories. To select another framework for an external copy
of this example, use `zig fetch --save=lcgf PATH_TO_CHECKOUT`, then build that
copy. Preserve the same application source and selected limits. The older
framework must satisfy the APIs used by the chosen harness; compile errors are
not a reason to change only one side's workload.

The following command uses already-built binaries; replace the two output
directories with their actual locations:

```sh
python3 tools/measure.py \
  --baseline out/reference/bin/bench \
  --candidate out/current/bin/bench \
  --core-baseline out/reference/bin/core_bench \
  --core-candidate out/current/bin/core_bench \
  --output measurements/static-comparison \
  --repeats 5 --samples 101
```

[`measure.py`](../tools/measure.py) alternates reference/candidate process order
and rotates architecture order. It checks scene dimensions, pixel/output
hashes, configuration, and sampling compatibility. It exercises physical
800×600 and 1920×1080 at scale 1, 1600×1200 at scale 2, and 1000×750 at scale
1.25, plus the larger core scenes and all five architectures.

The output contains raw reports, commands, executable SHA-256 values, machine
metadata, and `summary.json`. Aggregate medians are medians of run medians;
p95/p99 aggregates are medians of each run's percentile, not pooled tails.
The minimum and maximum run medians are not confidence intervals. Five repeats
give one order an extra run; choose an even repeat count of at least four for
exact order balance. Do not discard inconvenient timing outliers.

## Incremental drawing

The dynamic benchmark accepts `[samples [width height scale]]`:

```sh
out/current/bin/incremental_bench 101 800 600 1
out/current/bin/incremental_bench 101 1000 750 1.25
out/current/bin/incremental_bench 101 1920 1080 1
```

The cases are unchanged, hover, selection, scroll, theme, navigation, sidebar,
and explicit invalidation. Each input frame produces one UI output shared by
the full and incremental paths. Render order changes every two frames so that
it is independent of alternating scenario states. Complete framebuffers are
compared byte for byte after every warmup and measured frame, outside timing.
Changing scenarios must actually change pixels.

Reports include damage area, pixel payload, full-path selections, glyph
rebuilds, changed frames, and sequence hashes. Pixel payload is damage area
times four bytes, excluding protocol headers, alignment, and synchronization.
It is a calculated upload opportunity, not measured X11 throughput or latency.

An unchanged retained draw is measured after a frame has already been requested
and built. The ordinary desktop scheduler still waits when no frame is needed.
Theme and broad layout changes can cover nearly the whole target; retained
drawing then pays comparison overhead while saving little raster work.

## Subtree reuse

The reuse benchmark accepts an optional JSON destination and `--retained-first`:

```sh
mkdir -p measurements/reuse
out/current/bin/reuse_bench measurements/reuse/current-0.json
out/current/bin/reuse_bench --retained-first measurements/reuse/current-1.json
```

It covers unchanged subtrees, ancestor clipping, ancestor layout, and mixed
signal/keyboard/timer updates at roughly 1,000 and 4,000 nodes. Every observed
frame compares output hashes, dimensions, and cumulative application updates
against full rebuilding. Sequence hashes are regression evidence; they are not
a mathematical proof against collisions.

Interpret retained timing only when `same_output_and_updates` is true and
`mismatched_frames` is zero. Lost timer events or keyboard activations make a
faster result invalid. The reference and candidate must also agree on their
full-build control sequence. Ancestor clipping changes periodically in this
fixture, so its median includes frames with unchanged inherited clipping.

The combined runner repeats the three dynamic sizes and both reuse versions:

```sh
python3 tools/measure_retained.py \
  --incremental out/current/bin/incremental_bench \
  --reuse-baseline out/reference/bin/reuse_bench \
  --reuse-candidate out/current/bin/reuse_bench \
  --output measurements/retained-comparison \
  --repeats 5 --samples 101
```

The `--samples` argument controls incremental sampling; the reuse executable
records its own 100 warmups and 1,001 measured frames. The runner rotates size
order and reverses full/reuse ordering, retains invalid reference evidence,
and excludes invalid reference timings from valid speed comparisons. It fails
if the candidate changes the required output or updates.

## Validation and interpreting a result

Run `zig build test check` before benchmarking. The test step includes all five
architectures and the framework host's full-versus-retained comparisons.
`zig build framework-test` covers the selected dependency's core. Additional
vector-width checks use `-Dlanes=4`, `8`, or `16` with a suitable CPU target;
keep lane counts identical in a timed pair.

Build and run the framework's branch census from the framework root using
`zig build census-src-obj -Drender=sw -Dcpu=x86_64_v3`, followed by the two
checkers in `tools/census`. Its core/RGBA and Alpha8 objects must be checked
independently. Branch counts describe emitted control flow, not elapsed time.

Report the tested revision, compiler, CPU target, scenario, sample boundaries,
output checks, run variation, and memory tradeoffs beside a speed claim.
Architecture names organize ownership; any performance conclusion must come
from the actual dense-data work and valid, equivalent output.
