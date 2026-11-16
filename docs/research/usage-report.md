# Usage report: peaks per limit, what the buffer holds, and what to give it

Research for the approved feature: the runtime front end cannot infer its buffer size (the tree is
whatever the app builds), so `Context` records the peak demand of every `Limits` field and the
shell prints a report when `run` returns. It answers the six questions of the brief with
measurements on this machine and primary sources, and ends with a design the implementing agent
can follow.

Every claim carries one tag:

- **[M]** measured here, with the command and load in "Method";
- **[S]** read in source, `file:line` in this checkout (3aa2f9d) or at the commit given in "Sources";
- **[I]** inferred from the two above, with the reasoning given.

## Answers in brief

1. **Prior art.** Nobody reports demand past a fixed capacity. Clay sizes its arena from the
   limits (`Clay_MinMemorySize`) and calls an error handler once, naming the setter to raise, but
   its default handler does nothing [S]. LVGL, FreeRTOS, Zephyr and jemalloc keep a high-water
   mark (peak used) and show it as `used / total (pct)` [S]. Unreal's LLM tags every allocation so
   the categories sum to the total [S]. The useful shape: one line per capacity, `peak / given
   (pct)`, plus the knob to turn. That is what the design below prints, with one addition no
   prior art has: the count past the limit.
2. **Cost.** Turning each table's `overflow` bool into a `lost` counter adds 2 instructions to
   `Tree.pushRow` (`xor`, `add` to memory) and no conditional jump anywhere: the census of all
   117 probes has the same `jcc` counts, and `--baseline tools/census/baseline-src.json` passes
   [M]. Building the 3,961-node bench tree, two copies of lcgr interleaved in one process: +0.0 to
   +0.6 us on 108 us (at most 0.5%), inside the noise at load 14 [M]. The per-frame fold is one
   16-lane max, compare and select.
3. **Attribution.** Exact and automatic: run `Context.build` with a counting carver and record
   `carver.off` after each part. The parts sum to `requiredBytes` by construction (checked: 15
   parts sum to 4,118,144 at default `Limits`, 1,161,344 at the example's) [M]. Inside the tree,
   per-column bytes from `@typeInfo(Tree.Columns)` times `rows(cap)`, padded as the carver pads,
   sum to what `Tree.init` carves (1,134,720 + 460,544 = 1,595,264) [M].
4. **Debug against ReleaseFast.** `requiredBytes` and `@sizeOf(Context)` are the same in all four
   modes (4,118,144 and 4,112 bytes); only the lane count changes them (4 lanes: 4,116,096; 8:
   4,118,144; 16: 4,122,752), and that comes from the target, not the mode [M]. What does differ:
   a static buffer declared `= undefined` is 0xAA-filled `.data` in Debug and `.bss` in release
   builds, so in Debug it is in the file, resident once touched, and **not zero**, which breaks
   `Context.initZeroed`'s precondition [M]. Peaks are the app's data and do not depend on the mode.
5. **Margin and rounding.** No margin: the owner decided the suggestion is the peak itself
   (the research had proposed 1.25x; see section 5). Rounding up to whole SIMD rows
   is free for every table carved with `simd.rows`, but not for the draw list (`n + 1` rows of
   136-byte quads) or the tree's extras (`rows(cap + 1)`): at 8 lanes, rounding nodes up to the
   next multiple of 8 costs at most about 3 KB [M].
6. **Edge cases.** Peaks are a lower bound (only frames that ran), and after a limit is hit they
   are the demand of the degraded frame, which can be lower than the real one [M]. The comptime
   front end has nothing to report at run time. Each `Context` reports its own table. On a
   microcontroller, `std.debug.print` does not compile for `freestanding` [M], so the print is
   gated at compile time and a shell may supply its own sink.

7. **Quiet by default (owner's later decision).** `-Dlcgr-usage=never` is the default. Keep the
   recording compiled in and gate only the printing: compiling it out saves one instruction per
   push, a per-frame fold below the noise, 770 bytes of ReleaseSmall code and 200 bytes of
   `Context`, and costs `ctx.usage()` in some builds plus a build-option branch in every tier-0
   table [M]. See "Decision change".

**Found on the way** (each is a separate fix, not part of this feature):

- **A limit hit can crash the frame.** The shell example at `.{ .nodes = 8 }` panics in Debug
  with "index out of bounds: index 17, len 16" at `src/layout/levels.zig:87` (`levels.build`
  from `Frame.end`, `src/runtime/frame.zig:241`) and segfaults in ReleaseFast [M]. `pushRow`
  rewrites the last row when full (`src/core/tree.zig:379`), so when the node open at that row
  gets a child, the child is written over it with `parent[i] == i`; `levels.build` then reads its
  own stale depth (`src/layout/levels.zig:76`) and indexes `start` past the end [I]. This breaks
  the contract "running out is reported, never fatal" (`src/runtime/context.zig:27`). Fix once,
  in `pushRow`: `c.parent[i] = @min(parent, i -| 1)` keeps every parent before its row.
- **Six limits are silent today.** `Status` (`src/runtime/context.zig:51-62`) covers nodes,
  texts, customs, strings and depth; running out of anims, tweens, flips, signals, timers or
  memos sets nothing anywhere [S]. The design below reports all eleven.
- **`docs/perf/bytes.md` is stale.** It says 874 bytes per node; the pinned test
  (`src/runtime/context.zig:275`) and `docs/guide/perf.md:75` say 924, which is what measures [M].
- **The bench's buffers break `initZeroed` in Debug.** `tools/bench/bench.zig:76,80` declare
  `= undefined` and `bench.zig:406` carves them with `initZeroed` [S]; correct only in release
  builds (see question 4). Declaring them `= @splat(0)` puts them in `.bss` in every mode [M].

## Method

Machine: i9-14900HX, 32 CPUs, Linux 7.0.10, Zig 0.18.0-dev.1151+8dfb7a7cc. Load average 13 to 17
throughout, above the brief's threshold of 8, so the only timing reported is a paired, in-process,
interleaved comparison pinned to CPU 8 (idle at the time, 0% over a 2 s `/proc/stat` sample);
separate-process runs were tried and moved by ±10% between runs, so they are not used [M].

The probes are in `docs/research/usage/`:

- `attr.zig`: bytes per part of `Context` by counting-carver deltas in `build`'s order, checked
  against `requiredBytes`; per-column bytes of `Tree.Columns` and `Tree.Extras`; `requiredBytes`
  for nodes 4,090 to 4,105. Built `-O Debug|ReleaseSafe|ReleaseFast|ReleaseSmall`, and with
  `lanes` 4 and 16.
- `prototype.diff`: the counting prototype against this checkout's `src/`: a `lost` counter in
  `Tree`, `Texts`, `Customs`, `Strings`, `Anims`, `Tweens`; an unclamped open-node counter and its
  peak in `Frame.open`/`close`; the fold in `Frame.finish`. Additive (it keeps `overflow`), so
  its cost is an upper bound on the design's.
- `pushab.zig`: `docs/perf/build/push.zig`'s `pushRow` scene against two copies of lcgr in one
  binary (this checkout and the patched copy), alternating rep by rep, 20,000 reps, 5 processes.
- `peak.zig`: the shell example (`src/shell/example.zig`) for 30 frames under several `Limits`,
  against the patched copy, printing peak, given, frames hit and the first.

Census: `src/census_probes.zig` built as `zig build census-src-obj` builds it (`-O ReleaseFast
-mcpu x86_64_v3`) from both trees, then `python3 tools/census/census.py OBJ` and `--baseline
tools/census/baseline-src.json`.

Resident memory: `tools/bench/bench.zig` built by hand with `zig build-exe` in each mode (the
build script fixes it at ReleaseFast), run under `python3 tools/bench/probe.py -- bench --idle`,
twice each.

## 1. Prior art

| Library | What it exposes | Format | Source |
|---|---|---|---|
| Clay | `Clay_MinMemorySize()` sizes the arena from the current limits; `Clay_SetMaxElementCount`, `Clay_SetMaxMeasureTextCacheWordCount`; an error handler called with `CLAY_ERROR_TYPE_ELEMENTS_CAPACITY_EXCEEDED` and similar | A sentence naming the setter: "Try using Clay_SetMaxElementCount() with a higher value." No count, no peak. | clay.h:933, 1021-1026, 883-897, 1702 [S] |
| Clay | The default handler is empty, and each capacity warning fires once per context (`booleanWarnings`) | Silent unless the app installs a handler | clay.h:1153-1155, 1699-1704 [S] |
| Clay | Issue #102: a fixed maximum is either too small for the long list or wastes memory the rest of the time; fixed by a runtime setter and an error hook | | github.com/nicbarker/clay/issues/102 [S] |
| Dear ImGui | Grows its buffers (no fixed capacity). Metrics window: vertices, indices, windows, current allocations; a ring of recent frames that allocated, to enforce "no allocations on idle/repeating frames" | `Frame %06d: %+3d ( %2d alloc, %2d free )` | imgui.cpp:5301, 17008-17009, 17389-17396 [S] |
| LVGL | `lv_mem_monitor_t`: `total_size`, `free_size`, `max_used` (high-water mark), `used_pct`, `frag_pct`; the system monitor overlay prints them | `%zu.%zu kB (%d%%)\n%zu.%zu kB max, %d%% frag.` | lv_mem.h:33-42, lv_sysmon.c:408-415, lv_mem_core_builtin.c:148 [S] |
| FreeRTOS | `uxTaskGetStackHighWaterMark`: "the minimum free stack space there has been ... since the task started" | A number, in words | task.h:1880-1889 [S] |
| Zephyr | Thread analyzer: per thread, stack unused, used, size and percentage, printed by the analyzer | `%-20s: STACK: unused %4zu usage %4zu / %4zu (%3zu %%)` | thread_analyzer.c:51-52 [S] |
| jemalloc | `thread.peak.read`: the maximum of allocated minus freed bytes since the last reset | A number | jemalloc.xml.in:1854-1868 [S] |
| Zig std | `ArenaAllocator.queryCapacity`; `reset(.retain_capacity)` keeps the largest use so later frames do not allocate; `.retain_with_limit` caps it | A number | lib/std/heap/ArenaAllocator.zig:68, 88-97 [S] |
| TigerBeetle | "All memory must be statically allocated at startup"; "Put a limit on everything" | Limits are configuration, checked by assertions; nothing to report at run time | docs/TIGER_STYLE.md:96, 151 [S] |
| Unreal LLM | Every allocation carries one tag, so "all memory is tracked once and only once"; `stat LLM`, `stat LLMFULL`; `-LLMCSV` writes per-tag MB every 5 s; overhead "can be 100MB or more"; compiled out of Shipping | Per-tag table, CSV | dev.epicgames.com, "Using the Low-Level Memory Tracker" [S] |

Frostbite: no primary source was found; nothing here relies on it.

What carries over [I]:

- **The high-water mark is the universal number.** LVGL, FreeRTOS, Zephyr, jemalloc and Zig's
  arena all keep the peak, not the current value, because the peak is what sizes a fixed
  capacity. Zephyr's `usage N / M (P %)` is the closest to what this feature needs.
- **Nobody counts past the limit.** Clay reports that it ran out, not by how much; the others
  measure memory that grows. A fixed table that keeps counting rejected pushes ("wanted N") is
  the new piece, and it costs one add (question 2).
- **Silence by default is what gets ignored.** Clay's default handler is empty and warns once;
  issue #102 is a user finding the cap the hard way. LCGR's `Output.status` has the same shape:
  data the host may never read. The owner first chose to print by default, then (see "Decision
  change") to stay quiet unless the build asks; with the report off, the widened `Status` and
  `ctx.usage()` are what a host has, so a shell or the inspector should surface them.
- **Name the knob.** Clay's messages name the setter. The report ends with a paste-ready
  `Limits` literal for the same reason.
- **Attribute exactly, or not at all.** LLM's rule (every byte in exactly one category, the
  categories sum to the total) is what makes its table trusted; with a carver it is free here
  (question 3), with none of LLM's overhead.

## 2. Cost

The four rules (`docs/DESIGN.md`): columns and `u32` indices, `@Vector` over padded columns, no
data-dependent branch in a per-row loop, caller-owned memory and control flow. Counting adds no
column, no branch and no memory beyond a few words in `Context`.

**Per push.** Each table already computes "full" for its `overflow` flag
(`src/core/tree.zig:380`, `src/core/texts.zig:54`, `src/core/customs.zig:40`,
`src/core/strings.zig:23`). Counting is one more add of that bool. `Tree.pushRow` before and
after the prototype [M]:

```
-  setae  %cl
-  or     %cl,0x40c(%rdi)
+  xor    %r9d,%r9d
+  setae  %r9b
+  or     %r9b,0x410(%rdi)
+  add    %r9d,0x408(%rdi)
```

Replacing `overflow` by `lost != 0` (the design) drops the `or`, so the net is one instruction.

**Census** (all probes, x86_64_v3, ReleaseFast) [M]:

| probe | insns before | after | jcc before | after |
|---|---|---|---|---|
| `p_tree_push_row` | 166 | 166 | 1 | 1 |
| `p_tree_push` | 284 | 288 | 1 | 1 |
| `p_reuse` | 1,830 | 1,834 | 49 | 49 |
| `p_flip` (calls `Anims.place` per row) | 507 | 524 | 30 | 30 |
| `p_anim`, `p_tween`, every other probe | same | same | same | same |

`census.py --baseline tools/census/baseline-src.json` exits 0 on both objects.

**Time.** `pushab.zig`, the 3,961-node scene, medians per frame over 20,000 interleaved reps,
five processes, pinned to CPU 8, load 14 [M]:

| run | before (us) | after (us) |
|---|---|---|
| 1 | 108.6 | 109.2 |
| 2 | 108.6 | 108.7 |
| 3 | 108.6 | 109.2 |
| 4 | 107.8 | 108.3 |
| 5 | 109.3 | 109.2 |

+0.0 to +0.6 us, at most 0.5%, about 0.15 ns per node. (The scene measures 68 us at load 4-5 in
`docs/perf/build.md`; the absolute numbers here are inflated by the load, the pairing is not.)

**Per frame.** One fold in `Frame.finish`: `peak = @max(peak, want)`, `over = want > given`,
`hits += over`, `first = select(over and first == 0, frame, first)` over a `@Vector(16, u32)` (11
limits, padded). About a dozen vector instructions, run once a frame; not measurable at this
load, and not attempted [I]. Per `open`, one add and one `@max` for the depth peak; per `close`,
one saturating subtract.

**Memory.** Three 64-byte vectors and two `u32` in `Context`, nothing in the buffer.

**Code size of the print.** On hosted targets the report goes through `std.debug.print`. In a
ReleaseSmall program that uses nothing else from `std.Io`, that pulls in about 113 KB of text
(967 bytes empty, 116,299 with one print loop); formatting into a fixed `std.Io.Writer` and one
`write(2)` costs 3,471 [M]. But an app with `pub fn main(init: std.process.Init)` already has the
`Io` runtime (128,589 bytes for a hello on `init.io`), and adding `std.debug.print` to it costs
185 more [M]. So the print costs nothing extra in a normal hosted app, and the shell hook below
lets a lean one route it elsewhere.

## 3. Attribution by part and by column

`Context.build` (`src/runtime/context.zig:158-178`) carves every part in a fixed order, and
`requiredBytes` (`:182-187`) runs it with a counting carver. Recording `carver.off` after each
part gives every part's bytes from the same code that carves them, so the report cannot drift
from the layout. Measured at 8 lanes [M]:

| part | limit | default `Limits` | example (1,024 nodes, 256 texts) |
|---|---|---|---|
| tree, generation 0 (with layout scratch) | nodes | 1,595,264 | 403,328 |
| tree, generation 1 (shares the scratch) | nodes | 1,397,888 | 353,408 |
| texts, two generations | texts | 79,104 | 20,736 |
| customs, two generations | customs | 2,432 | 2,432 |
| strings, two generations | strings | 131,072 | 131,072 |
| draw list | nodes, texts, customs | 781,888 | 199,744 |
| signals | signals | 2,176 | 2,176 |
| anims | anims | 8,704 | 8,704 |
| tweens | tweens | 6,336 | 6,336 |
| flips | flips | 1,920 | 1,920 |
| open-node stack | depth | 256 | 256 |
| timers | timers | 704 | 704 |
| memos | memos | 3,392 | 3,392 |
| level-order index | nodes | 65,792 | 16,640 |
| focus scopes | nodes | 41,216 | 10,496 |
| **sum = `requiredBytes`** | | **4,118,144** | **1,161,344** |

The layout scratch both generations share is the difference of the two tree rows: 197,376 bytes
at default `Limits` (12 columns of `rows(4096) = 4,104` f32, each padded to 64), 49,920 at the
example's [M].

**Inside a part.** A column set's bytes are, per field, `alignForward(rows * @sizeOf(T),
column_align)`, times `k` for a `[k][]T` field: exactly what `Carver.columns` carves
(`src/core/mem.zig:68-82`). Summed over `Tree.Columns` at `rows(cap)` and `Tree.Extras` at
`rows(cap + 1)` it equals `Tree.init`'s count: 1,134,720 + 460,544 = 1,595,264 [M]. So a group
breakdown (links, layout inputs, layout scratch, layout outputs, paint, semantics, which is the
a11y `role` and `value`) needs only a name-to-group table for `Tree.Columns`, checked at compile
time to cover every field exactly once. The group names exist only as comments today
(`src/core/tree.zig:215-280`); a comment cannot be read at comptime, so the table is the one new
piece of data, and the compile-time check is what keeps it from drifting [I].

**Per limit.** Every part but the draw list depends on one limit. The draw list carves `nodes +
1` quads, `texts + 1` runs, `customs + 1` custom draws and `nodes + texts + customs + 4` commands
(`src/draw/draw_list.zig:110-121`); it is reported as one part. The suggestion does not need a
split: it is `requiredBytes` of the suggested `Limits`, part by part.

## 4. What changes between Debug and ReleaseFast

| | Debug | ReleaseSafe | ReleaseFast | ReleaseSmall |
|---|---|---|---|---|
| `requiredBytes(.{})`, 8 lanes | 4,118,144 | 4,118,144 | 4,118,144 | 4,118,144 |
| `requiredBytes(example)` | 1,161,344 | 1,161,344 | 1,161,344 | 1,161,344 |
| bytes per node of capacity | 924 | 924 | 924 | 924 |
| `@sizeOf(Context)` | 4,112 | 4,112 | 4,112 | 4,112 |
| global `var b: [1 MiB]u8 = undefined` | `.data`, 0xAA | `.bss`, 0 | `.bss`, 0 | `.bss`, 0 |
| bench `--idle`: resident after one frame | 7,168 KiB | | 3,060 KiB | 2,612 KiB |
| bench: `.text` / `.data` / `.bss` | 3,255,046 / 15,945,736 / 16,488 | | 770,112 / 21,992 / 11,849,100 | 260,929 / 21,880 / 11,846,300 |

All [M]. The lane count, which comes from the target (`src/core/simd.zig:23`), changes
`requiredBytes(.{})`: 4,116,096 at 4 lanes, 4,118,144 at 8, 4,122,752 at 16 [M].

Plainly:

- **Does not change with the mode:** the buffer the limits need, every part's bytes, the
  struct sizes, and the peaks the app produces (they are the app's own tree, text and
  animations). A report from a Debug run is valid for a ReleaseFast build of the same target.
- **Changes with the target:** the lane count, by a few KB at default limits.
- **Changes with the mode:** code size (12x Debug to ReleaseSmall); stack use (not measured);
  and static buffers declared `= undefined`, which Debug fills with 0xAA and stores in the file
  (`.data` 15.9 MB in the Debug bench), so their pages are resident once touched and they are not
  zero. `initZeroed` over such a buffer in Debug starts from 0xAA columns. Declared `= @splat(0)`
  they are `.bss` in every mode [M].

So the owner's premise holds for the process, not for the report: ReleaseFast does use memory
differently (smaller code, `.bss` instead of `.data` for static buffers), but the numbers the
report prints are the same in every mode. Turning the report on in a release build costs
nothing in information, and a release build is where the real screens are visited.

## 5. The margin and the rounding

**No margin (owner's decision).** The suggestion is exactly the peak, or the "wanted" count when a
limit was hit, rounded up to the step below. The research had proposed 1.25x, after Go's slice
growth factor (`src/runtime/slice.go:333-341`) [S], as headroom for screens a run did not visit;
the owner removed it. The report's "this run only" line says the numbers cover only the frames
built, so headroom is the developer's choice, not the framework's.

**Rounding.** `simd.rows(cap) = alignForward(cap, lanes) + lanes` (`src/core/simd.zig:38-44`), so
for every table carved with `rows(cap)` all `cap` in one block of `lanes` cost the same: rounding
up inside the block is free. Two parts do not follow it [M]:

- the draw list carves `n + 1` rows of 136-byte quads and its command columns at `n + texts +
  customs + 4`, so it grows by about 128 bytes per node inside a block;
- the tree's extras carve `rows(cap + 1)`, so their block boundary is one node earlier: at 8
  lanes, 4,095 nodes cost 1,984 bytes less than 4,096.

`requiredBytes` at 8 lanes, nodes 4,090 to 4,105 [M]: 4,115,008, 4,115,136, 4,115,264,
4,115,904, 4,116,032, 4,116,160, 4,118,144, 4,119,040, 4,119,168, 4,119,296, 4,119,424,
4,119,552, 4,119,680, 4,119,808, 4,121,920, 4,129,600. The large step (+7,680) is the block
boundary of the main columns, at 4,105. Rounding to a multiple of the lane count costs at most
about 3 KB at 8 lanes (4,090 to 4,096: +3,136): not
free, but small. Round each limit up to a step: `simd.lanes` for row tables, 64 for `strings`
(one cache line of bytes), 16 for `depth` (a cache line of `u32`), and never below one step,
because every table asserts or relies on `cap > 0` (`src/core/texts.zig:42`,
`src/anim/anims.zig:70` computes `cap - 1`) [S].

## 6. Edge cases

**Frames that never ran.** The peak is of the frames built. A screen the session did not visit
is not in it. The report says how many frames it covers, and there is no allowance for it;
the honest wording is "peaks of N frames" [I].

**After a limit is hit, the count is a lower bound too.** With the shell example, limits that
truncate change what the app builds next [M]:

| limit hit | wanted nodes | texts | strings |
|---|---|---|---|
| none (1,024 nodes) | 18 | 7 | 51 |
| `depth = 3` | 17 | 6 | 44 |
| `strings = 16` | 17 | 6 | 44 |
| `texts = 4` | 18 | 7 | 51 |
| `nodes = 16` | 18 | 7 | 51 |

Hit testing and layout run on the truncated tree, so a widget that depends on them builds less.
The report should say so when anything was hit: raise the limits and run again [I].

**Persistent tables.** Anims, tweens, timers, memos and signals keep rows across frames; their
demand is the rows held at once plus the new ids refused that frame. Sample `len` before the
sweeps in `Frame.finish` (`src/runtime/frame.zig:264-265`, `:275`), since a row not yet swept
still occupies its slot. Past `cap` a new id overwrites the last row and the next lookup of the
displaced id misses, so `lost` can count one id more than once in later frames; it is still the
number of refusals, and over-reporting demand is the safe side [I].

**The comptime front end.** Its capacity is exact (`docs/DESIGN.md`, "Capacity is exact, so
there are no limits to configure and no overflow path"); RAM and read-only bytes are comptime
constants (`src/comptime/columns.zig:354-362`, `ram_bytes`, `runtime_bytes`). Nothing to record
at run time and nothing to print; a build-time size report is the place for its numbers [S].
If a bounded dynamic region for lists is added later, it is a limit like any other and joins the
same fold.

**Several contexts or windows.** One `Context` per window
(`src/shell/wayland/main.zig:59-61`), each with its own limits [S]. Usage is per `Context`; a
multi-window host formats one table per context with a label. `run` drives one context, so it
prints one.

**Generations.** perf-gaps is redesigning the second generation. The report reads its parts
from `build` (question 3), so it is correct for any number of generations and any sharing, as
long as `build` names each part it carves. Design against "generations: g, each part carved g
times or shared" and print the parts `build` reports, not a fixed list [I].

**Microcontrollers.** `std.debug.print` does not compile for `thumb-freestanding-eabihf`
(`std/Io/Threaded.zig:2108`: no `getrandom`, no `IOV_MAX`) [M]. `iface.run` is used by the
bare-metal firmware (`src/shell/baremetal/firmware.zig:51`) [S], so the print must be behind a
compile-time test of the OS, or a shell declaration. Without a sink, `Context.usage()` is still
there for a debugger (`p ctx.usage()` over SWD) or for the firmware to send over its own link.

## Design

### Data in `Context`

`src/runtime/context.zig`, after `Limits` (`:28-47`):

```zig
/// One per `Limits` field, in field order. Adding a limit adds a member, and `want` (frame.zig)
/// stops compiling until it says how to count it.
pub const Limit = std.meta.FieldEnum(Limits);
comptime {
    std.debug.assert(@typeInfo(Limits).@"struct".fields.len <= 16);
}
/// One count per limit, padded to a vector.
pub const Counts = @Vector(16, u32);

/// What the frames asked of each limit, past it included. Read with `Context.usage`.
pub const Usage = struct {
    limits: Limits,
    /// Frames built (`begin` calls).
    frames: u32 = 0,
    /// Largest demand in any frame: rows (or bytes, for `strings`; levels, for `depth`) the frame
    /// would have used with no limit. Above the limit when it was hit.
    peak: Counts = @splat(0),
    /// Frames whose demand was above the limit.
    hits: Counts = @splat(0),
    /// Number of the first such frame; 0 if none.
    first: Counts = @splat(0),
};
```

`Context` (`:106-154`) gains `usage: Usage` (`.limits` set in `build`), `open: u32` (open nodes,
unclamped) and `open_peak: u32`. `pub fn usage(ctx: *const Context) Usage` returns it with
`frames = ctx.frame`.

`Status` (`:51-62`) becomes `bitpack struct(u16)` with one bool per limit in `Limit` order, so
the six silent limits are reported too; `finish` sets it from the fold, `@bitCast` of the
`want > given` mask's low 11 bits. (An API change to `Output.status`; every current reader names
fields, so it stays source compatible.)

`pub fn partBytes(limits: Limits) Parts` beside `requiredBytes` (`:182`): `build` takes an
optional `*Parts` and stores `carver.off` deltas after each part; `requiredBytes` passes null.
`Parts` is an `std.EnumArray(Part, usize)` with `Part = enum { tree_cur, tree_prev,
layout_scratch, texts, customs, strings, draw, signals, anims, tweens, flips, stack, timers,
memos, levels, scopes }`; `layout_scratch` is `tree gen 0 - tree gen 1`, and `tree_cur` is
reported without it, so the three sum to the two trees. When the generations change, `Part`
changes with `build`.

### Hook points

| where | today | change |
|---|---|---|
| `src/core/tree.zig:206` | `overflow: bool` | `lost: u32 = 0`: pushes refused this frame; `overflow` becomes `lost != 0` at its readers (`src/runtime/frame.zig:234,269`) |
| `src/core/tree.zig:361` | `reset` clears `overflow` | clears `lost` |
| `src/core/tree.zig:379-380` | `overflow = orB(overflow, len >= cap)` | `lost += @intFromBool(len >= cap)`; also `c.parent[i] = @min(parent, i -| 1)` (the crash above) |
| `src/core/texts.zig:19,48,54`, `src/core/customs.zig:16,35,40` | same as the tree | same as the tree |
| `src/core/strings.zig:16,23,35` | `overflow = orB(overflow, bytes.len > room)` | `lost += bytes.len - n` (bytes refused) |
| `src/anim/anims.zig:70-71`, `src/anim/tweens.zig:81-82`, `src/runtime/scheduler.zig:137-138`, `src/runtime/reuse.zig:75-76` | `len = @min(len + is_new, cap)` | `lost += @intFromBool(is_new and len == cap)` before it; `lost` cleared in `begin` |
| `src/anim/flip.zig:40-45`, `src/runtime/signals.zig:34-35` | `k = @min(len, cap - 1)` | `lost += @intFromBool(len >= cap)` (flips cleared per frame at `context.zig:237`; signals never) |
| `src/runtime/context.zig:240-241` (`begin`) | `depth = 1` | `open = 1; open_peak = 1` |
| `src/runtime/frame.zig:52-60` (`open`) | clamps `depth` | `open += 1; open_peak = @max(open_peak, open)` |
| `src/runtime/frame.zig:63-68` (`close`) | never pops the root | `open = @max(open, 2) - 1` |
| `src/runtime/frame.zig:263-283` (`finish`) | `status` from the bools, after the sweeps | before the sweeps: build `want: Counts` with an `inline for` over `Limit` and an exhaustive `switch` (`.nodes => t.len + t.lost`, ..., `.depth => ctx.open_peak`); `given` from `limits`; fold; `status` from the mask |
| `src/shell/iface.zig:107-120` (`run`) | returns | after the loop, `usage.report(shell, ctx)` (below) |
| `build.zig:10-11` | `lanes` option | `options.addOption(UsageMode, "usage", b.option(UsageMode, "lcgr-usage", "Print the usage report when run returns: never (default), auto, always") orelse .never)` |

`want` for each limit: nodes, texts, customs, flips: `len + lost` of this frame's table. strings:
`len + lost` (bytes). anims, tweens, timers, memos: `len + lost` before the sweep. signals:
`len + lost` (signals are only created). depth: `open_peak`. memos' `kept` list is bounded by
the same `cap` (`reuse.zig:201-202`) and needs no separate count.

### The report

A new file outside the tiers, `src/shell/usage.zig`, so tier 0-2 stay free of `std.Io`:

- `pub fn suggest(u: Usage) Limits`: per limit, `max(step, roundUp(peak, step))`, with `peak` the wanted count when the limit was hit,
  with `step` = `simd.lanes`, 64 for `strings`, 16 for `depth`. Integer arithmetic, no float.
- `pub fn write(w: *std.Io.Writer, u: Usage, label: []const u8) !void`: the text below. Works into
  `std.Io.Writer.fixed` for hosts with their own loop and sink.
- `pub fn report(shell: anytype, ctx: *const Context) void`: called by `run`. Decides by
  `build_options.usage` (`never`: compiled out; `always`; `auto`: see below), formats into a
  fixed 4 KiB buffer, then hands the text to `shell.report(text)` if the shell declares it,
  else `std.debug.print("{s}", .{text})` when `builtin.os.tag != .freestanding`, else nothing.

Exact text, shell example at the example's limits after 30 frames (numbers measured with the
(The example below was computed with the old 1.25x margin; the implementation recomputes it from
the real numbers with the margin removed.)
prototype; suggested limits as `suggest` defines them; bytes are `partBytes` of each) [M]:

```
lcgr usage: 30 frames, no limit hit. Peaks are of the frames that ran.
limit         peak / given     use  suggested  frames hit (first)
nodes           18 / 1024       2%         24
texts            7 / 256        3%         16
customs          1 / 64         2%          8
strings         51 / 65536      1%         64
anims            0 / 256        0%          8
tweens           0 / 128        0%          8
flips            0 / 64         0%          8
signals          0 / 256        0%          8
depth            5 / 64         8%         16
timers           0 / 32         0%          8
memos            0 / 128        0%          8
buffer                            given  suggested
  tree, this frame               353408      11968
  tree, previous frame           353408      11968
  layout scratch, shared          49920       1536
  draw list                      199744       6720
  level index                     16640        512
  focus scopes                    10496        384
  text runs                       20736       2432
  custom draws                     2432        512
  strings                        131072        128
  signals                          2176        128
  springs                          8704        512
  tweens                           6336        704
  layout animations                1920        384
  open-node stack                   256         64
  timers                            704        256
  memos                            3392        384
  total                         1161344      38592
suggested: .{ .nodes = 24, .texts = 16, .customs = 8, .strings = 64, .anims = 8, .tweens = 8, .flips = 8, .signals = 8, .depth = 16, .timers = 8, .memos = 8 }
```

When a limit was hit, the first line is `lcgr usage: 30 frames, 3 limits hit (first: frame 1).
Frames that hit a limit were incomplete; their peaks may be low, so run again with the suggested
limits.`, and the row reads `nodes           18 / 16       113%         24  30 (1)`. Use is
`ceil(peak * 100 / given)` so any use shows at least 1%. Plain digits, no grouping (`std.fmt`
has none). Columns are fixed width; numbers up to 10 digits fit.

### `auto`, and a question for the owner

The owner's rule is "auto prints when a limit was hit or use was under 25%". Read per limit,
it always prints: the shell example at its own limits uses 0 to 8% of every limit, and an app
that never animates uses 0% of `anims` forever [M]. Two readings that do what it is meant to do:

- **bytes (recommended):** print when a limit was hit, or when `requiredBytes(suggest(u))` is
  under 25% of `requiredBytes(limits)`, that is, the buffer could shrink fourfold. Unused small
  tables then do not trigger it; an oversized node limit does. The example above: 38,592 against
  1,161,344, 3%: prints.
- **per limit, used ones only:** print when a limit was hit, or a limit with `peak > 0` is under
  25%.

Decided: **bytes**. The owner left the choice to the lead, who took the recommended reading. The
owner also decided the report is **quiet by default**: `-Dlcgr-usage=never` is the default, and
`auto` or `always` turn it on in every build mode, ReleaseFast and ReleaseSmall included.

### Tests to write

In `src/runtime/context.zig` and `src/runtime/frame.zig` unless named:

1. "usage: the peak is the largest frame, not the last": frames of 10, 30, 20 leaves; `peak` 31
   (with the root), `hits` 0.
2. "usage: past a limit it counts what was asked": `nodes = 16`, a frame of 40 flat leaves;
   `peak.nodes` 41, `hits` 1, `first` the frame number, `status.nodes`.
3. "usage: every limit is counted past its end": one table-driven test, a limit of 8 (or 64
   bytes, or depth 3) and a frame that asks for twice that, for each `Limit`; fails to compile if
   a limit is added without a row.
4. "usage: a full tree's nested open keeps parents before rows": the shell example at `.{ .nodes
   = 8 }` runs 30 frames in Debug without a panic (the crash above), and `tree.validate` passes.
5. "partBytes: the parts sum to requiredBytes" at default `Limits`, the example's, and one with
   every limit odd; runs at 4, 8 and 16 lanes in the test matrix.
6. "Tree column groups cover every column once": a comptime check in `src/core/tree.zig`, plus a
   test that the groups sum to `Tree.init`'s count.
7. "suggest: the peak rounded up to the step, never zero": peaks 0, 1, 18, 4096 and 65536 bytes;
   `requiredBytes(suggest(u))` is at most `requiredBytes` of the exact peak limits
   plus 4 KB.
8. "report: the exact text" in `src/shell/usage.zig`: a fixed `Usage` written into
   `std.Io.Writer.fixed`, compared with the expected string, once without hits and once with.
9. "run prints once when the shell is done": in `src/shell/iface.zig`, the `Manual` shell with a
   `report` declaration captures the text; under `-Dlcgr-usage=never` it is not called.
10. The bare-metal build (`ci/run.sh baremetal`) still links, for Cortex-M7 and RV32IMAC.
11. Census: `tools/census/baseline-src.json` unchanged.

### Measured cost, for the commit message

Recording always on (the recommendation in "Decision change"):

`Tree.pushRow` +1 instruction (an `add` replaces the `or` of the overflow flag), no conditional
jump in any census probe; the 3,961-node build, interleaved in one process, +0.0 to +0.6 us on
108 us at load 14 (`docs/research/usage/pushab.zig`); one 16-lane fold per frame; 200 bytes in
`Context`, none in the buffer. Re-measure `pushab.zig` at load under 8 before quoting a number
below 0.5%.

## Decision change: quiet by default

The owner changed the default: `-Dlcgr-usage=never` is the default; `auto` (prints when a limit
was hit or use was under 25%) and `always` turn the report on, in every build mode. Two ways to
build `never`, both designed and measured here.

**Option 1: recording always on, only the printing gated.** Everything in "Design" stays; under
`never`, `src/shell/usage.zig`'s `report` is `if (comptime build_options.usage == .never)
return;`, so the formatter and `std.debug.print` are not referenced and not linked.
`ctx.usage()` and the 11-bit `Status` work in every build.

**Option 2: recording compiled out under `never`.** `const record = build_options.usage !=
.never;` in `src/runtime/context.zig`; `Usage`'s counters, `open` and `open_peak` become `if
(record) T else void`, the fold in `finish` and the depth counting in `open`/`close` sit under
`if (comptime record)`, and `ctx.usage()` is a `@compileError` when `!record`. The `lost`
counters cannot go: `Status` is reported in every build and needs "this table was full", which
is what `lost != 0` is. Keeping a bool instead under `never` means two versions of every push
(`overflow` or `lost`), in tier 0, chosen by a build option.

Measured, this checkout's `src/` at 3aa2f9d (option 2 under `never` is exactly that code) against
`prototype.diff` (option 1; the diff keeps `overflow` beside `lost`, so its cost is an upper
bound) [M]:

| | option 2, `never` | option 1 | difference |
|---|---|---|---|
| `Tree.pushRow`, disassembled | 1 jcc | 1 jcc, `xor` and `add` more (the `or` of `overflow` goes in the design) | +1 instruction net |
| 3,961-node build (`pushab.zig`), median of 5 | 107.8-109.3 us | 108.3-109.2 us | +0.0 to +0.6 us |
| shell example frame, 18 nodes, `begin` to `end` (`frameab.zig`), medians of 10 processes, order alternated | 2,969-3,698 ns | 2,924-3,828 ns | -77 to +130 ns, median of the ten differences +6 ns |
| `.text`, ReleaseSmall, a program running the example (`one.zig`) | 39,430 B | 40,200 B | +770 B |
| `.text`, ReleaseFast, same | 74,603 B | 76,563 B | +1,960 B |
| `Context` | 4,112 B | about 4,312 B | +200 B (three 64-byte vectors, two `u32`) |
| buffer (`requiredBytes`) | unchanged | unchanged | 0 |

Load 11 to 14, CPU 8, interleaved in one process; the per-frame difference does not resolve at
this load in either direction, so the fixed per-frame cost is under about 0.1 us [M].

**Recommendation: option 1.** The cost it would save is one instruction per push, a fold per
frame that does not show above the noise, under 1 KB of ReleaseSmall code and 200 bytes of
`Context`. What option 2 costs instead [I]:

- `ctx.usage()` exists only in some builds, so a host that reads it (its own loop, the devtools
  inspector, a test) stops compiling, or reads zeros, when a dependency builds with `never`;
- the six silent limits stay silent under `never` unless their counters stay anyway, which is
  most of the recording;
- every table in tier 0 grows a build-option branch in its type, and each configuration needs
  its own test run (the test matrix doubles for `src/core`, `src/anim`, `src/runtime`);
- the report's numbers would only be trustworthy in builds where it is on, while the bug it
  exists to find (a frame bigger than the limits) happens in the build that ships.

Changes to "Design" under option 1: the build option's default is `never`; `run` compiles the
report only when the option is `auto` or `always`; test 9 checks that under `never` the shell's
`report` is not called and `std.debug.print` is not referenced (the ReleaseSmall `.text` of the
headless example is unchanged by the feature beyond the recording, +770 B or less); add test 12,
"usage: recorded under never": `ctx.usage()` after frames that hit a limit gives the counts with
`-Dlcgr-usage=never`. Re-measure `frameab.zig` and `pushab.zig` at load under 8 before quoting
anything finer than "under 0.1 us per frame, under 0.5% of build".

## Sources

Fetched 2026-11-16:

- Clay, `clay.h` at e6cc36941ab2af5d81107617039d6f527a1c660b (github.com/nicbarker/clay); issue
  github.com/nicbarker/clay/issues/102.
- Dear ImGui, `imgui.cpp` at master, `IMGUI_VERSION "1.93.1 WIP"` (github.com/ocornut/imgui).
- LVGL master: `include/lvgl/stdlib/lv_mem.h`, `src/debugging/sysmon/lv_sysmon.c`,
  `src/stdlib/builtin/lv_mem_core_builtin.c` (github.com/lvgl/lvgl).
- FreeRTOS-Kernel main, `include/task.h` (github.com/FreeRTOS/FreeRTOS-Kernel).
- Zephyr main, `subsys/debug/thread_analyzer/thread_analyzer.c`
  (github.com/zephyrproject-rtos/zephyr).
- jemalloc dev, `doc/jemalloc.xml.in` (github.com/jemalloc/jemalloc).
- Go master, `src/runtime/slice.go` (github.com/golang/go).
- TigerBeetle main, `docs/TIGER_STYLE.md` (github.com/tigerbeetle/tigerbeetle).
- Unreal Engine documentation, "Using the Low-Level Memory Tracker in Unreal Engine"
  (dev.epicgames.com/documentation/en-us/unreal-engine/using-the-low-level-memory-tracker-in-unreal-engine).
- Zig 0.18.0-dev.1151+8dfb7a7cc standard library, `lib/std/heap/ArenaAllocator.zig`,
  `lib/std/debug.zig:320-328`.
