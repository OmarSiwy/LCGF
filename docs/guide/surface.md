# Drawing your own pixels in an `lcgf_app` window

A `Surface` is a rectangle of the window that you draw yourself with `lcgf_render.gpu`
([Custom drawing with lcgf_render.gpu](gpu.md)): a plot, a viewport, a video frame. It has a
texture of its own, and the UI shows that texture as an ordinary quad at its node's place in
paint order. Widgets over it cover it, and its node's clip, radius and opacity apply.

## Which layer to pick

A surface is one of three ways to draw what the widgets cannot (docs/DESIGN.md, "An
application's own drawing: three layers"):

- **A `Surface`** when you need the GPU itself: your own passes, pipelines and WGSL. It needs
  a GPU window (below).
- **`Frame.canvas`** for 2D content (lines, rectangles, arcs, polygons, labels) under a camera.
  LCGF owns its shader and a software twin held to the same pixels, so it draws the same on
  every back end, software included, and your code fills columns and moves the camera. It has
  no joins between segments, no curves and no gradients (src/draw/canvas.zig).
- **An `lcgf_app.Image`** when there is no GPU at all, or the pixels are yours anyway: CPU
  pixels you fill, with `src/draw/paths.zig` (paths to coverage, an `alpha` image) or your
  own code. The window shows it and redraws the nodes that show it when its `generation`
  changes.

Pick the canvas for anything a 2D batch can draw, and a surface only for what needs shaders of
your own.

## An example

The whole program is [`examples/surface/main.zig`](../../examples/surface/main.zig): a button
and rings that a WGSL shader animates. It is not quoted here because the guides' examples
build without a GPU; `ci/run.sh app` builds it and runs it on Xvfb, where it fails if no
ring was drawn.

```sh
zig build surface-example && zig-out/bin/surface-example
```

It needs a Vulkan build on Linux (`-Drender=vk`, the default there). The window is X11, and a
Wayland session runs it through XWayland when `DISPLAY` is set. In any other build `gpu` is a
compile error that says why; `Surface`, `GpuFrame` and `draw` compile, and a surface is never
live there (below).

## The two functions

An application with surfaces has the `build` every `lcgf_app` application has, and one more:

- `build(app, f, events)` lays out the widgets. A surface is a node in it:
  `app.plot.node(f, .from("plot"), style)`, where `plot` is a `lcgf_app.Surface` kept in the
  application's state, as a `<canvas>` lives in a page.
- `draw(app, g)` draws into the surfaces, on `g.device`, with `g.upload` for buffer and texture
  writes and `g.encoder()` for passes. Make the pipelines and buffers in `g.arena` when
  `g.fresh` is set (the first `draw`). Render into
  `plot.texture.createView()`, `Surface.format`, over its first `plot.size` pixels.

## What each frame costs

The window draws again only what changed:

| What changed | `build` | `draw` | Drawn again |
|---|---|---|---|
| A widget (input, a signal, a timer) | yes | no | the frame's damage, from the new rows |
| A surface (`plot.redraw()`, or its node's size) | no | yes | the surface's rectangle, from the rows already on the GPU |
| Nothing | no | no | nothing: no frame, the loop sleeps |

So a widget that changes never calls `draw`, and an animation never builds. To animate, call
`plot.redraw()` at the end of `draw`: it asks for the next frame, which the display's refresh
(FIFO) paces. Calling it in `build`, for example when a button is clicked, asks for one frame.

## When the window is not shown

A minimised, hidden or blanked window takes no frames. The loop gives the frame up
(`Stats.not_shown`) without calling `draw`, owes the whole window, and sleeps: it tries again
on the next event or after `retry_seconds` (half a second). When the window takes a frame
again, it is drawn whole from the rows and the surface textures already on the GPU; `draw`
runs only if a surface asked for it.

## Without a GPU

`LCGF_RENDER=sw` forces the software window, and a machine without a display or a Vulkan
device falls back to it. Every application runs there. Its `draw` is never called, and a
surface's node paints its style's fill. `plot.live()` says which window it is in, so `build`
can put something else in the surface's place: a message, or a CPU-drawn `lcgf_app.Image`.
It is false in every frame of a software window, and true in every frame of a GPU one.

A surface has no software fallback of its own, because its pixels are defined by your shaders
and pipeline state. Running them takes an implementation of the GPU API and a shader compiler,
which is what a software driver (lavapipe, WARP) is; no framework ships one, and WebGPU makes a
fallback adapter optional. Where a software Vulkan driver is installed, a surface runs on it
unchanged: that is how CI runs `examples/surface`. Content that must draw without any GPU
belongs on the canvas or in an image.
