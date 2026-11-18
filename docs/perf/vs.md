# LCGF beside other GUI libraries

Each default-branch run measures LCGF and eleven alternatives on the same Linux runner. The generated tables identify the measured revision and show all results, including ties and losses. [Latest CI comparison](https://github.com/OmarSiwy/LCGF/blob/benchmark-results/README.md) · [Raw data](https://github.com/OmarSiwy/LCGF/blob/benchmark-results/measurements.json)

CI samples each speed-build process immediately after its 3,000 timed polls. The harness flushes its result and waits on stdin while the collector reads `VmRSS` and `VmHWM` from the child’s `/proc/PID/status`. The workload memory table reports median end-of-scene and peak resident KiB across launches. The idle-startup probe uses a separate process after one frame.

Reproduce the suite from the repository root with `nix develop .#vs -c ci/run.sh gates-vs`. The job starts a private Xvfb display and runs five repetitions of 3,000 polls for form, list, text, springs, resize and idle. It separately measures process launch to first frame, idle and peak resident memory, idle wake-ups, executable sections, mapped shared libraries and three mapped-window resize operations. The local output is `zig-out/comparison/README.md` and `zig-out/comparison/measurements.json`. Pull requests retain the same report as a CI artifact. The historical tables below give measurements from earlier revisions.

LCGF, Clay, Nuklear and microui use static builds for cold startup and idle RSS. The active frame timings and mapped library counts use their speed builds. The size column uses separately optimized small executables. This lets readers distinguish touched pages, executable sections and the shared libraries a distributor may need to ship.

## What a frame is in each harness

| Row | Frame timed | Text | Notes |
|---|---|---|---|
| LCGF | `bench/vs/lcgf/main.zig`: harness.h's driver in Zig, a static binary without libc; every poll asks `Context.needsFrame`, then begin + hit test, build, layout, paint into the draw list when it says yes; list and springs build every poll | monospace measure (0.6 em per byte), text runs are not split into glyphs | the reference row |
| Clay 0.14 | `Clay_BeginLayout`, declarations, `Clay_EndLayout` (layout and render commands) | the same monospace measure, word wrap by Clay | Clay has no widgets or animation: they are built from elements, springs are the prototype's step |
| Dear ImGui 1.93.0 | input, `NewFrame`, ImGui's own widgets, `Render` (vertex and index buffers), null back end | default font (ProggyClean) at 14 and 20 px, every glyph laid out into vertices | springs are the prototype's step (no animation API) |
| egui 0.37.0 | `Context::run_ui` (input, egui's own widgets, layout, shapes) and `Context::tessellate` (meshes), no eframe, no window | default fonts at 14 and 20 px, every glyph tessellated into vertices | springs are the prototype's step (egui's animation helpers are tweens) |
| Iced 0.14.0 | `view`, `UserInterface::build` (diff against the widget tree, layout), `update` with the frame's event, `draw` into the tiny-skia renderer's layers (no rasterisation until `present`); no window | cosmic-text shaping with Iced's embedded Fira Sans, 14 and 20 px, layouts cached in the widget tree | springs are the prototype's step |
| Slint 1.18.1 | retained, lazy bindings: components made once; per frame the property changes (pointer event, ListView `content-y`, bar widths, window size), then `draw_if_needed` on a `MinimalSoftwareWindow`: bindings, layout and software redraw of the dirty region into a 32-bit buffer | system fonts, 14 and 20 px, rasterised | includes rasterisation; layout is evaluated lazily during rendering, so there is no layout-only time |
| Qt Quick 6.12.0 | retained, bindings and scene graph: QML made once; per frame the changes (mouse move, ListView `contentY`, bar widths, window size), then `grabWindow`: polish (layout), scene graph sync and render with the software back end into an image | system fonts, 14 and 20 px, rasterised | includes rasterisation; `grabWindow` renders every frame, so the idle row uses Qt's own render loop instead (frames swapped) |
| LVGL 9.6.0 | retained: objects made once; per frame the changes (pointer read, list rows recycled, bar widths, resolution), then `lv_refr_now`: layout and software redraw of the invalidated areas into a 32-bit partial buffer | Montserrat 14 and 20 px, rasterised | includes rasterisation; LVGL's own `layout` line (changes + `lv_obj_update_layout`) is given below |
| Nuklear 4.13.4 | Immediate-mode controls and layout, followed by traversal of the native command stream | host-supplied monospace advances | clips the list to the visible range |
| microui 2.02 | Immediate-mode controls, layout and traversal of its native command list | host-supplied monospace advances | uses fixed-height virtual rows |
| GTK 4 | Native retained controls, a virtualized `GtkListView`, GTK allocation and a GSK snapshot. Event dispatch can also paint | Pango and system fonts | changed pointer positions require an X11 round trip. Idle uses the GLib event loop |
| Qt Widgets | Native widgets, a virtualized `QListView`, layout and software paint into a pixmap | system fonts at 14 and 20 px | idle uses the native event loop |

The output counter records work in each adapter's own units. A draw command, a glyph mesh and a complete image represent different amounts of rendering. Use the pixel-verified window test below to compare presentation of the same image across all twelve frameworks.

## Historical eight-framework frame time (median / p99, microseconds)

Each column was measured in its own `ci/run.sh vs-<name>` run, beside an LCGF row of that run
(the LCGF medians of each run are in the next table: LCGF changed between runs as lanes merged,
springs most). The LCGF column here is from the Clay run. For LVGL and Slint the timings cover every
poll, and the idle row counts the polls that redrew anything; for egui and Iced it counts the frames an
eframe or iced_winit host would have run.

| Scene | LCGF | Clay | Dear ImGui | LVGL (layout only) | egui | Iced | Slint | Qt Quick |
|---|---|---|---|---|---|---|---|---|
| form | 16.7 / 19.6 | 28.0 / 39.3 | 15.8 / 23.2 | 0.9 / 1.2 (0.8) | 216.1 / 291.8 | 21.6 / 24.6 | 46.0 / 379.1 | 114.2 / 117.7 |
| list | 12.3 / 15.0 | 21.7 / 27.0 | 11.1 / 19.5 | 795.9 / 905.7 (421) | 242.3 / 259.1 | 212.4 / 311.9 | 2,216.6 / 2,551.7 | 203.5 / 208.5 |
| text | 17.6 / 20.2 | 29.8 / 33.1 | 89.9 / 164.4 | 1.0 / 1.9 (0.9) | 130.1 / 182.0 | 19.9 / 23.1 | 31.7 / 35.1 | 214.1 / 218.7 |
| springs | 219.8 / 226.5 | 112.3 / 161.4 | 52.8 / 90.4 | 3,248.9 / 3,386.0 (2,472) | 316.5 / 370.1 | 165.7 / 172.4 | 5,260.1 / 5,937.1 | 12,016.7 / 15,133.5 |
| resize | 17.6 / 26.1 | 29.4 / 36.7 | 92.9 / 151.8 | 1,970.1 / 3,514.8 (1,039) | 281.3 / 331.2 | 141.2 / 240.5 | 2,534.9 / 4,710.9 | 313.7 / 1,879.4 |
| idle: frames built of 3,000 polls | 2 | 3,000 | 3,000 | 1 | 3 | 1 | 1 | 2 |

LCGF frame medians (us) in each run, and the load average (1 minute, 32 CPUs) during it:

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

LCGF from the Clay run; in the egui run it was 12,312 KiB resident and 269,459 + 11,785,924 bytes,
after the benchmark gained more columns.

| | LCGF | Clay | Dear ImGui | LVGL | egui | Iced | Slint | Qt Quick |
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

- The LCGF row is the benchmark tool itself: it carries two cores (the prototype builds the frame,
  the ported `src/` core lays it out and paints) and a static buffer for each, sized for 4,096 nodes.
  Its resident memory, bss and binary size are therefore upper bounds for LCGF, not its footprint;
  a real example program replaces them when one exists.
- Idle wake-ups: LCGF, Clay and Dear ImGui have no event loop of their own, so their harnesses
  block on stdin after the first frame, and zero is what any host that sleeps on input gets. The
  egui and Iced harnesses do the same: their wake-ups would come from eframe's or iced_winit's
  window loop, which needs a window this machine's CI cannot open. The row that says something is "frames built": LCGF's
  `Context.needsFrame` skips all but two of the 3,000 unchanged polls; egui asks for 3 frames
  (`repaint_delay` zero after the first two) and then none, Iced 1 (no redraw request after it); Clay and ImGui have no such query
  (ImGui leaves idling to the application), so the host must detect "nothing changed" itself or
  build every poll.
- Springs: Clay has no animation; the harness steps the 1,000 springs in plain C (as
  `bench/vs/harness.h` does for every framework without one), while LCGF's time includes its
  animation table (`Frame.animate`: a slot lookup per call and the stepped spring columns).
- Text: Clay word-wraps and caches word widths across frames; LCGF's monospace wrap is arithmetic.
  Neither shapes text or emits glyph quads. ImGui lays out real glyph advances and writes four
  vertices per glyph (12,984 vertices in the text scene), work LCGF leaves to its renderer: that is
  most of ImGui's text and resize time.
- LVGL is retained and redraws only what changed. In the form and text scenes the moving pointer
  changes no style (the default theme has no hover styles), so a poll costs about a microsecond and
  nothing is drawn after the first frame. Where everything changes (list scrolled 997 px a frame,
  1,000 bar widths, a resize) it relayouts and re-rasterises the window, and its time is mostly
  software rendering plus a layout that alone takes 12 to 60 times LCGF's whole frame. Its idle
  host loop (`lv_timer_handler`, then sleep until the next timer) wakes 30 times a second for the
  display refresh and input read timers (LV_DEF_REFR_PERIOD 33 ms). Its bss is mostly the 1/10-screen
  draw buffer the harness gives it (952,320 bytes). Springs: 1,882 of 3,000 frames redrew; the rest had
  no bar width change after rounding to whole pixels.
- LVGL's list recycles 35 row objects and sets each one's text, position and background colour
  every frame (local style), as an LVGL list over 100,000 rows has to.
- Form: ImGui's text fields are `InputText` widgets; LCGF's form scene draws a bordered box with a
  label (no editing state), so ImGui does a little more there.
- Clay culls render commands outside the window (73 in the text scene); LCGF paints every node in
  the tree.
- egui shapes and tessellates real text (its default fonts, embedded in the binary: most of its
  3.9 MB) and rebuilds every widget with its hover and focus state each frame; its list re-lays out
  each "Row N" label, since the texts change as the list scrolls.
- Iced keeps state between its rebuilt views: each text widget's shaped paragraph lives in the
  widget tree and is reused while its content and bounds stay the same, which is why form and text
  cost about what LCGF's do. Where texts or sizes change every frame (the list's "Row N" labels, a
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

## Pointer moves that change nothing (form, text)

Until the perf-gaps branch the LCGF row built every poll, while LVGL, Slint and Qt Quick time
every poll and redraw only what changed. In form and text the only input is the pointer
moving: LVGL (no hover styles in its default theme) redrew nothing after the first frame and a
poll cost about a microsecond, against 16 to 18 us for an LCGF rebuild: the x22.6 and x17.9 of
the gates were that, not slower passes. `Frame.reuse` could not have applied: a reused subtree
still copies its rows, lays out what is not kept and paints every node, and no scene uses it.

`Context.needsFrame` now stamps the pointer position only while it is over a node that senses
the pointer, while a button is held, or when the app sets `Context.track_pointer` (the
inspector does while open); elsewhere a move stamps as "outside the window" and no frame is
built (`src/runtime/scheduler.zig`, `stamp`). Entering or leaving a sensing node builds the
hover frame and its settle frame. The harness asks needsFrame every poll, as a host does, and
times every poll (the `poll` line, which `measure.py` reads) as the other harnesses do. The
form builds 908 of 3,000 polls (the pointer is over a checkbox, slider or button, or just left
one), text 2 of 3,000. Rows, list and springs still build every poll: their state changes
outside `Input` (the per-pass benchmark's pointer, the scroll position, the spring targets).

## Resident memory and time to first frame

Two causes, found on the perf-gaps branch, made the LCGF row 12,104 KiB and 4.72 ms against
Clay's 2,140 KiB and 0.67 ms. First, the harness: `--idle` ran the untimed differential check
against the prototype core, which builds a whole prototype context (3.3 MB) beside LCGF's;
it now runs only in timed runs. Second, the library: `mem.Carver` cleared every column it
carved, so a context made every byte of its capacity resident (4.4 MB for 4,096 nodes) and
paid for clearing it before the first frame. Clay mallocs its arena (8,192 elements by default)
and touches only what it uses. `Carver.zeroed` / `Context.initZeroed` skip the clear for a
buffer that is zero already (the benchmark's static buffers), so only touched pages count.
Measured, pinned, at load 30 to 47 of 32 CPUs: resident 12,000 -> 8,932 (harness) -> 1,752 KiB
(Clay 2,140 in the same window); first frame 6.9 -> 5.2 -> 1.8 ms (Clay 1.0).

A third cause was the harness again: std's default 256 KB thread-local signal stack, which
start.zig clears before main (64 page faults per start). The benchmark sets
`std_options.signal_stack_size = null`. Pinned, 31 starts, load 4: first frame 2.90 ms before
the branch, 0.57 after the two fixes above, 0.47 without the signal stack (Clay 0.45);
resident 1,624 KiB (Clay 2,076).

## Springs and list against Dear ImGui (not met)

Quiet run (load 5, pinned, `measure.py --runs 3`): springs 75.4 us against ImGui's 57.0 (x1.32),
list 12.2 against 11.9 (x1.03, inside the run-to-run spread; x1.13 in the gates run). Both
harnesses build every frame of these scenes, so the comparison is fair as it stands. The
springs frame splits into build 30 us, layout 33 us and paint 13 us (1,042 nodes). The profile
is flat: `Tree.push` 26% (about 20 ns a node, store-bound over its columns, as
docs/perf/port-perf.md found), `paint.emit` 16%, the scene's `animate` calls and styles 15%,
`levels.resolve` 13%, `fitSpan` 10%, `place` 7%. No function has a hotspot to remove. ImGui
puts each bar at its cursor in one pass and writes four vertices; LCGF runs the eight-pass flex
layout over every node and paints from the laid-out columns. Closing x1.32 needs fewer
passes or fewer columns written per node, which is a layout and tree design change, not a fix
in this branch.

## The LCGF row's harness, and capacity

Until the perf-gaps branch the LCGF row was the per-pass benchmark (`tools/bench`): it carried
the prototype core, the differential check against it, static buffers for 4,096 nodes and
std's formatting, so its size (280 KB loaded, 11.8 MB bss) said little about LCGF.
`bench/vs/lcgf/main.zig` now does what the Clay harness does and nothing else: harness.h's
driver, LCGF's frame, its context in a mapped buffer as Clay's arena is malloced.

Fair in both directions, two more changes:

- Capacity per scene (harness.h `vs_capacity`): every harness that sizes its tables does so
  for the scene, LCGF's node count rounded up to a power of two, at least 256 (Clay's max
  element count, LCGF's limits). A fixed capacity favours whichever library touches less of
  what it does not use: at 4,096 LCGF's first frame touches one page per column (684 KiB
  resident), at 256 it is 388 KiB; Clay moves less (448 -> 376 KiB, static).
- The LCGF row has no libc. Clay's resident memory and start-up are measured on
  `vs-clay-static`, built static against musl (`measure.py --startup`), so neither row pays for
  a dynamic C library; its frame times stay on the glibc build (musl's snprintf and memcpy made
  its text frame 31 -> 48 us), and its size on the dynamic build (libc not in its bytes).

## What could not be measured fairly here

- Idle wake-ups for egui and Iced: their event loops (eframe, iced_winit) need a window, and the
  harnesses run without one; the "frames built" row stands in for them.
- GPU paths: every row runs on the CPU. The GPU back ends (wgpu for egui, Iced and Slint, the RHI
  for Qt Quick, ImGui's and Clay's renderers) are not measured, and neither is LCGF's.
- The cost of drawing pixels for the immediate-mode rows and LCGF: their frames stop at the draw
  list, while LVGL, Slint and Qt Quick rasterise in theirs. The two groups compare within
  themselves; across groups only the scenes where little changes (form, text, idle) say much.

## Window resize latency

Run `nix develop .#vs -c bench/vs/window-resize/run.sh` on Linux. The same comparison
runs in `ci/run.sh gates-vs`. It opens one mapped window at a time on a private 24-bit
Xvfb display. LCGF uses the X11 host and software renderer shared by its desktop examples.
Every framework lays out the same centered 64 × 64 rectangle. The background changes
with window width so stale rows and frames from the previous size are detectable.

Qt Quick uses XCB and its software scene graph. Qt Widgets paints its native widget backing store and GTK 4 paints its native drawing area with Cairo. Clay, Nuklear and microui emit rectangle commands, and ImGui and egui emit meshes. Their hosts rasterize the output with Cairo. LVGL, Iced and Slint use their own software rasterizers. These eight clients share an Xlib image uploader. Consequently the numbers include each configured renderer and
presentation path. An application using a different backend can have different latency.

The observer times an X11 resize request through completion of the first server-side
snapshot whose RGB values match the requested geometry at **every pixel**. Clients with a 32-bit ARGB visual must also present opaque alpha at every pixel. A corner
probe avoids repeated full-size reads while the previous frame is showing.
Times include a server-side copy and synchronization round trip. The observer then reads
the frozen image and verifies it outside the timed interval. The raw JSON gives this
readback duration separately. This measures server-visible software presentation. Physical display scanout,
a desktop compositor and GPU swapchains are outside the measurement.

Each client completes 25 measured rounds in five blocks, with a warm-up at the start
of each block. The order of frameworks rotates between blocks. Each round includes:

- **Grow** from 800 × 600 to 2514 × 1420.
- **Shrink** from 2514 × 1420 to 900 × 676.
- **Drag-settle** from the last resize request to the correct 2514 × 1420 image, after
  five intermediate sizes sent roughly 8 ms apart. Intermediate frames may coalesce.

The table reports median and nearest-rank p95 milliseconds separately for each operation.
Missing, stale or partially painted frames fail the run after five seconds. The result
file is `zig-out/window-resize.json`. The existing `resize` scene above continues to
measure text reflow and frame construction. [Window fixtures and observer](../../bench/vs/window-resize)
