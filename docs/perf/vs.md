# LCGR beside other GUI libraries

The six scenes of `bench/scenes/` (form, list, text, springs, resize, idle) ported to each framework
under `bench/vs/<name>/`, and measured with the same probes: frame time over 3,000 frames,
resident memory and idle wake-ups from `tools/bench/probe.py`, and loaded bytes (text + rodata +
data) from `tools/bench/size.zig`. `bench/vs/measure.py` runs it all; `ci/jobs/vs-<name>.sh` runs it
for one framework beside the LCGR row (`nix develop -c ci/run.sh vs-clay`). No job is in `all`.

Every number here is from one machine (32 CPUs, Linux, no GPU used) and the medians of 5 runs; the
1-minute load average during the run is given with each table. Timings never compare across
machines, and differ by tens of percent between runs on a machine shared with other builds.

## What a frame is in each harness

| Row | Frame timed | Text | Notes |
|---|---|---|---|
| LCGR | `tools/bench/bench.zig`: begin + hit test, build, layout, paint into the draw list | monospace measure (0.6 em per byte), text runs are not split into glyphs | the reference row |
| Clay 0.14 | `Clay_BeginLayout`, declarations, `Clay_EndLayout` (layout and render commands) | the same monospace measure, word wrap by Clay | Clay has no widgets or animation: they are built from elements, springs are the prototype's step |
| Dear ImGui 1.93.0 | input, `NewFrame`, ImGui's own widgets, `Render` (vertex and index buffers), null back end | default font (ProggyClean) at 14 and 20 px, every glyph laid out into vertices | springs are the prototype's step (no animation API) |
| egui 0.37.0 | `Context::run_ui` (input, egui's own widgets, layout, shapes) and `Context::tessellate` (meshes), no eframe, no window | default fonts at 14 and 20 px, every glyph tessellated into vertices | springs are the prototype's step (egui's animation helpers are tweens) |
| Iced 0.14.0 | `view`, `UserInterface::build` (diff against the widget tree, layout), `update` with the frame's event, `draw` into the tiny-skia renderer's layers (no rasterisation until `present`); no window | cosmic-text shaping with Iced's embedded Fira Sans, 14 and 20 px, layouts cached in the widget tree | springs are the prototype's step |
| Slint 1.18.1 | retained, lazy bindings: components made once; per frame the property changes (pointer event, ListView `content-y`, bar widths, window size), then `draw_if_needed` on a `MinimalSoftwareWindow`: bindings, layout and software redraw of the dirty region into a 32-bit buffer | system fonts, 14 and 20 px, rasterised | includes rasterisation; layout is evaluated lazily during rendering, so there is no layout-only time |
| Qt Quick 6.12.0 | retained, bindings and scene graph: QML made once; per frame the changes (mouse move, ListView `contentY`, bar widths, window size), then `grabWindow`: polish (layout), scene graph sync and render with the software back end into an image | system fonts, 14 and 20 px, rasterised | includes rasterisation; `grabWindow` renders every frame, so the idle row uses Qt's own render loop instead (frames swapped) |
| LVGL 9.6.0 | retained: objects made once; per frame the changes (pointer read, list rows recycled, bar widths, resolution), then `lv_refr_now`: layout and software redraw of the invalidated areas into a 32-bit partial buffer | Montserrat 14 and 20 px, rasterised | includes rasterisation; LVGL's own `layout` line (changes + `lv_obj_update_layout`) is given below |

None of these rows rasterises except LVGL, Slint and Qt Quick. Draw output per frame differs in kind (LCGR quads and
text runs, Clay render commands, ImGui and egui vertices, Iced layers), so the `out=` counts in the harness output are not comparable
across rows.

## Frame time (median / p99, microseconds)

Each column was measured in its own `ci/run.sh vs-<name>` run, beside an LCGR row of that run
(the LCGR medians of each run are in the next table: LCGR changed between runs as lanes merged,
springs most). The LCGR column here is from the Clay run. For LVGL and Slint the timings cover every
poll, and the idle row counts the polls that redrew anything; for egui and Iced it counts the frames an
eframe or iced_winit host would have run.

| Scene | LCGR | Clay | Dear ImGui | LVGL (layout only) | egui | Iced | Slint | Qt Quick |
|---|---|---|---|---|---|---|---|---|
| form | 16.7 / 19.6 | 28.0 / 39.3 | 15.8 / 23.2 | 0.9 / 1.2 (0.8) | 216.1 / 291.8 | 21.6 / 24.6 | 46.0 / 379.1 | 114.2 / 117.7 |
| list | 12.3 / 15.0 | 21.7 / 27.0 | 11.1 / 19.5 | 795.9 / 905.7 (421) | 242.3 / 259.1 | 212.4 / 311.9 | 2,216.6 / 2,551.7 | 203.5 / 208.5 |
| text | 17.6 / 20.2 | 29.8 / 33.1 | 89.9 / 164.4 | 1.0 / 1.9 (0.9) | 130.1 / 182.0 | 19.9 / 23.1 | 31.7 / 35.1 | 214.1 / 218.7 |
| springs | 219.8 / 226.5 | 112.3 / 161.4 | 52.8 / 90.4 | 3,248.9 / 3,386.0 (2,472) | 316.5 / 370.1 | 165.7 / 172.4 | 5,260.1 / 5,937.1 | 12,016.7 / 15,133.5 |
| resize | 17.6 / 26.1 | 29.4 / 36.7 | 92.9 / 151.8 | 1,970.1 / 3,514.8 (1,039) | 281.3 / 331.2 | 141.2 / 240.5 | 2,534.9 / 4,710.9 | 313.7 / 1,879.4 |
| idle: frames built of 3,000 polls | 2 | 3,000 | 3,000 | 1 | 3 | 1 | 1 | 2 |

LCGR frame medians (us) in each run, and the load average (1 minute, 32 CPUs) during it:

| Run | Load | form | list | text | springs | resize |
|---|---|---|---|---|---|---|
| vs-clay | 3.2 to 4.2 | 16.7 | 12.3 | 17.6 | 219.8 | 17.6 |
| vs-imgui | 4.5 to 5.0 | 14.8 | 11.2 | 16.4 | 201.2 | 16.4 |
| vs-lvgl | 4.4 to 5.2 | 14.4 | 11.1 | 16.5 | 200.1 | 16.4 |
| vs-egui | 3.3 to 3.9 | 16.8 | 12.8 | 17.8 | 76.3 | 17.9 |
| vs-iced | 4.5 to 5.3 | 16.9 | 12.8 | 17.7 | 75.5 | 17.7 |
| vs-slint | 3.1 to 6.4 | 16.9 | 12.8 | 17.7 | 74.5 | 17.9 |
| vs-qtquick | 2.3 to 3.2 | 16.8 | 12.8 | 17.9 | 74.3 | 19.2 |

## Memory, idle and size

LCGR from the Clay run; in the egui run it was 12,312 KiB resident and 269,459 + 11,785,924 bytes,
after the benchmark gained more columns.

| | LCGR | Clay | Dear ImGui | LVGL | egui | Iced | Slint | Qt Quick |
|---|---|---|---|---|---|---|---|---|
| Resident after one idle frame | 8,048 KiB | 2,096 KiB | 3,844 KiB | 3,540 KiB | 6,884 KiB | 6,024 KiB | 15,176 KiB | 70,440 KiB |
| Idle wake-ups per second | 0 | 0 | 0 | 30 | 0 | 0 | 0 | 0 |
| Loaded bytes (size build) + bss | 220,643 + 7,557,108 | 99,105 + 101,392 | 757,100 + 61,448 | 659,062 + 1,022,184 | 3,938,932 + 400 | 1,626,435 + 264 | 8,016,224 + 2,312 | 47,534 + 32,240, plus shared libraries |

The size build is ReleaseSmall for the Zig, C and C++ rows, cargo's `small` profile (opt-level s,
LTO, one codegen unit, panic abort, stripped) for the Rust rows, and `c++ -Os -s` for Qt Quick.
Every other row links its framework statically (and libc dynamically); Qt ships as shared
libraries, so its executable is only the harness: once idle it maps 107 shared libraries of
199,423,208 bytes on disk (`bench/vs/measure.py --libraries`), Qt's own and those it pulls in
(ICU with its data, libstdc++, fontconfig, FreeType, HarfBuzz, libc and more).

## What these numbers do and do not say

- The LCGR row is the benchmark tool itself: it carries two cores (the prototype builds the frame,
  the ported `src/` core lays it out and paints) and a static buffer for each, sized for 4,096 nodes.
  Its resident memory, bss and binary size are therefore upper bounds for LCGR, not its footprint;
  a real example program replaces them when one exists.
- Idle wake-ups: LCGR, Clay and Dear ImGui have no event loop of their own, so their harnesses
  block on stdin after the first frame, and zero is what any host that sleeps on input gets. The
  egui and Iced harnesses do the same: their wake-ups would come from eframe's or iced_winit's
  window loop, which needs a window this machine's CI cannot open. The row that says something is "frames built": LCGR's
  `Context.needsFrame` skips all but two of the 3,000 unchanged polls; egui asks for 3 frames
  (`repaint_delay` zero after the first two) and then none, Iced 1 (no redraw request after it); Clay and ImGui have no such query
  (ImGui leaves idling to the application), so the host must detect "nothing changed" itself or
  build every poll.
- Springs: Clay has no animation; the harness steps the 1,000 springs in plain C (as
  `bench/vs/harness.h` does for every framework without one), while LCGR's time includes its
  animation table (`Frame.animate`: a slot lookup per call and the stepped spring columns).
- Text: Clay word-wraps and caches word widths across frames; LCGR's monospace wrap is arithmetic.
  Neither shapes text or emits glyph quads. ImGui lays out real glyph advances and writes four
  vertices per glyph (12,984 vertices in the text scene), work LCGR leaves to its renderer: that is
  most of ImGui's text and resize time.
- LVGL is retained and redraws only what changed. In the form and text scenes the moving pointer
  changes no style (the default theme has no hover styles), so a poll costs about a microsecond and
  nothing is drawn after the first frame. Where everything changes (list scrolled 997 px a frame,
  1,000 bar widths, a resize) it relayouts and re-rasterises the window, and its time is mostly
  software rendering plus a layout that alone takes 12 to 60 times LCGR's whole frame. Its idle
  host loop (`lv_timer_handler`, then sleep until the next timer) wakes 30 times a second for the
  display refresh and input read timers (LV_DEF_REFR_PERIOD 33 ms). Its bss is mostly the 1/10-screen
  draw buffer the harness gives it (952,320 bytes). Springs: 1,882 of 3,000 frames redrew; the rest had
  no bar width change after rounding to whole pixels.
- LVGL's list recycles 35 row objects and sets each one's text, position and background colour
  every frame (local style), as an LVGL list over 100,000 rows has to.
- Form: ImGui's text fields are `InputText` widgets; LCGR's form scene draws a bordered box with a
  label (no editing state), so ImGui does a little more there.
- Clay culls render commands outside the window (73 in the text scene); LCGR paints every node in
  the tree.
- egui shapes and tessellates real text (its default fonts, embedded in the binary: most of its
  3.9 MB) and rebuilds every widget with its hover and focus state each frame; its list re-lays out
  each "Row N" label, since the texts change as the list scrolls.
- Iced keeps state between its rebuilt views: each text widget's shaped paragraph lives in the
  widget tree and is reused while its content and bounds stay the same, which is why form and text
  cost about what LCGR's do. Where texts or sizes change every frame (the list's "Row N" labels, a
  resize re-wrapping every paragraph, 1,000 bar widths) it re-shapes or re-lays out, and the time
  goes up 7 to 10 times (resize against text, list against form). The list scrolls a `scrollable`
  over the visible rows between two spacers, moved by the `scroll_to` operation each frame.
- Slint, like LVGL, is retained and draws only dirty regions, and its idle loop is its own: run
  due timers, redraw if needed, sleep until the next timer or input. With nothing animating it has
  no timer, so it sleeps without waking (0 wake-ups). In the form scene the std-widgets' hover
  states redraw a widget in 756 of 3,000 polls (median 46 us, p99 379 us when one redraws); in the
  text scene nothing has a hover state, and a poll is the pointer event's hit test (32 us). Where
  everything moves (list, springs, resize) its time is software rendering of the whole window plus
  re-evaluating the bindings: setting 1,000 bar widths through a model notifies the repeater row by
  row. Its resident memory and binary include the system font database and the image and SVG
  decoders the std-widgets icons need (8.0 MB loaded).
- Qt Quick: form and text cost 0.1 to 0.2 ms a grab although `grabWindow` renders every frame,
  which suggests its software renderer repaints only the regions that changed (not verified in
  Qt's code); a resize re-polishes the layouts and repaints the window. Springs set a `list<real>` property of 1,000
  widths each frame, which re-evaluates the 1,000 JavaScript bindings that read it: most of its
  12 ms. Its idle loop (`exec`, with nothing animating and no cursor blinking) did not wake in the
  2 s window. Resident memory is mostly the shared libraries' pages and the QML engine.

## What could not be measured fairly here

- Idle wake-ups for egui and Iced: their event loops (eframe, iced_winit) need a window, and the
  harnesses run without one; the "frames built" row stands in for them.
- GPU paths: every row runs on the CPU. The GPU back ends (wgpu for egui, Iced and Slint, the RHI
  for Qt Quick, ImGui's and Clay's renderers) are not measured, and neither is LCGR's.
- The cost of drawing pixels for the immediate-mode rows and LCGR: their frames stop at the draw
  list, while LVGL, Slint and Qt Quick rasterise in theirs. The two groups compare within
  themselves; across groups only the scenes where little changes (form, text, idle) say much.
