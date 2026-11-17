# Choosing a render back end

LCGF draws a frame's `DrawList` with one of seven back ends: software, Vulkan, Metal,
Direct3D 12, GL ES, web (WebGPU in the browser) and wgpu. A build compiles exactly one of them
for the `lcgf_render` module, picked by a build option:

```
zig build -Drender=auto     # the default: the target's own API
zig build -Drender=vk       # or sw, metal, d3d12, gles, web, wgpu (wgpu also needs -Dwgpu-native=v29)
```

| Target | `auto` picks |
|---|---|
| macOS, iOS | `metal` |
| Windows | `d3d12` |
| Linux, Android | `vk` |
| wasm32 | `web` |
| freestanding (microcontrollers) | `sw` |

Nothing chooses at run time and nothing dispatches: `lcgf_render.Renderer` is the selected back
end's own type, so a call through it compiles to the same machine code as one through a direct
import. `ci/run.sh render-select` checks that for every back end by comparing the two builds'
`.text` byte for byte.

Every code block below is a piece of `docs/guide/backends.zig`, which `zig build docs` compiles
and runs. The docs build selects `sw`, so the example draws into a framebuffer without a GPU.

## One frame, any back end

`lcgf_render` exposes the back end (`backend`), its renderer (`Renderer`), what the renderer
records into (`Pass`) and uploads through (`Queue`), and which one it is (`kind`). Code written
against those names compiles for whichever back end the build selected:

```zig
const render = @import("lcgf_render");

/// One frame on whichever back end the build selected: the same code for all of them.
fn drawFrame(gfx: *render.Renderer, queue: render.Queue, pass: render.Pass, draw: *const DrawList, glyphs: lcgf.render_iface.Glyphs, viewport: [2]f32, scale: f32) void {
    gfx.prepare(queue, draw, glyphs, viewport, scale); // uploads, before the pass begins
    lcgf.render_iface.render(gfx, pass, draw);
}
```

You still own the device, the queue and the pass (see `custom.md`), and what they are differs
per back end, as it must: `Pass` is a `VkCommandBuffer` for Vulkan, an
`MTLRenderCommandEncoder` for Metal, an `ID3D12GraphicsCommandList` for Direct3D 12, a
`WGPURenderPassEncoder` for wgpu, `void` for GL ES (the current context) and a framebuffer
target for software. Where your code makes one, switch on `kind` at compile time:

```zig
// What a pass is depends on the back end: here a framebuffer and its scissor.
const pass: render.Pass = switch (render.kind) {
    .sw => .{ .fb = &fb, .scissor = fb.all() },
    else => @compileError("this example draws in software"),
};
```

Custom draws (the inline route in `custom.md`) use your own pipeline in that pass, so they are
written for one back end, or for each behind the same switch. The experimental hosts
can also composite a texture drawn through a shared WebGPU callback. [WebGPU custom drawing](webgpu-custom.md)

## When you bring no device

`lcgf_render.Setup` makes what an application without its own GPU code needs, moved from the
shells that use it:

| Back end | Setup | Used by |
|---|---|---|
| `vk` | `vk.Setup` (loader, instance, device, renderer) and `vk.setup.Window` (surface, swapchain, frames, `draw`, `rebuild`) | Android shell |
| `metal` | `metal.Setup` over a `CAMetalLayer` (device, renderer, frames in flight, `draw`) | iOS shell |
| `sw` | `sw.Setup`: clear the framebuffer and draw the list; you show the pixels | X11, Win32 and Wayland shells |

Direct3D 12, GL ES, wgpu and web have no `Setup` yet, because no shell draws with them; their
window pieces are in the back end itself (`d3d12/frame.zig`, `gles/egl.zig`, `wgpu/surface.zig`,
the web glue). Naming `render.Setup` for them is a compile error.

## Which one to pick

Use `auto` unless you have a reason. The native back ends exist because the overhead worth
removing is the portable layer above the GPU API, not the API (docs/DESIGN.md). Measured here
against wgpu-native v29 on the same Vulkan driver (docs/perf/RESULTS.md has the numbers):
the Vulkan back end spends 2.8 times less CPU per frame on an NVIDIA RTX 4060 and about 6 times
less on lavapipe, and after drawing it is about 1 MB smaller in resident memory than a
Vulkan-only wgpu instance on NVIDIA.

Pick `wgpu` when your application already uses wgpu and wants LCGF to draw into its passes.
Pick `gles` for devices with no Vulkan driver (old GPUs, some virtual machines); it has an ES2
path for the oldest. Pick `sw` for microcontrollers, or for the smallest memory footprint where
a GPU driver's own tens of megabytes cost more than drawing on the CPU.
