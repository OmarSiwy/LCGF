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

An application leaves the option at `auto` and runs through `lcgf_app` ("When you bring no
device" below), which falls back to software by itself where it has no GPU window. `sw` is for
microcontrollers, machines that must not load a GPU driver and the smallest static binary, not
the starting point for a desktop application. Application code names no back end.

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

A custom draw (the inline route in `custom.md`) runs in that pass. Write it once against
`render.gpu`, which presents WebGPU's object model over whichever API the build selects. Its
types are that API's own handles, and the native calls stay one field away. You can also write
it straight against the native API, behind the same switch. The software back end has no
`gpu`. [Custom drawing with lcgf_render.gpu](gpu.md)

## When you bring no device

`lcgf_render.Setup` makes what an application without its own GPU code needs, moved from the
shells that use it:

| Back end | Setup | Used by |
|---|---|---|
| `vk` | `vk.Setup` (loader, instance, device, renderer) and `vk.setup.Window` (surface, swapchain, frames and the kept picture: `begin` and `present`, or `draw` in one call; `rebuild`) | Android shell, the X11 GPU window (`src/shell/x11/gpu.zig`) and through it `lcgf_app` |
| `metal` | `metal.Setup` over a `CAMetalLayer` (device, renderer, frames in flight, `draw`) | iOS shell |
| `sw` | `sw.Setup`: draw the list into a framebuffer that keeps the last frame, only inside its damage; you show the pixels | X11, Win32 and Wayland shells |

Direct3D 12, GL ES, wgpu and web have no `Setup` yet, because no shell draws with them; their
window pieces are in the back end itself (`d3d12/frame.zig`, `gles/egl.zig`, `wgpu/surface.zig`,
the web glue). Naming `render.Setup` for them is a compile error.

`lcgf_app` (`docs/guide/runtime.md`, "A window in one call") goes one step further and owns the
window, the device and the loop. Which back end it draws with follows `-Drender` and the
platform:

| Build | Window |
|---|---|
| Linux, `vk` (the default there) | X11 with Vulkan, the picture kept and only damage redrawn; under Wayland through XWayland when `DISPLAY` is set. `Surface` and `draw` exist only here ([surface.md](surface.md)) |
| Linux, `sw` or any other back end | the software window: Wayland when `WAYLAND_DISPLAY` names a compositor, else X11 |
| Windows | the software window (Win32) |
| macOS | AppKit with Metal, every frame drawn whole |

On the Vulkan build, `LCGF_RENDER=sw` in the environment, an unset `DISPLAY` or no Vulkan
device gives the software window instead. An application with `draw` runs there too: `draw`
is never called, and a `Surface` is not live (`Surface.live`) and paints its node's fill. On Linux an `lcgf_app` build links libc when its back end is a GPU one (the
Vulkan loader is opened at run time); a `-Drender=sw` build does not.

## Which one to pick

Use `auto` unless you have a reason. The native back ends exist because the overhead worth
removing is the portable layer above the GPU API, not the API (docs/DESIGN.md). Measured here
against wgpu-native v29 on the same Vulkan driver (docs/perf/RESULTS.md has the numbers):
the Vulkan back end spends 2.8 times less CPU per frame on an NVIDIA RTX 4060 and about 6 times
less on lavapipe, and after drawing it is about 1 MB smaller in resident memory than a
Vulkan-only wgpu instance on NVIDIA.

Pick `wgpu` when your application already uses wgpu and wants LCGF to draw into its passes.
Pick `gles` for devices with no Vulkan driver (old GPUs, some virtual machines); it has an ES2
path for the oldest. Pick `sw` for microcontrollers, for machines that must not load a GPU
driver, or for the smallest static binary and memory footprint where a GPU driver's own tens of
megabytes cost more than drawing on the CPU. A desktop application that might run without a GPU
does not need `sw` for that: `lcgf_app` falls back to software at run time.
