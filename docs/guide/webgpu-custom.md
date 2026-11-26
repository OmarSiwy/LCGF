# Draw a custom node with WebGPU

Write the node's drawing once against `lcgf_render.gpu`, in WebGPU's object model with a WGSL
shader. It compiles to the native API of the selected back end. Then pick one of two routes:

- **Inline.** Draw in the UI's pass at the node's place in paint order.
- **Texture in.** Draw into a texture of your own, and show that texture on an ordinary UI quad
  with `Style.texture`. It is clipped, rounded, batched and layered like the rest of the UI. When
  the content has not changed, skip the redraw and the UI keeps sampling the texture.

[Custom drawing with lcgf_render.gpu](gpu.md) covers the API, the frame phases and each back
end's host side. Its example (`docs/guide/gpu.zig`) has both routes: `draw` for inline and
`drawInto` for texture in.

## A node redrawn every frame

`src/render/vk/probe_projection.zig` is a complete texture-in host on Vulkan:

- a 56 × 56 node texture created by the application;
- a textured, tinted WGSL draw into the node texture;
- the UI's own pass sampling the node texture as a quad.

The node's pass goes into the same command buffer as the UI's pass, ahead of it. The pass's
`end` leaves the texture shader-readable, and that is the whole hand-off.

```sh
zig build custom-draw-probe -Doptimize=ReleaseFast
zig-out/bin/custom-draw-projection check        # every composed frame against reference pixels
zig-out/bin/custom-draw-projection cached       # drawn once, sampled every frame
zig-out/bin/custom-draw-projection projection   # redrawn every frame
```

The probe's WGSL is translated by naga during the build, so naga must be on `PATH`. On lavapipe,
redrawing the node every frame added a median of 2.45 µs of CPU time through submit and 2.05 µs
of application recording. The projection added 21,920 bytes to the stripped executable. The
wgpu-native guest it replaced added 56.3 µs, 59.4 µs and 4.57 MiB.
[Measurements and method](../research/custom-webgpu/README.md)

## The Metal guest experiment

Before the projection, custom nodes ran on a second WebGPU implementation (wgpu-native) that
shared the native device. The Vulkan host of that experiment is retired. The Metal host remains
until a macOS run times the projection the same way. It borrows the Metal device and texture
from stock wgpu-native v29 and waits on the CPU between the two queues.
[Metal host](../../src/render/metal/probe_webgpu.zig) · [Job commands](../../ci/jobs/metal-webgpu.sh)

```sh
ci/run.sh metal-webgpu
```
