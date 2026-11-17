# Draw a custom node with WebGPU

Use the same Zig drawing code and WGSL shader wherever the host can share a texture
between WebGPU and its native UI renderer. The experimental hosts call the application's
drawing code into a texture. Vulkan or Metal then samples that texture on a regular UI
quad in paint order. Ordinary widgets use their native draw path.

The sample is the runnable interface today. It is an offscreen experiment with a fixed
RGBA8 target. A public widget registration API, resize handling and device-loss recovery
are still pending. The existing inline `Frame.custom` route gives the host a draw command
in its current renderer's pass. [Application drawing code](../../src/render/wgpu/custom_draw_sample.zig) · [Existing custom rendering routes](custom.md)

## Implement the drawing

1. **Set up once.** The host supplies a `WGPUDevice` and its `WGPUQueue`. In
   `Drawing.init`, create the pipeline from your WGSL, an application-owned uniform
   buffer and a bind group. The sample pipeline writes to `WGPUTextureFormat_RGBA8Unorm`
   with one sample. Match these properties to the drawing target.
2. **Record a dirty frame.** The host supplies a `WGPUCommandEncoder` and a
   `WGPUTextureView`. Open a render pass using the view as the color attachment. The
   sample writes the tint with `wgpuQueueWriteBuffer`, binds the pipeline and group,
   calls `wgpuRenderPassEncoderDraw`, and ends the pass before returning. Its `col` and
   `alpha` arguments are ordinary sample data. Your drawing can use its own inputs.
3. **Hand the encoder back.** The host finishes and submits it, establishes the
   ordering required by the selected native backend, and composites the result.
   The encoder, view, device and queue are borrowed. Leave their release and the
   supplied encoder's submission to the host.
4. **Reuse the result.** The host can skip the callback while the custom content and
   target stay valid. Native UI frames continue to sample the cached image. In the
   probes the host explicitly selects which frames redraw. An application integrating
   the contract would invalidate on changes to its custom scene or target.
5. **Tear down.** After outstanding use completes, `Drawing.deinit` releases the
   application's bind group, pipeline and buffer. The host owns the shared image and
   the resources that it supplied to the callback.

For a first drawing, use the sample's clear-only path. It opens and ends a pass and
needs no vertex buffer. Then enable its textured WGSL draw to see how the same callback
updates uniforms, sets bindings and issues draw commands. [Callback and WGSL](../../src/render/wgpu/custom_draw_sample.zig)

## Run the hosts

**Linux x86-64 with Vulkan.** Use the pinned Zig compiler, v29 headers, and the patched
Vulkan-only wgpu-native archive built using the research instructions. The host creates
the Vulkan device and queue, imports them into wgpu-native and wraps a native image. It
transitions the image for sampling after the callback. Set `GUEST_HEADERS` to the include
directory containing `webgpu/wgpu.h` and `GUEST_LIBRARY` to the patched
`libwgpu_native.a`. [Build the archive](../research/custom-webgpu/README.md#reproduce-on-linux-x86-64) · [Vulkan host](../../src/render/vk/probe_guest.zig)

```sh
zig build custom-draw-probe -Doptimize=ReleaseFast \
  -Dguest-headers="$GUEST_HEADERS" -Dguest-library="$GUEST_LIBRARY"
zig-out/bin/custom-draw-native native
zig-out/bin/custom-draw-webgpu check
zig-out/bin/custom-draw-webgpu cached
zig-out/bin/custom-draw-webgpu guest
```

`check` compares the entire composed frame against native reference pixels. `cached`
draws once during warmup. `guest` redraws the node on each timed frame. The native-only
executable can be built by omitting the archive option. Normal native builds use neither
experiment option.

**macOS with Metal.** Use the pinned Zig compiler, the macOS SDK and the stock v29
wgpu-native package. This implementation gets the native Metal device and texture from
WebGPU. It uses separate WebGPU and Metal queues with CPU completion waits for the
experiment. The job builds the binary, checks the reference images, and times cached and
redrawn frames. [Metal host](../../src/render/metal/probe_webgpu.zig) · [Job commands](../../ci/jobs/metal-webgpu.sh)

```sh
ci/run.sh metal-webgpu
```

## Cost and backend coverage

On Linux x86-64, the matched native-only executable contained zero WebGPU C entry points.
The Vulkan/WGSL guest increased the stripped executable size by **4.57 MiB**. The two
builds of the ordinary Vulkan renderer, with and without the experiment options, had
identical machine code. A cached node still costs texture storage and a native textured
quad. In ten lavapipe rounds its median CPU difference through submit was +0.25 µs
relative to the native-only fixture, within the observed variation. On the earlier NVIDIA
run, redrawing one 56 × 56 node added **30.7 µs** to the full frame (median paired
difference), including the application's draw and its extra submission. These measurements
are for the Vulkan experiment. [Measurements and method](../research/custom-webgpu/README.md)

Vulkan and Metal have experimental host programs. Direct3D 12, GLES and the software
renderer have no shared-texture adapter for this callback in the experiment. The regular
native and software rendering interfaces remain available. [Backend guide](backends.md)
