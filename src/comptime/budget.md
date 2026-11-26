# Comptime front-end costs

## Compiling a spec

Run `python3 src/comptime/budget.py` in the pinned development shell. Each row
includes the root column, its child rows and their labels. The exported lookup
reads the flattened parent table at a runtime index, so the compiler must emit it.
The table below gives elapsed time through object emission and the sizes of that
object's code and read-only data. It covers flattening and the lookup. A complete
application also compiles the layout, paint and widget code it uses.

| Nodes | Compile (s) | Code (bytes) | Read-only data (bytes) |
| ---: | ---: | ---: | ---: |
| 100 | 0.060 | 28 | 100 |
| 1,000 | 0.092 | 33 | 2,000 |
| 10,000 | 0.408 | 33 | 20,000 |

Measured on 2026-11-17 with an i9-14900HX and the repository's pinned Zig, targeting
x86_64-linux, x86_64_v3, ReleaseSmall. Times are medians of five compiler processes,
each with a fresh local cache and a shared toolchain cache. The CI compile-time
gate separately measures semantic analysis without object emission.

## Layout storage

`zig build ct-sizes` calculates the constant column sizes, the size of a retained
`Cols.Dynamic` and the per-frame `Layout.Scratch` separately. The runtime column is
the amount actually carved by `Tree.init` at the same node capacity. Its buffer
includes layout workspace. State, strings supplied by the caller, draw lists and
renderer allocations fall outside this comparison. Read-only bytes count declared
tables, so linker elimination can make the final image smaller.

| Example | Nodes | Read-only bytes | Retained RAM | Layout scratch | Runtime tree RAM |
| --- | ---: | ---: | ---: | ---: | ---: |
| Mixer | 8 | 410 | 424 | 4,864 | 7,360 |
| Card | 5 | 492 | 248 | 2,368 | 6,400 |
| Settings | 32 | 3,275 | 1,184 | 5,472 | 18,304 |
| Badge | 3 | 273 | 136 | 2,432 | 6,400 |
| Dashboard | 13 | 1,063 | 900 | 3,344 | 11,328 |

Measured on the same x86-64 host with the default SIMD width. The custom widget
example builds its rows at runtime and uses the runtime tree for layout.

## Editing a spec

On the same machine, `python3 src/comptime/edit_budget.py` measured 12.68 ms,
32.19 ms and 260.63 ms at 100, 1,000 and 10,000 nodes respectively.
The script keeps a Debug x86-64 compiler running with `-fincremental -fno-llvm`
and moves a label between rows five times after the initial build. Each time runs
from the update request to a linked executable. The script runs that executable
and checks node 10's parent to detect a stale result. The reported median excludes
both writing the source file and running the probe. The cold-build table above
uses a different optimization mode and produces an object.
