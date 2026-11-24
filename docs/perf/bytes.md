# Bytes per node (C0804)

## Current styling branch

The current `Context.requiredBytes` capacity test measures **1004 bytes per node**.
The upstream baseline at `ed94db3` measured 924 bytes; transform origins, paint-reference/outset geometry, and prepared-texture revision
metadata and subtree participation add 40 bytes to each of the two generations of sparse paint-extra capacity.
`Look` remains 32 bytes and the GPU `Quad` remains 136 bytes. Text and custom rows
now carry their inherited transform and rounded clip; those costs follow the
separate `texts` and `customs` limits. The historical measurements below are retained
for their original optimization comparison.

## Historical C0804 measurements

Measured with `docs/perf/build/bytes.zig` (`Context.requiredBytes` at 8,192 nodes minus 4,096,
divided by 4,096; the same at every lane count) and pinned by the test "requiredBytes: 874 bytes
per node of capacity" in src/runtime/context.zig.

| | before (61816cb + main) | after |
|---|---|---|
| runtime `Context`, per node of capacity | 922 B | 874 B (-5.2%) |
| of which: tree, per generation | 376 B | 376 B, 48 of them shared |
| of which: draw list | 170 B | 170 B |
| `Context` at default `Limits` (4,096 nodes) | 4,106,048 B | 3,908,672 B (-197 KB) |

(The prototype's 0.65 KB per node in docs/CHECKS.md predates per-corner radii, opacity,
transforms, rounded clips, the paint op stream and the depth pass.)

## What changed

The runtime front end keeps two tree generations (this frame's, and last frame's for hit testing
and `Frame.reuse`). The layout scratch columns, `fit`, `nat`, `grow_sum`, `grow_inv`, `used` (two
axes each), `gap_total` and `cursor`, 48 bytes a row, are rewritten by every layout run before they
are read (`layout.prepare` zeroes or sets the accumulators, `fit` writes the rest) and read by
nothing outside one, and the two generations are never laid out at once. So the second generation
now shares the first one's (`Tree.initSharing`, `Tree.scratch`), and `Frame.reuse` copies every
column of a reused subtree but those (`mem.copyRowsExcept`).

## Where the rest is (per node, one tree generation)

| group | bytes |
|---|---|
| links: id, parent, end, text, custom | 20 |
| layout inputs (min, max, grow, pct, pads, offset, scroll, main per axis; gap, nkids, flow, shrink, aligns) | 96 |
| layout scratch (shared between generations) | 48 |
| layout outputs: size, pos, rect, vis, child clip, three u8 flags | 67 |
| paint inputs: look 32, border 4, uv 16, radii 16 | 68 |
| transform and opacity, own and inherited: transform 24, world 24, opacity 4, alpha 4, clip radii 16 | 72 |
| semantics: role, value | 5 |

Draw list, per node: `Quad` 136, op stream 9, commands 13, depth pass 12.

## Not done here: the lean Quad with a side table

`Quad` is the GPU instance row, 136 bytes since per-corner radii, opacity, a transform and clip
radii were added (80 in the prototype). Measured (docs/perf/paint.md): with 96-byte quads paint
goes 35.6 -> about 33.8 us, and about 16 of paint's 35.6 us are the quad stores. A lean 80-byte row
with the rare fields in a side table indexed by the quads that use them needs the vertex shader to
read that table: a storage buffer, which GLSL ES 3.0 (`translate.sh` targets `es300`) has no vertex
stage access to, or a texture fetched by index, which is a new per-frame resource in every back
end (sw, wgpu, vk, the golden tools' wgpu-py pipelines and the GL ES one to come). That is a change
to the renderer contract across several lanes' homes, not a footprint commit; reported to the plan.
