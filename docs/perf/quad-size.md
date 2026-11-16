# Quad size: hot/cold split measured and dropped

Question (lane optimise, C0801/C0804): `Quad` grew from the prototype's 80 bytes to 136 when
per-corner radii, opacity, a 2D transform and clip radii were added to every instance. Should the
rare fields move to a side table indexed only by the quads that use them?

## Method

`zig build bench` (rows scene, 3,961 nodes, 1,281 quads), pinned to a P-core of an i9-14900HX,
load average 4 to 5 on 32 CPUs. Probe: `xform` and `clip_radii` removed from `Quad` (136 -> 96
bytes) and from paint's writes (`order.depthOrder`'s two tests on them set to true), everything
else unchanged; three runs each.

## Numbers

| state | paint, 136-byte Quad | paint, 96-byte Quad |
|---|---|---|
| before C0801 (store-forward stall in paint) | 49.6 us | about 48.5 us (-2%) |
| after C0801 | 35.6 us | about 33.8 us (-5%) |

A second probe removed the quad stores altogether (output wrong): paint 35.6 -> about 20 us, so
the stores of 538 KB of quads a frame are about 16 us of paint; the shrink above recovers a small
part of that. GPU upload: 56 fewer bytes per quad, about 66 KB a frame at 1,281 quads (40% less
upload) for the full 136 -> 80 split.

## Decision (lead, lane optimise): dropped

The CPU gain is a few percent of paint, near the noise. The upload saving does not pay for what
the split needs: the vertex shader reading a side table, across quad.wgsl, the committed
translations (src/render/shaders/gen/), sw, wgpu, vk, the golden tools' wgpu-py pipelines and the
GL ES path, which has no storage buffers in the vertex stage (translate.sh targets `es300`), so it
would also need a texture-based table. Reopen only with new data: a scene where quad upload or
paint stores dominate the frame.
