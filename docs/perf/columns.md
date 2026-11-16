# Columns regrouped by measured access (C0801)

## What was measured

`perf record` over `zig build bench` (rows scene, pinned to a P-core) and `perf annotate` of the
inlined paint sweep: one instruction held 9.5% of all bench cycles, about 40% of paint. Paint read
the node's `Look` by value (`const look = looks[i]`), a 36-byte row whose `params` sat at offset
16 of a 36-byte stride; LLVM copied the row to the stack and reloaded `params` from it with a
16-byte load spanning two of its own smaller stores, a blocked store forward on every node.

Per pass, which fields of `Look` are read:

| reader | fields |
|---|---|
| paint sweep 1 | all of them |
| finalize | `border` only (children clip inside the border) |
| `draw.inherit.clip` | `border` only |
| `damage.hashNodes` | all of them |

## What changed

- `Look` is 32 bytes with `params` first: rows and `params` are 16-byte aligned.
- `border` left `Look` for its own column, `Tree.Columns.border`, next to it: the two readers that
  want it alone read 4 bytes instead of a 36-byte row.
- Paint reads the row in place (`&looks[i]`), not a copy.

## Numbers

`zig build bench` (rows scene, 3,961 nodes), medians of five alternated runs of each binary,
pinned to CPU 2 (P-core, i9-14900HX), load average 4.0 to 5.5 on 32 CPUs:

| pass | before (50484ec) runs | median | after runs | median |
|---|---|---|---|---|
| paint | 47.6 47.6 47.8 49.6 49.6 | 47.8 us | 35.3 35.6 35.6 35.7 35.8 | 35.6 us (-26%) |
| finalize | 38.5 38.6 38.6 38.6 38.6 | 38.6 us | 38.5 38.6 38.6 38.6 38.7 | 38.6 us |
| frame | 325.9 325.9 326.3 327.0 328.5 | 326.3 us | 309.3 310.0 310.2 311.8 316.7 | 310.2 us (-5%) |

`bench --counters`, paint per frame: 191,715 -> 134,685 cycles, 462,136 -> 434,412 instructions,
IPC 2.41 -> 3.23 (L1D misses 5,077 -> 8,659: the stall hid them).

Steps of the change, measured the same way (three runs each, medians): the regrouped `Look` alone
took paint to 37.7 us, reading it in place another 2 us to 35.4.

finalize does not move with the `border` column (38.6 us either way): it is not bound by the bytes
it reads. It swings between 18 and 39 us with unrelated code changes around the same loop, the
latency chain through `child_clip[parent]`; that is C0805's.

## Not changed, and why

- Paint's second gather of the parent row (`clip_radii[parent]` next to `child_clip[parent]`):
  removing it changed nothing measurable (49.6 us both), so the two stay separate columns.
- `Quad` (136 bytes): writing 96-byte quads instead (no `xform`, `clip_radii`) moved paint 49.6 ->
  about 48.5 us, inside the noise; see C0804.
