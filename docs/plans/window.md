# Plan: one window layer

Decided by the owner on 2026-11-27. The lead session lands the work; each stage below is one
agent's.

## Goal

1. An application draws a widget of its own through `lcgf_render.gpu`, WebGPU's object model,
   with full control of what happens inside that rectangle.
2. That drawing and the widgets around it are drawn independently: neither redraws the other.
3. Which back end draws the widgets (software or a GPU API) is not in application code. A
   build option chooses (`-Drender=`), and `LCGF_RENDER=sw` overrides at run time.

## The contract

`lcgf_app` owns the shell, the device, the swapchain, the fonts and the pacing. An application
gives it `build`, and `draw` if it has surfaces.

| What changed | What runs | What must not run |
|---|---|---|
| A widget (`needsFrame`) | `build`, layout, paint; the window's picture is drawn again inside `DrawList.damage` | the application's `draw` |
| A surface (`Surface.redraw`, or its size) | the application's `draw`; the picture is drawn again inside that surface's rectangle | `build`, layout, paint, any upload of UI rows |
| A canvas's camera or palette (`lcgf_app.Canvas.redraw`) | the canvas's uniforms and dirtied rows written; the picture drawn again inside the canvas node's rectangle from the kept list | `build`, layout, paint, any upload of UI rows, the application's `draw` |
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

- `-Drender=sw` has no `gpu` (a compile error that says so); a `Surface` and a `draw` there
  compile, and the surface is never live.
- A GPU build that opens no device falls back to software, an application with `draw` too:
  `draw` is never called and `Surface.live` is false, so `build` can show something else.
- `LCGF_RENDER=sw` forces the fallback.

**Inline drawing stays below the window layer.** `Frame.custom` with `drawUntilCustom`
(`docs/guide/custom.md`) draws straight into the UI's pass with no copy, for a host that owns
its loop. `Frame.canvas` is unchanged: LCGF's own batch, drawn inline, damaged by its node.
`lcgf_app.Canvas` wraps it for the window: its camera and palette change with no `build` on the
GPU window (a software window builds a frame for them).

## Stages

Every stage ends with `zig build test fmt lint`, `ci/run.sh census-src` and `ci/run.sh docs`
passing, and the job named in its row. `docs` compares `docs/api/API.md` with the index
`zig build docs` generates, so a commit that changes a public declaration regenerates it.

Stages 0 to 6, and from stage 7 the composed page and canvas labels through `lcgf_app`, are on
`main` ("Landed", below). What is open:

| # | Work | Done when |
|---|---|---|
| 7 | Every example runs through `lcgf_app` with the default back end: the standalone projects (`buildDesktopExample` builds them with `-Drender=sw`, on `src/example/host.zig` and `src/example/window.zig`), and `dashboard`, `viewport` and `texture` drawing through `render_sw` types. The example host (`src/example/host.zig`, its `Incremental`, and `src/example/window.zig`) is then deleted, once Schemify confirms the `lcgf_app` path. | Nothing imports the deleted files; no example names a back end. |
| 8 | Win32 with Direct3D 12; the picture on Metal; the GPU on Wayland (the shell has no libwayland, so a Vulkan surface cannot be made over it: dmabuf buffers on the shell's own connection); GL ES; the web. | |

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

## Landed (on `main`)

| What | Commits |
|---|---|
| 0: the HTML and CSS front end, the C ABI and the C++ and Rust bindings removed; the comptime page and compose commits that waited with them | 3d34ccab, 93d852d5, d4c11b3a, 7660397f, 7ee7af5f |
| 1: the software window. The shells' `presentWith(out, glyphs, images)`; a text run that overflows its node damages where its glyphs reach; `lcgf_app` turns damage on and takes `App.images`; a composed page carries the union of both sides' damage (`ComptimeUi.recordDamage`) | cf48077d, 642d05ca, e97e7648, 367ce9a4 |
| 2: the Vulkan window keeps its picture. A Vulkan surface over an X window; `Context.trackDamageWhole`; `vk.setup.Window.begin` and `present`, rows kept on the GPU; a window that is not shown gives its frame up (`error.NotShown`); canvases cut to the damage rect | 596c14b9, 524a03b1, b6affe8e, c1edb04b, 01522df2 |
| 3: `lcgf_app` on the GPU: X11 with Vulkan, `Surface`, `draw`, images, the fallback and `LCGF_RENDER`; `examples/surface`; docs/guide/surface.md | c1d2a006, 71cae28e |
| 4: the text service (src/app/text.zig): the application's fonts, else system faces, else the bitmap font, at the window's scale, runs kept across frames; wired into `lcgf_app` | 758e1ca6, 1870469e, 8a089b59, fa7716b9, 2fa81980, c2b5bd89, 644d4791 |
| 5: canvas labels over a distance atlas (src/app/labels.zig, `bit.distance`), chosen by bench/micro/canvastext.zig; golden `labels` at camera scales 0.5 to 8 | 9a067b4b, 40cf51f2, 3b22a4c4, 9d1c1fa0 |
| 6: X11 pacing at RandR's refresh rate; scale tests on Wayland and the web; goldens at scale 2 (tools/golden/ref/draw-2x); also `Connection.overrideScale` and the screen's size from RandR | 612c4550, 9265b3e1, 79faee36, ea96b956, 69f50853, 5abf1b7f, 25f7ffc3, 9b062620 |
| 7, in part: `lcgf_app.Image.alpha`; an App draws its frame inside a page of its own (`page`, `compose`); `lcgf_app` registered for dependent packages, examples/app a package that calls `addApp`; canvas labels in the window's fonts (`labels: lcgf_app.Labels`, `Options.labels`), also in a composed page; `Options.canvas` sizes the GPU window's canvas rows | 85b08b30, 4480c11e, 5773d30d, 08dd77ba, 8be9626b, 690417b1, b217a16d |
| No GPU is a state (`Surface.live()`, no `error.NoGpu`; `Surface` and `GpuFrame` on every build), an unreachable X server takes the software path, a `custom` node is said once in a debug build; a new image generation redraws only the nodes that show it (`damage.addTextures`); bitmap canvas glyphs on both windows; a floating `.fill` region is a compile error; the general canvas row | 29fdabaa, 2143e029, 5bef6afd, 748cbcbc, 5e30337b, af5e8e85, 6b35cc75 |

Measured on main 71cae28e, ReleaseFast, calling-thread CPU time per frame, 300 frames a mode:

- llvmpipe on Xvfb, `LCGF_APP_GPU_BENCH`, a 2560 x 1440 window of 32 x 24 bordered cells under
  an 800 x 600 surface: a surface frame 53 µs (3.9 ms wall), 0 builds; a widget frame 192 µs
  (2.9 ms wall), 0 draws; an idle second 0 frames, 33 µs.
- NVIDIA GeForce RTX 5060 (driver 595), X11 through Xwayland on a 2560 x 1440 display at
  59.91 Hz. Through `lcgf_app` (`zig build app-test` with `LCGF_APP_GPU_BENCH`, 768 bordered
  cells under an 800 x 600 surface): a surface frame 255 µs, 0 builds; a widget frame (one cell
  changes) 362 µs, 0 surface draws; an idle second 0 frames; 16.35 ms wall a frame, the
  display's refresh (FIFO); 20 tests passed, 1 skipped. At the Vulkan window alone (`zig build
  x11-gpu` with `LCGF_X11_GPU_BENCH`, 768 quads): the old whole redraw into the swapchain image
  150 µs; a whole redraw into the picture 140 µs; no new list and nothing damaged 127 µs; no
  new list with a 400 x 300 rect damaged 161 µs; one small damage rect with a new list 175 µs,
  plus 122 µs for its build, layout and paint; 5 tests passed.

On that driver a presented frame costs about 130 µs of submit and present whatever is drawn,
so the kept picture does not lower the CPU time of a presented frame. What it saves is the
build, layout and paint a surface frame no longer runs, and the `draw` a widget frame no longer
calls. GPU time was not measured.
