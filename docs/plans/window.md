# Plan: one window layer

Decided by the owner on 2026-11-27. The lead session lands the work; each stage below is one
agent's.

## Goal

1. An application draws a widget of its own through `lcgf_render.gpu`, WebGPU's object model,
   with full control of what happens inside that rectangle.
2. That drawing and the widgets around it are drawn independently: neither redraws the other.
3. Which back end draws the widgets (software or a GPU API) is not in application code. A
   build option chooses (`-Drender=`), and `LCGF_RENDER=sw` overrides at run time.

Today the parts exist and nothing joins them:

- `lcgf_render.gpu` is the WebGPU-shaped interface, on six GPU back ends
  (`docs/guide/gpu.md`), and `-Drender=` picks one back end per build.
- `lcgf_app.run` (`src/app/app.zig`) draws in software on Linux and Windows, skips custom
  draws, uses the bitmap font and never turns damage on.
- `src/example/host.zig` is a second, software-only application layer with its own hooks.
  Schemify copied it.
- No GPU back end keeps a picture: `vk.setup.Window.draw` clears and redraws everything, so
  widgets and a custom draw always redraw together.

## The contract

`lcgf_app` owns the shell, the device, the swapchain, the fonts and the pacing. An application
gives it `build`, and `draw` if it has surfaces.

| What changed | What runs | What must not run |
|---|---|---|
| A widget (`needsFrame`) | `build`, layout, paint; the window's picture is drawn again inside `DrawList.damage` | the application's `draw` |
| A surface (`Surface.redraw`, or its size) | the application's `draw`; the picture is drawn again inside that surface's rectangle | `build`, layout, paint, any upload of UI rows |
| Nothing | nothing: no frame, no wakeup | |

A surface is a texture the application owns, as a `<canvas>` is in WebGPU. The application
renders into it with its own passes and attachments. LCGF shows it as an ordinary quad
(`Style.texture`) at the node's place in paint order, so widgets over it cover it, and clip,
radius, opacity and transforms apply.

## What an application writes

The names may change while the usage is written; the properties in the table may not.

```zig
const app = @import("lcgf_app");
const gpu = app.gpu; // lcgf_render.gpu

const Scope = struct {
    theme: lcgf.widgets_base.Theme = .default,
    plot: app.Surface = .{}, // a rectangle of the window this program draws
    scene: Scene = undefined, // its pipelines and buffers

    pub fn build(s: *Scope, f: *Frame, _: *const Events) void {
        const ui = lcgf.widgets.on(f, &s.theme);
        if (ui.button(.run, .{ .label = "Run" }).clicked) s.running = !s.running;
        const node = s.plot.node(f, .from("plot"), .{ .size = .{ .fill, .fill }, .radius = 6 });
        if (f.interact(node, .{ .drag = true }).dragged) s.plot.redraw();
    }

    /// A frame in which a surface has to be drawn. Not called because a widget changed.
    pub fn draw(s: *Scope, g: *app.GpuFrame) !void {
        if (g.fresh) s.scene = try .init(g.device, g.arena, app.Surface.format); // new device
        s.scene.upload(&g.upload); // gpu.Upload: the frame's one upload phase
        const enc = g.encoder(); // ends the upload phase: gpu.Encoder
        var pass = enc.beginRenderPass(.{ .color_attachments = &.{.{ .view = s.plot.texture.createView(), .clear_value = .{} }} });
        s.scene.draw(&pass);
        pass.end();
    }
};
```

Each `lcgf_app` call is a few public calls of the layers under it (the granularity rule of
`docs/DESIGN.md`). A host that owns its loop uses those: the back end's `Setup.Window.begin`
and `present`, and `Surface`.

## How a frame is drawn

**GPU back end.**

- The window keeps one colour image of its own size, in the swapchain's format: the picture.
- A presented frame is: the application's passes into its surfaces (when one is dirty); one
  pass on the picture that loads, never clears, scissored to each damage rect, issuing the UI's
  commands; a copy of the picture to the swapchain image; present.
- The UI's rows stay in GPU buffers between frames. Only a built frame uploads.
- The draw list is not culled on this path: the scissor culls. The rows on the GPU then always
  describe the whole window, which a surface frame needs. `Context.trackDamage` culls, so the
  context gains a way to record the region and leave the list whole.
- A resize or a new swapchain makes the picture again and damages everything.

**Software back end.** `sw.Setup.draw` already keeps the framebuffer and draws only inside
damage, and the shells upload the damaged boxes. The window layer turns damage on and gives
the shell the application's images and glyphs.

**Without a GPU.**

- `-Drender=sw` has no `gpu`: a `Surface` or a `draw` there is a compile error that says so.
- A GPU build that opens no device falls back to software. An application with `draw` cannot:
  it exits with `error.NoGpu`.
- `LCGF_RENDER=sw` forces the fallback.

**Inline drawing stays below the window layer.** `Frame.custom` with `drawUntilCustom`
(`docs/guide/custom.md`) draws straight into the UI's pass with no copy, for a host that owns
its loop. `Frame.canvas` is unchanged: LCGF's own batch, drawn inline, damaged by its node.

## Stages

Every stage ends with `zig build test fmt lint`, `ci/run.sh census-src` and `ci/run.sh docs`
passing, and the job named in its row. `docs` compares `docs/api/API.md` with the index
`zig build docs` generates, so a commit that changes a public declaration regenerates it.

| # | Agent, branch | Work | Done when |
|---|---|---|---|
| 0 | `land`, `plan/land` | Rebase onto `main` and gate the commits that never landed: `saved/land-deletions` (23c98c03 HTML and CSS removed, ce372404 C ABI and C++/Rust removed, 2b2d1e69) and `saved/frame-data` (a1603851, 26cb5feb). Remove what `main` has since added that refers to removed things. | No removed path is referred to; the gates pass. |
| 1 | `window-sw`, `plan/window-sw` | The software window is complete. Schemify's report of 2026-11-27: under `trackDamage`, `x11.Window.present` leaves a canvas node empty, cannot take the application's images (texture 1 panics), and its text texture defaults to white. Fix each at its root. The shells stop making glyphs and choosing images: the caller passes both to `present`. `lcgf_app` turns damage on and takes the application's images in a form with no back end in it. | On Xvfb (`x11`): a canvas under damage shows its new camera and only its rectangle is uploaded; an application image draws; an idle second presents nothing. |
| 2 | `window-gpu`, `plan/window-gpu` | The Vulkan window keeps its picture: `begin` and `present` on `vk.setup.Window`, the pass scissored to damage, rows kept on the GPU, the region recorded without the cull. | `x11-gpu` on lavapipe: T1 below; a resize; an out-of-date swapchain. |
| 3 | `window-gpu` | `lcgf_app` on the GPU: X11 with Vulkan on Linux, `Surface`, `draw`, the application's images, the fallback and `LCGF_RENDER`. A Wayland session uses X11 through XWayland when `DISPLAY` is set, until stage 8. `examples/surface`. A guide page. | T2, T3, T4 below, on lavapipe. |
| 4 | `app-text`, `plan/app-text` | `lcgf_app` draws text with real fonts at the screen's scale: the application's font files (`Options.fonts`), else the system's default faces (`src/text/fallback/system.zig`), else the bundled bitmap font. `text_stack.Stack` measures and wraps, `raster` fills `raster_atlas` at physical pixels, and the atlas reaches the back end as dirty rects. | A golden paragraph at scales 1, 1.25 and 2: proportional, with `∞ … ·`, 0 bad pixels against a reference rasterization. |
| 5 | `app-text` | Canvas text stays sharp under zoom. Measure a distance-field atlas (`src/text/raster/sdf.zig`) against rasterizing again at the settled size, and keep one. | A canvas label golden at camera scales 0.5, 1, 2, 4 and 8, on `sw` and on Vulkan, with an edge no wider at 8 than at 1. |
| 6 | `scale-pace`, `plan/scale-pace` | The X11 software path paces to the display's refresh rate, read from RandR, not to 60 Hz. Goldens at scales 1 and 2. A test for scale detection on Wayland (integer and fractional) and on the web, where one is missing. | A recorded RandR reply for a 120 Hz mode gives 1/120 s. The golden jobs pass at both scales. |
| 7 | later | Every example runs through `lcgf_app`. `src/example/host.zig`'s `Incremental` and `src/example/window.zig` are deleted. `docs/DESIGN.md` and the guides say what is true. | Nothing imports the deleted files. |
| 8 | later | Win32 with Direct3D 12; the picture on Metal; the GPU on Wayland (the shell has no libwayland, so a Vulkan surface cannot be made over it: dmabuf buffers on the shell's own connection); GL ES; the web. | |

Stages 0, 1, 2, 4 and 6 start together. Stage 3 and the wiring of stage 4 start when stage 1
is on `main`: until then only `window-sw` edits `src/app/app.zig` and the shells' `present`.

## Tests that show the contract

- **T1.** A frame that is all blue, then a frame whose list is all red with a 32 × 32 damage
  rect: the window reads red inside the rect and blue outside.
- **T2.** 100 surface redraws under an idle UI: `build` is called 0 times, 0 bytes of UI rows
  are uploaded, the picture's pass is scissored to the surface's rectangle, pixels outside it
  are the same bytes before and after, and pixels inside show the new content.
- **T3.** 100 widget frames (a button's hover toggling) beside a surface: `draw` is called 0
  times.
- **T4.** An idle second presents 0 frames.

Report with each stage, with the workload and the conditions: CPU time per frame through
submit for a full redraw, for one small damage rect and for a surface frame, at 2560 × 1440 on
lavapipe and on the machine's GPU where its display can be reached.

## Rules for the agents

- Work in your own worktree, on the branch in your row, from `main`. Never write to the
  primary checkout, never push, never message another session.
- Copy the primary checkout's `zig-pkg/` into your worktree instead of fetching it again.
- Run Zig through `nix develop -c`. A CI job that needs Xvfb or lavapipe runs in
  `nix develop .#golden -c ci/run.sh <job>`.
- One logical change per commit, and every commit builds and passes (`CONTRIBUTING.md`).
  Messages follow `git log`: `area: one sentence`, then why, what, and how it was checked.
- A public function arrives with the test that uses it. Write the usage first.
- Keep OS, allocator and GPU dependencies out of tier 0. A new dependency is a design change:
  report it, do not add it.
- Rebase onto `main` before you report. `main` moves while you work.
- Report: the commits, each gate's last lines of output, measurements with their conditions,
  every place you left this plan and why, and what you did not do.
