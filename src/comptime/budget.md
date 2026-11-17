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
