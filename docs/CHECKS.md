# Checks

Run these commands from the repository root. Nix supplies the pinned Zig and the tools each CI job uses. Sections 2 and 3 also retain the original prototype measurements on Zig 0.17.1 and x86-64 Linux. For comparisons, run both revisions on the same machine. [Archived prototype source](https://github.com/OmarSiwy/LCGF/tree/b6c1319/prototype)

## 1. Tests (the test matrix)

```sh
nix develop -c ci/run.sh debug
nix develop -c ci/run.sh release-safe
nix develop -c ci/run.sh release-fast
nix develop -c ci/run.sh cross
```

| Job | What it runs |
|---|---|
| `debug`, `release-safe`, `release-fast` | `zig build test` on the production package in each mode |
| `lanes-4`, `lanes-8` | the production tests at the lane count suggested by each CPU: `-Dcpu=x86_64` (SSE2, 4) and `-Dcpu=x86_64_v3` (AVX2, 8) |
| `lanes-2`, `lanes-16` | the root package's tests at a lane count no x86-64 CPU query gives, forced with `-Dlanes=N` |
| `cross` | `zig build test-build` for aarch64-linux, aarch64-macos, x86_64-windows, wasm32-wasi and riscv64-linux |
| `windows`, `macos` | what only that OS can show, on a GitHub runner of it (header `# runner: windows` or `# runner: macos`; outside `all`) |
| `app` | examples/app through `lcgf_app` (one call to a window): for a second on Xvfb and on a headless Weston, and compiled for x86_64-windows and aarch64-macos |

A job's header lines choose how it runs: `# shell: <name>` the Nix dev shell (`golden` has
wgpu-py on lavapipe, Xvfb, weston and Wine), `# all: no` leaves it out of `ci/run.sh all`, and
`# runner: windows|macos` the GitHub runner (default ubuntu).

## 2. Branch census

```sh
nix develop -c ci/run.sh census-src
```

The job builds `src/census_probes.zig` for `x86_64_v3`, disassembles the object with `objdump` and checks conditional jumps against `bench/census/baseline-src.json`. Backward jumps usually control loops. The table below records the original prototype census.

```
function      insns  jcc  back  fwd short-fwd   vec
p_push          181    0     0    0         0    74
p_response       32    0     0    0         0    10
p_step          241    7     2    5         1    87
p_wrap           67    2     1    1         0    36
p_measure        97    4     1    3         1    46
p_find           44    2     1    1         0    13
p_sweep         107    2     1    1         0    10
p_anim           90    2     1    1         0    61
p_paint         299    8     4    4         0    48
p_hit           145    4     1    3         1    68
p_finalize      151    4     2    2         0    63
p_place         150    3     1    2         0    53
p_resolve       134    3     1    2         0    59
p_fit           144    8     3    5         1    66
p_prepare        39    2     1    1         0    13
```

The four short forward jumps were read in the disassembly: three are the entry and remainder tests
the compiler adds around an unrolled loop (`p_measure`, `p_hit`, `p_fit`), and one is a select that
runs once per frame (`p_step`). None is inside a per-row loop. The gate is that this stays true: a
new short forward jump has to be looked at, and either removed or explained.

Bool-to-float conversions written as `@floatFromInt(@intFromBool(c))` were compiled to
compare-and-jump; `simd.b2f` avoids that with a bit pattern. Use the `simd` selects rather than
writing your own.

On Zig 0.18.0-dev.1151+8dfb7a7cc (the move from 0.17.1) LLVM turned two once-per-call selects
back into `test`/`je`. Both were removed by deleting the condition, not by masking it, since LLVM saw
through the masks:

- `push` (prototype and `src/core/tree.zig`): `nkids[parent] += fl * b01(i != 0)` became
  `nkids[parent] += fl; nkids[i] = 0;`. The root is its own parent, so clearing its own count after
  the increment removes the self-count; every other row has `parent < i`. 0 jumps.
- `hit.near`: the final `selU(any, top, none)` became a max over rows shifted by one
  (`none +% 1 == 0`), minus one. With no match the result is `none`. 2 jumps, both loop control.

`p_step` gained one remainder test after an unrolled vector loop (loop control).
Auto-vectorized loops add jumps that are all loop control: `p_anchor`'s subtree shift
(`for (pos[a][n..end[n]]) |*v| v.* += delta`) became a 32-wide, a 4-wide and a scalar loop with
trip-count dispatch between them, 12 -> 20 jcc, no jump on data. When the census flags an
auto-vectorized loop, check that every new jump compares a trip count, not a column value.

Two more ways around 0.18 re-branching a select, found by lane interaction: LLVM's CodeGenPrepare
turns a select into a branch around a load when one operand is a field loaded only for that
select (masks, `simd.selU`, `b2f` products and bit selects alike). An `if` whose body starts with
`@branchHint(.unpredictable)` marks the select `!unpredictable` and it stays a cmov (`pick` in
`src/interact/interaction.zig`). When even that fails, select the address and then load
(`step`'s id under the pointer: the real row or a constant zero id). The recorded disassembly showed no additional per-row jump. The production limits live in `bench/census/baseline-src.json`.

The selects are not enough on their own (found by lane simd, x86_64_v3). In a per-row loop where
one operand is loaded only for the select, `out[i] = simd.selU(c[i] > a[i], a[i], b[i])` compiles to
the same branches as a plain `if` (13 jumps, no cmov); with both operands already loaded for the
compare it is a cmov. Those branches span 0x36 bytes, past the census's 32-byte short-forward rule,
so they show only in the `jcc` column. The production gate checks the per-pass counts in `bench/census/baseline-src.json`. Prefer whole-vector selects (`@select` over `F`/`U`) in
batch loops.

Counts raised after the styling, perf, gpu-projection and software-renderer merges (every other
jump those merges added was removed). Each remaining jump was read in the disassembly:

- `p_finalize` jcc 3 -> 5, `p_damage_cull` 4 -> 5, `p_a11y_flatten` 7 -> 8,
  `p_merge_across_text` 12 -> 15: `geometry.transformRect`'s one test for the identity, per call
  site. The branch-free form computes the inverse and corners for every row: on the rows bench
  finalize took 7.4G instead of 3.2G instructions:u and `nodeBounds` 1.9G instead of 0.8G.
- `p_paint` jcc 14 -> 16, `p_paint_layered` 14 -> 17 (short_fwd 1 -> 0 in both):
  `geometry.nodeShown`'s test for a plain node (default extras row, no stock shadow), two long
  forward jumps per sweep to the out-of-line bounds. Without it paint computed every node's
  bounds again after finalize: on bench/vs/lcgf (x86_64_v3, 3,000 polls) springs took 889,817
  instead of 780,526 instructions a frame and list 161,722 instead of 146,834.
- `p_paint` jcc 16 -> 24, `p_paint_layered` 17 -> 25, `p_tree_push` and `p_tree_push_row`
  1 -> 2, `p_finalize` 4 -> 5, no short forward jump among them: the test for a node that has
  no extras row, its own or inherited, in each of the three passes. Such a node takes a short
  way (push stores its columns unmasked, finalize loads no matrix, paint writes its rect, its
  parent's clip and its look) and the others go through the rows as before; the jumps are long
  ones between the two. Without them every node paid for the rows: on bench/vs/lcgf
  (x86_64_v3, 3,000 polls) springs took 741,973 instead of 592,062 instructions a frame and
  list 141,503 instead of 102,181.
- `p_finalize` jcc 5 -> 14, back 2 -> 5, and the new `p_runs_place` (jcc 9, back 3), no
  short forward jump: the passes that take a run of siblings at a time (`layout/runs.zig`).
  Their jumps are the ends of a run and the choice between whole vectors and single rows, one
  set per run rather than per row; the rows of a whole vector have none. A run's parent is read
  once and its cursor stays in a register, where the row-by-row pass read the parent again and
  carried the cursor through memory for every child. On bench/vs/lcgf (x86_64_v3, 3,000
  polls) with both passes by runs, springs (rows of 25 bars) took 491,116 instead of 586,856
  instructions a frame and resize 137,663 instead of 156,938; list and form, whose runs are
  one to three rows, took 103,222 instead of 102,036 and 51,009 instead of 49,061.
- `p_fit` jcc 4 -> 5, `p_grid_fit` 14 -> 15, and the new `p_runs_fit` (jcc 11, back 2,
  short_fwd 2): `fit`'s fold by runs, the same trade. The pass calls `runs.fit`, one jump
  more in each caller. Of the two short forward jumps, one picks the copy of the row loop for
  a parent that stacks its children along the axis (a sum) or across it (a max), once per run:
  the optimizer hoisted the row-by-row pass's select out of the loop, which leaves 16
  instructions a row. The other is that loop's exit. Neither is a select on a row's value.
  With fit by runs as well, springs took 464,791 instead of 491,116 instructions a frame and
  resize 131,846 instead of 137,663; list 105,779 instead of 103,222 and form 52,807 instead
  of 51,009. Frame time on those two did not move: 9.8 and 9.8 us for list, 15.3 and 15.4 us
  for a built frame of form (pinned core, nine interleaved rounds).
- `p_finalize` jcc 14 -> 18, back 5 -> 6: one jump per frame on `Tree.wide`, with both forms
  of the clip loop behind it. `runs.survey` sets the flag when an eighth of the rows head a
  vector of siblings, and place, fit and finalize take a run at a time only then, so a tree of
  short runs no longer pays for the ends of its runs: list took 102,988 instead of 105,779
  instructions a frame and form 49,501 instead of 52,807, against 102,036 and 49,061 before
  any pass went by runs; springs took 468,970 and resize 132,514, the survey's own cost over
  464,791 and 131,846.
- `p_paint` jcc 24 -> 53, back 6 -> 8, short_fwd 0 -> 2; `p_paint_layered` 25 -> 23: sweep 1
  has a second form for a tree of long runs (`Tree.wide`, one jump per frame), so the count is
  of both. That form asks of a row from which it has not just failed whether the next vector
  of rows is plain siblings, and `plainQuads` then paints whole vectors with the parent's clip
  read once and nothing to test per row; `encode` takes a vector of quads with the batch's key
  as one compare. The two short forward jumps are that question's `and`, in the forms with
  and without text: they skip the test of the row's text and custom links when the row
  `lanes - 1` on has another parent. On bench/vs/lcgf (x86_64_v3, 3,000 polls) springs took
  421,638 instead of 468,970 instructions a frame; list 102,557 (102,988), form 49,411
  (49,501) and resize 133,859 (132,514), whose long runs are rows of text.
- `p_tree_push` jcc 2 -> 36, back 0 -> 4, short_fwd 0 -> 21; `p_tree_push_row` 2 -> 38,
  0 -> 6, 0 -> 21: `push` stores a lean field (`Template.lean`, twenty of the node fields)
  only when the node sets it off the default, in a row that `reset` has put back to the
  defaults. The probes push a style they know nothing about, so each of those fields is a test
  and a short jump over its store, and one more picks this form (a row pushed before, a tree
  that is not full). A style written where the node is made settles the tests when the call is
  compiled: the scene's bar keeps four of them, for its animated width. The stores were the
  build's cost, about one cycle each with the columns' lines to fetch: sampled cycles put 53%
  of the springs frame in the build, on the stores of defaults. A select of where to store
  compiled to 14 of the same jumps and more instructions. On bench/vs/lcgf (x86_64_v3, 3,000
  polls, pinned core, nine interleaved rounds) the median frame went 25.3 -> 22.0 us on
  springs, 6.6 -> 6.0 on list, 8.0 -> 7.3 on resize, and a built frame of form 10.0 -> 9.4;
  instructions a frame 406,217 -> 382,354, 102,948 -> 99,837, 127,638 -> 123,128 and
  49,593 -> 48,267, with the reset's fills of the lean columns counted.
- `p_paint` jcc 53 -> 59, short_fwd 2 -> 7; `p_paint_layered` 23 -> 27, short_fwd 0 -> 1:
  sweep 1 no longer writes the quad of a plain node with neither colour (a container, a text
  leaf: about half the nodes of a form or a list), where it wrote 136 bytes and left them
  behind, and `fade` returns an opaque node's colour without rounding it. Each is a short jump
  over the work, one per form of the sweep and per use of `fade`. On bench/vs/lcgf
  (x86_64_v3, 3,000 polls) list took 97,561 instead of 99,837 instructions a frame, resize
  115,996 instead of 123,128, form 47,408 instead of 48,267, and springs, every node of which
  is painted, 381,975 instead of 382,354; median frame 6.0 -> 5.9 us on list and 7.3 -> 7.0
  on resize.
- `p_hit_layered` jcc 2 -> 7, back 1 -> 2, short_fwd 0 -> 2: the once-per-call choice between the
  SIMD hit and `atExact` (transforms or rounded clips), and `needsExactHit`'s scan over the extras
  rows (bound and unroll remainder only). A select would run the exact walk on every query.
- `p_touch_step` jcc 4 -> 5, back 2 -> 3: the capture check's loop over the contact slots. A free
  slot searches 0 rows.
- `p_reuse` jcc 49 -> 51, back 19 -> 23: the paint-reference check before a copy and the rebase
  after it, two loops over the subtree's extras rows, each with a search over 0 rows unless the
  row references a node outside the subtree.
- `p_grid_resolve` jcc 11 -> 16, back 4 -> 5: a subgrid copies its parent's tracks instead of
  sizing its own, once per grid, and the copy loop's bound and alias checks. Running
  `sizeTracks` for every grid to drop the test still leaves the copy loop.
  Then 16 -> 17: on x, a `Decl.repeat` grid (`repeat(auto-fill/auto-fit)`, `columns: W`)
  counts its columns from its laid-out width, one test of `repeat_count` per grid. The work
  itself is out of line (`repeatColumns`); calling it for every grid to drop the test would
  cost a call per grid on every grid page.
- `p_flip` short_fwd 4 -> 5 and `p_damage_frame` back 7 -> 8: trip-count dispatch of an
  auto-vectorized loop and a loop-entry test placed before its loop; the sources are unchanged.

## 3. Benchmark

```sh
nix develop -c zig build bench
nix develop -c zig build bench -- --scene springs --counters
```

The Linux benchmark reports median and p99 per pass. The default rows scene builds 3,961 nodes and 1,320 text runs per frame for 3,000 frames. Use `--scene` to select form, list, text, springs, resize or idle. The following numbers came from two runs of the original prototype on the same 2.1 GHz Xeon VM core with eight SIMD lanes.

| Pass | Run A (median) | Run B (median) |
|---|---|---|
| begin + hit | 1.7 µs | 2.5 µs |
| build | 142 µs | 192 µs |
| layout | 163 µs | 225 µs |
| paint | 31 µs | 43 µs |
| whole frame | about 0.34 ms | about 0.46 ms |

The production benchmark also reports individual layout passes and polling time. The rows scene adds incremental layout, flex and grid measurements.

## 4. GPU pixel check

```sh
nix develop .#golden -c ci/run.sh golden
```

`tools/golden/dump.zig` builds the toolbar and custom viewport with the production runtime. Mesa lavapipe renders the dumped draw commands, including the host pipeline for the custom viewport. The job checks individual pixels and compares the entire frame with `tools/golden/reference.png`, the image from the original fixture.

### lcgf_render.gpu

```sh
nix develop .#golden -c ci/run.sh gpu-zero-cost
nix develop .#golden -c ci/run.sh vk
nix develop .#golden -c ci/run.sh gles
nix develop .#golden -c ci/run.sh web
zig build custom-draw-probe -Doptimize=ReleaseFast
sh docs/research/custom-webgpu/validate.sh zig-out/bin/custom-draw-projection
```

- **`gpu-zero-cost`.** Builds `src/render/vk/gpu_probe.zig` in ReleaseFast. It contains the same custom draw written in raw Vulkan and through the projection, and the job requires identical instructions in both.
- **Per back end.** Each back end's tests run `src/render/gpu/check.zig` on a real device:
  - upload through staging;
  - render to a texture and sample it;
  - vertex buffers;
  - a compute pass.

  The render conformance scene's custom draw goes through the projection everywhere, so the goldens cover it too. The web job runs the checks in Chromium (`test_gpu.html`).

  At 4× MSAA, lavapipe's scissor test passes 2 of 4 samples in the row and column just outside a scissor's top and left edges (a quarter in the corner). That is the rasterizer's sample placement, not the projection: the scissor recorded at 1× and 4× is the same. So multisampled comparisons allow exactly that ring, and nothing else: `pixelsOffMultisampled` in `src/render/vk/scenes.zig` accepts a pixel there only if it is the expected blend of inside and outside colours, and `tools/golden/golden.py --scissor-ring x0,y0,x1,y1` does the same for the wgpu goldens (`ci/jobs/wgpu.sh` passes `8,8,152,112` for `custom.png`). Every other pixel must still match.
- **Custom-draw probe.** Times a redrawn custom node against the native-only build (`docs/research/custom-webgpu/measure.py`). Under validation it compares every composed frame with reference images, and a control run omits the layout hand-off to show the validation layer is active.

### C++ and Rust bindings

```sh
nix develop .#vs -c ci/run.sh bindings
```

The job installs `zig build abi -Dwgpu-native=v29` into `zig-out`, a prefix with `liblcgf`, `lcgf.h`, `lcgf-gen`, the C++ headers, the CMake package and wgpu-native. CMake then builds the C++ checks and cargo builds the Rust crates against that prefix alone. `bindings/check/run.sh`:

- replays 1,086 frames of pointer and Tab input over a toolbar (`.zon`), a mixer (the `ui!` DSL) and a panel with regions, a custom draw node and a spring, four ways: Zig's `ComptimeUi`, Zig through the seam, C++ and Rust. Draw lists and events must be byte-identical, and every widget must receive an event;
- makes resources, two pipelines (with their MSL) and one frame through the Zig Metal projection, `lcgf/gpu.hpp` with `LCGF_GPU_METAL` and `lcgf::gpu` with `metal`, against a stand-in Objective-C runtime that logs every message (`bindings/check/objc_record.c`). The three logs must be equal; the C++ Metal checks must compile for aarch64-macos with `-Werror`;
- makes the same resources, pipelines and frame through the Zig D3D12 projection, `lcgf/gpu.hpp` with `LCGF_GPU_D3D12` and `lcgf::gpu` with `d3d12`, on a recording Direct3D 12 over DirectX-Headers (`bindings/check/d3d12_record.c`) that logs every field of every struct, HLSL and root signatures included. The three logs must be equal; the C++ check must compile for x86_64-windows-gnu with `-Werror`;
- draws the comptime examples (mixer, card, settings, badge, dash, todo, feed, sized controls, palette, with patched colours, and meter, with formatted labels of every argument kind) through Zig's comptime pipeline (`ct_layout`, `ct_paint`, `ct_events`; `bindings/check/ct_dump.zig`), and their `.zon` (`src/abi/testdata/static/`) through `lcgf-gen --static` into C++ (each UI's frame built three ways: by `zig build-obj`, and without Zig from C by clang and by gcc) and Rust (the same three ways, by `lcgf_build::static_ui`), 240 frames of changing viewports, label text, list counts, conditions, choices and scroll offsets, with pointer and Tab input. The draw lists, and the events and focus, must be byte-identical;
- replays partial updates on mixer, dash, todo, palette and meter (where every field is a format's argument) (`ct_dump partial`; `ct_check partial` in C++ and Rust): every fourth frame a full frame, two in four one label's field changed and laid out again with `relayout`, one in four the colour fields changed and `patch`ed. The draw lists and each frame's dirty quads must be byte-identical to Zig's `Layout.relayout` and `Paint.Patches`;
- runs the three UIs, three of the static UIs and three runtime scenes from C++ and Rust linked against `liblcgf_auto.a`, with `LCGF_FORCE_LANES` at 4, 8 and 16 in turn (widths the CPU cannot run are skipped). Every width must make Zig's frames, and the width that ran must be the one forced;
- makes the rows of 4,096 styles in Zig, through `lcgf_template_from`, with C++'s `lcgf::Row` and with Rust's `Row::from`. They must be equal word for word;
- builds bench/scenes' six scenes, and the gate's `kit` scene (formatted text written in place, the widgets by options, springs on a colour and an array, a tween), through the runtime front end in Zig, C++ (`lcgf/runtime.hpp`) and Rust (`lcgf::runtime`), 120 frames each with presses, and whether each frame was needed. Two scenes run again with 40 nodes and a stack of 3, so the rows C++ and Rust push inline overflow. The outputs must be byte-identical;
- records one GPU frame through `lcgf_render.gpu`, `lcgf/gpu.hpp` and `lcgf::gpu` into `bindings/check/record.c`, which logs every Vulkan call with each argument and struct field. The three logs must be equal;
- runs check.zig's GPU checks (`bindings/cpp/check/gpu_checks.hpp`, `bindings/rust/lcgf-check/src/gpu_checks.rs`) in C++ and Rust on Vulkan (lavapipe), GL ES 3.1 (llvmpipe through EGL) and wgpu-native, with pipelines and bind groups made from the repository's WGSL. The Rust `webgpu.h` declarations must have the C header's sizes and field offsets (`bindings/check/wgpu_layout.c`).

Frame times for each language are printed but not judged (`ci/run.sh vs-lcgf-bindings` measures the C++ and Rust harnesses beside the Zig one). `zig build test` covers the rest:

- the tables `lcgf-gen` writes must equal Zig's comptime tables word for word, static UIs' included (`src/abi/zon.zig`);
- the tier-0 passes take min and max as selects (`simd.maxF`, `simd.minF`), so a tie or NaN gives the same bits on every target and in the C++ and Rust ports; the widget and draw goldens did not move when they changed;
- the static engine's frames must equal `ct_layout` and `ct_paint`'s over the examples, bench scenes (folds, batch sorting, clips) and painted regions beside a fold, and its templates and constant columns theirs (`src/abi/ct.zig`). `ct_layout.Layout` and `ct_paint.Paint` make their tables with the same functions (`src/comptime/tables.zig`), and `ct-sizes`, `ct-rodata` and the two ct benches did not move when they started to;
- the seam must match `ComptimeUi` over the reference replay and the panel (`src/abi/seam.zig`);
- the runtime front end's C calls must keep the input alive through the frame and skip unchanged frames (`src/abi/api.zig`);
- lcgf-gen's run-time GLSL binding patch must equal the comptime one (`src/render/gpu/naga.zig`).

## 5. API index

```sh
nix develop -c ci/run.sh docs
```

`zig build docs` writes the public declarations exported by `src/lcgf.zig` to `zig-out/docs/API.md`. CI compares the result with the checked-in `docs/api/API.md` and verifies the guide examples.

## 6. Compiler facts

```
python3 ci/zigcheck.py
```

70 small cases behind `docs/ZIG_0_17_1.md`. All agree on 0.17.1 and on 0.18.0-dev.1151+8dfb7a7cc (after the `bitpack` rename).
