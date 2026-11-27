# Custom drawing with `lcgf_render.gpu`

`lcgf_render.gpu` is WebGPU's object model with the cost compiled away. You write a custom
draw once with buffers, textures, samplers, pipelines, bind groups and WGSL, and it builds for
Vulkan, Metal, Direct3D 12, GL ES 3, wgpu-native and WebGPU in the browser. Each projection maps
the model at compile time onto the API that build selects (`-Drender`). There is no wrapper
underneath:

- **Types are the native handles.** A `gpu.Buffer` on Vulkan is a `VkBuffer` and its size; a
  `gpu.RenderPipeline` is a `VkPipeline` and its layout. Every field is public, and so is the
  native API (`gpu.vk`, `gpu.native`). Reaching past the projection is a field access.
- **Calls are the native calls.** `pass.draw(3, 1, 0, 0)` is one `vkCmdDraw`. The check
  `ci/jobs/gpu-zero-cost.sh` builds the same draw twice in ReleaseFast, once by hand in raw
  Vulkan and once through the projection, and requires the same instructions.
- **Nothing tracks state.** WebGPU's implementation tracks the state of every resource, every
  binding and every submission. The projection doesn't. A frame moves through phases instead, and
  each phase has a fixed state: you can only write in the upload phase, and you can only draw in a
  pass.

The `gpu` in the examples is `@import("lcgf_render").gpu`. Every code block below is a piece of
`docs/guide/gpu.zig`. That file is generic over the projection and the shader. A Vulkan test
(`zig build vk`) runs it on a real device and reads the result back.

## What differs from WebGPU

| WebGPU | `lcgf_render.gpu` |
|---|---|
| The device allocates each resource | You pass an `Arena` to every `create*`. An arena is one native memory block plus a descriptor pool, and you own it. Free it as one block, or `reset` it. |
| `queue.writeBuffer` at any time | `Upload.writeBuffer` and `writeTexture` in the frame's upload phase. `Upload.finish()` ends the phase with one barrier and returns the `Encoder`. |
| Implicit layout transitions | Every texture has a resting layout: shader-readable, or general for storage. A pass the projection begins leaves its attachments resting. |
| Bind group layouts and entries as arrays | `createBindGroup(arena, pipeline, group, .{ ... })` takes a struct built from the WGSL at compile time. A binding that is misspelled, missing or of the wrong kind is a compile error. |
| Validation on every call | Debug builds check what comptime cannot: scissor bounds, a draw with no pipeline, write alignment. These checks and their fields don't exist in release builds. |
| `device.createShaderModule(wgsl)` | `gpu.Shader(source)`. The WGSL is reflected at compile time; naga translates it when you build. |
| `firstInstance` | GL ES 3.0 has no base-instance draw. The GL ES projection rebinds every instance-step buffer `first_instance` elements on for that draw instead, and its `@builtin(instance_index)` would start at 0, not `first_instance`. Read per-instance data from instance-step vertex buffers, not from storage indexed by `instance_index`: on GL ES, a draw with `first_instance != 0` whose vertex shader reads `instance_index` panics in every build. |

## Shaders

A build turns your WGSL files into a module with one declaration per shader. Each declaration
holds the source and the translation the selected back end consumes: SPIR-V, MSL, HLSL or GLSL.
In `build.zig`:

    const shaders = lcgf.addGpuShaders(b, backend, .naga, &.{.{ .name = "picture", .path = b.path("src/picture.wgsl") }});

`.naga` runs naga, which must be on `PATH`, when you build. `.{ .prebuilt = dir }` reads the
translations committed to `dir` instead, for builders without naga. The repository's own
shaders build that way, from `src/render/shaders/gen/`, which `src/render/shaders/translate.sh`
regenerates. Each back end then fixes up naga's output for its own binding model at compile
time (`src/render/gpu/naga.zig`):

- GLSL gets explicit bindings.
- HLSL samplers get registers.
- MSL `user(fakeN)` placeholders get buffer, texture and sampler slots.

## Set up once

```zig
pub fn init(dev: gpu.Device, arena: *gpu.Arena, target: gpu.Target) !P {
    const image = try dev.createTexture(arena, .{ .size = .{ .width = 2, .height = 2 }, .format = .rgba8_unorm, .usage = .{ .texture_binding = true, .copy_dst = true } });
    const smp = try dev.createSampler(.{});
    const quad = try dev.createBuffer(arena, .{ .size = 6 * 8, .usage = .{ .vertex = true, .copy_dst = true } });
    const tint = try dev.createBuffer(arena, .{ .size = 16, .usage = .{ .uniform = true, .copy_dst = true } });
    const pipeline = try dev.createRenderPipeline(Shader, .{
        .vertex = .{ .buffers = &.{.{ .array_stride = 8, .attributes = &.{.{ .format = .float32x2, .offset = 0, .shader_location = 0 }} }} },
        .fragment = .{ .targets = &.{.{ .format = target.format, .blend = .premultiplied }} },
        .multisample = .{ .count = target.samples },
    });
    // Group 0 of textured.wgsl as a struct: a binding misspelt, missing or of the wrong
    // kind is a compile error, not a validation message at run time.
    const group = try dev.createBindGroup(arena, pipeline, 0, .{ .params = tint, .tex = image.createView(), .smp = smp });
    return .{ .pipeline = pipeline, .group = group, .image = image, .smp = smp, .quad = quad, .tint = tint };
}
```

`P` is `Picture(gpu, source)`, and `Shader` is `gpu.Shader(source)`. Field names such as
`.params`, `.tex` and `.smp` are the variable names in the WGSL.

## Each frame: upload, then draw

```zig
pub fn upload(p: *const P, up: *gpu.Upload, tint: [4]f32) !void {
    try up.writeTexture(p.image, &checker, 8);
    up.writeBuffer(p.quad, 0, std.mem.sliceAsBytes(&corners));
    up.writeBuffer(p.tint, 0, std.mem.asBytes(&tint));
}
```

The inline route draws into the UI's own pass, at the custom node's place in paint order. Pass
the custom command's scissor, `gpu.scissor(c.rect, c.clip, scale, width, height)`, as `rect`:

```zig
pub fn draw(p: *const P, pass: *gpu.RenderPass, rect: gpu.Rect) void {
    if (rect.width == 0 or rect.height == 0) return;
    pass.setViewport(@floatFromInt(rect.x), @floatFromInt(rect.y), @floatFromInt(rect.width), @floatFromInt(rect.height), 0, 1);
    pass.setScissorRect(rect.x, rect.y, rect.width, rect.height);
    pass.setPipeline(p.pipeline);
    pass.setBindGroup(0, &p.group);
    pass.setVertexBuffer(0, p.quad, 0);
    pass.draw(6, 1, 0, 0);
}
```

The texture-in route draws into a texture of your own in a separate pass. The UI then shows that
texture as `Style.texture`, clipped, rounded and batched like any other quad:

```zig
pub fn drawInto(p: *const P, enc: gpu.Encoder, target: gpu.Texture) void {
    var pass = enc.beginRenderPass(.{ .color_attachments = &.{.{ .view = target.createView(), .clear_value = .{ .a = 1 } }} });
    p.draw(&pass, .{ .x = 0, .y = 0, .width = target.width, .height = target.height });
    pass.end();
}
```

Compute passes work the same way: `enc.beginComputePass()`, `setPipeline`, `setBindGroup`,
`dispatchWorkgroups`, `end`. They need Vulkan, Metal, Direct3D 12, GL ES 3.1, wgpu or WebGPU.

## The host's side

In an `lcgf_app` window the window layer is the host: `draw` gets the device, the upload phase
and the encoder already wrapped (`GpuFrame`), and the texture-in route is a `Surface`
([surface.md](surface.md)). The rest of this section is for a host of your own.

You own the device, the command stream and the UI's pass, as with every other route
([custom rendering](custom.md)). Each back end's `wrap` functions turn the handles you already
have into the projection's types:

| Back end | `gpu.Device.wrap` | `gpu.Upload.begin` | `gpu.RenderPass.wrap` (the UI's pass) | Example host |
|---|---|---|---|---|
| vk | `*const vk.device.Device` | `VkCommandBuffer`, or `beginStaged` with a `Staging` ring for texture writes | the command buffer, inside dynamic rendering | `src/render/vk/scenes.zig` |
| metal | `id<MTLDevice>` (set `staging`) | `id<MTLCommandBuffer>` | the render command encoder | `src/render/metal/play.zig` |
| d3d12 | `*const d3d12.device.Device` (set `staging`) | the command list | the command list | `src/render/d3d12/scenes.zig` |
| gles | the `Fns`, `Fns3` and optional `Fns31` tables | `{}` (the current context) | `{}` | `src/render/gles/play.zig` |
| wgpu | `WGPUDevice`, `WGPUQueue` | `WGPUCommandEncoder` | `WGPURenderPassEncoder` | `src/render/wgpu/play.zig` |
| web | device and queue handles (`lcgf.js` `gpuProjection`) | encoder handle | pass handle | `src/render/web/scenes.zig` |

Upload before the UI's pass begins, next to the renderer's own `prepare`. Then draw inline
while walking the commands with `drawUntilCustom`, exactly as `custom.md` shows.

## How it is checked

- **Conformance.** The render conformance scene's custom draw is `src/render/gpu/gradient.zig`,
  one file for every back end. The Vulkan, GL ES, wgpu and web goldens are compared at 0 bad
  pixels.
- **The rest of the model.** `src/render/gpu/check.zig` covers what the gradient doesn't:
  - a texture upload through staging;
  - render to texture, then sampling the result in a second pass;
  - vertex buffers;
  - instanced draws from first instances past 0, from a per-vertex buffer and two per-instance
    buffers (one bound at an offset), with `sint32x2`, `sint32x4` and `uint32` attributes;
  - a compute pass writing a storage buffer.

  It runs on Vulkan (lavapipe, with synchronization validation), GL ES 3.1, wgpu, and in
  Chromium (`src/render/web/test_gpu.html`).
- **Cost.** `ci/jobs/gpu-zero-cost.sh` compares instructions, as described above. For a whole
  frame, `src/render/vk/probe_projection.zig` repeats the custom-node timing from
  `docs/research/custom-webgpu/`. Redrawing a 56 × 56 node every frame costs about 2.5 µs of CPU
  time through submit. The wgpu-native guest it replaced cost 56 µs.

The Direct3D 12 and Metal test suites run the same `check.zig` checks. Direct3D 12 runs them
on WARP, or on vkd3d under Wine. Metal needs a Mac, and the checks skip on any other system.
