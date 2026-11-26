# Redundant static-UI ports: why they are faster than Zig, and how to delete them

Research only, on an export of `main` at d791e152 (2026-11-26). Nothing in the repository was edited during it. Its experimental edits are in [`experiments.diff`](experiments.diff): the bench harness (reps and modes), the inlining experiment on the comptime pipeline and on the engine, and the C-backend probe step. The keep-skip measurement (§2.3) was reverted after it was measured and is shown in Appendix B. The measurement scripts are in [`scripts/`](scripts/), and the raw per-round data in [`data/`](data/).

The question it answers comes from the user's position: the C++ and Rust bindings should not re-implement Zig logic. Zig should be the fastest implementation, and the bindings should call it or be generated from it.

## Summary

**Conditions.**
- Machine: Ryzen 7 8700F, `taskset -c 3`, 9 interleaved rounds, medians.
- Per frame = (count at 100 reps − count at 0 reps) / 24,000.
- Zig 0.18-dev (LLVM 23.1, native, 8 lanes); rustc 1.99.1 (LLVM 23.1.3, `target-cpu=native`, 1 codegen unit, LTO).
- The machine was shared with other agents, so wall time is noisy and cycles and instructions are the main evidence.

**Baseline on main, instructions / cycles per frame:**

| UI | Zig comptime | Rust | engine |
|---|---|---|---|
| settings | 10,348 / 5,104 | 8,707 / 3,916 | 13,614 |
| todo | 18,397 / 7,669 | 10,632 / 4,701 | 17,270 |
| dash | 5,041 / 2,269 | 3,479 / 1,688 | 5,596 |
| mixer | 2,002 / 1,054 | 1,123 / 549 | 3,347 |

The harnesses do the same full frame; this was checked independently. `stateFor + gatherText + select` is 4–9% of a frame, and the ports do the same formatting inside `frame`.

**Root causes of the gap:**
1. **The "comptime" passes aren't specialized.** `src/comptime/layout.zig:461-469` calls `layout.fit`/`resolve`/`place`/`finalizeWith` out of line, with a run-time `axis` and the `View` passed by pointer. Constant columns are loaded instead of folded. One `resolve__func_1035` symbol serves all four UIs, because identical bodies were merged. Inlining them with `@call(.always_inline)`:
   - cut instructions by 16% (settings), 16% (todo), 29% (dash) and 49% (mixer);
   - kept all 10 static UIs and the 5 partial replays byte-identical;
   - did not grow the pass code size (about 41 KB after, at least 42 KB before).
2. **`keep`/`convert` (`src/comptime/layout.zig:498-524`) copies every output column into `Dynamic` each frame.** That is 24% of todo's instructions, and the ports never make the copy. With the copy skipped, Zig runs 8,059 / 10,785 / 3,347 / 938 instructions on settings / todo / dash / mixer: equal to or below Rust's count, except todo at +1.4%.
3. **A residual 7–14% in cycles** comes from lower IPC (more backend stalls; store-forwarding ruled out). The likely causes are codegen detail: finalize's scope and extra-row loads, building the `Texts` columns, and padded struct-field tables where Rust folds whole columns to bit masks.
4. **The gate's C++ column is an SSE, 4-lane build.** `NIX_ENFORCE_NO_NATIVE` plus no `-march` makes CMake pick `liblcgf_l4.a`. Native clang runs Rust's instruction counts.

**Why the engine sits near the seam lines.** The seam itself costs nothing: engine, `rust/sm` and `c++/sm` all run about 13.6k instructions on settings. The engine's cost is interpreting run-time tables, and inlining its passes gains at most 2.4%. Against Zig after both fixes it runs 1.6–3.5× the instructions and 1.33–2.4× the cycles. It only looked competitive because the comptime line had both defects. There are four copies of the static frame, not three: `src/abi/ct.zig:700-1183` is a second Zig copy.

**Feasibility checks.** Zig's C backend compiles the engine to C (756 KB). gcc and clang build it, and linked in place of liblcgf all 10 static UIs are byte-identical. Unspecialized, it runs at the engine's speed under clang and about 3× slower under GCC. Zig and rustc here share LLVM 23, so LTO specialization is also viable for Rust.

**Recommendation: fix Zig first, then delete the ports.**
- **WP1:** inline the passes.
- **WP2:** have finalize write the outputs directly instead of `keep`.
- **WP3:** one Zig frame body, generic over where its tables come from. Deletes about 400 lines of the engine's duplicate.
- **WP4:** C++ and Rust static UIs use `SeamUi` only. Deletes `ct.hpp` (780), `ct.rs` (1,184) and about 420 `lcgf-gen` lines.
- **WP5:** recover per-UI speed with no Zig compiler at the user's build time: C-backend source or LTO bitcode, specialized on constant `words`.
- **WP6:** runtime copies move to calls plus LTO (`Push`, `Row`, `Animatable`'s rounding). `Id` stays, gated.

Taken alone, WP4 costs C++ and Rust static UIs 1.33–2.4× in cycles, so run WP5's probe first if that regression isn't acceptable even briefly. The existing plans (`docs/plans/bindings-*.md`) keep `ct.rs`, `ct.hpp` and the hand fast paths on a "parity already reached" claim that was measured against the defective baseline, so they don't go far enough.

On the experiments only the byte-identity checks were run, not `zig build test`, `census-src` or the full gate. The `keep` skip is a measurement, not a fix, and WP5's specialized speed isn't measured yet.

## 0. Conditions and method

- **Machine:** AMD Ryzen 7 8700F (Zen 4, 16 threads), Linux 7.0.10, shared with other agents. Wall time varied ±15–30% between rounds, so cycles and instructions are the primary evidence.
- **Toolchains:**
  - Zig 0.18.0-dev.1151 (pinned, LLVM 23.1), `zig build abi -Doptimize=ReleaseFast`, native, 8 lanes.
  - rustc 1.99.1 (LLVM 23.1.3), `-C target-cpu=native`, 1 codegen unit, fat LTO, abort.
  - GCC 16.2 and clang 21.1.8 from `.#vs`.
  - perf from `/nix/store/aimqccjpiwq49lvffnra8zxb8rmwjs67-perf-linux-7.0.10/bin/perf`, since the shells have none. `perf_event_paranoid` is 2, so every event takes `:u`.
- **Counting:**
  - Per frame = (count at 100 reps − count at 0 reps) / (100 × 240). This removes start-up, table building and dumps.
  - Cycles are the mean over the 100 reps. "ns" is the harness's best of 50 reps.
  - 9 interleaved rounds, medians: [`data/measure-base.txt`](data/measure-base.txt) (main) and [`data/m-final.txt`](data/m-final.txt) (after the experiments).
- **Harness changes in the export only:** `LCGF_REPS` for C++ and Rust, and `lcgf-ct-dump <ui> 240 --bench zig|engine|gather|layout <reps>` (in [`experiments.diff`](experiments.diff)).
- **Gate C++ is SSE, 4 lanes.** `NIX_ENFORCE_NO_NATIVE` and no `-march` make `lcgfConfig.cmake:16-23` choose `LCGF_LANES=4` and `liblcgf_l4.a`. Hand-built native variants were added for comparison: `g++`/`clang++ -O3 -march=znver4 -DLCGF_LANES=8` against `liblcgf_l8.a` (Appendix A).

### 0.1 Same work per frame (checked independently)

- **Zig, `ct_dump.zig:104-143`:** `stateFor`, `gatherText` (`ct.zig:1313`, formatting), `Regions.select`, `runLiveText` (measure, masks, passes, finalize, `keep`), `rebuildLiveText` (paint, encode, patches). No allocation in the loop.
- **Rust, `ct_check.rs:136-151`:** the `set` closure, then `Ui::frame` = `ct.rs:673-680`: `gather` (`T::texts` plus the measure), `select`, `layout`, `paint`, `patch_all`. No incremental path; `relayout` and `patch` are only used by `partial`.
- **C++, `ct_check.cpp:95-120`:** the same as Rust.
- **Zig harness extras:** the `gather` and `layout` split puts `stateFor + gatherText + select` at 93 / 212 / 384 / 432 instructions per frame (mixer / dash / settings / todo), 44–130 cycles, 4–9% of a frame. The ports do the same formatting inside `frame`, so nothing needs normalizing.
- **Engine line:** it also pays `cStateOf` (a memset plus stores) per frame, about 50 instructions.

## 1. Inventory of the duplication

There are four implementations of the static frame: comptime `ct_layout`/`ct_paint`, the `src/abi/ct.zig` engine, `ct.hpp` and `ct.rs`.

### 1.1 Static-UI ports (main; counts in parentheses)

| Piece | Zig original | ct.hpp | ct.rs | Engine (`src/abi/ct.zig`) |
|---|---|---|---|---|
| f32 helpers (maxF, minF, b2f, exact round) | `simd.zig:70-90`, `rounding.zig:27` | 38-57 (20) | 16-52 (37) | uses simd |
| Sink: put, putBool, putUint, putF32 | `fmt.zig:110-160` (Sink, decimal) | 59-105 (47) | 156-243 (88, with decimal and round_half_away) | uses `fmt.Sink` |
| Region, Select, select_window | `dynamic.zig:62`, `:178` | 107-127 (21) | 54-66, 245-264 (33) | 706-717 (again) |
| Block, Tables | `ct.zig:98-200` (Block, Region, Header) | generated per UI | 67-155 (89) | `Run.carve` 735-783 |
| Live mask | `dynamic.zig:196`, `comptime/layout.zig:475` | 165-181 (17) | 334-351 (18) | 790-811 |
| fit | `layout.zig:93-161` (`fitOf`) | 183-205 (23) | 353-376 (24) | tier 0 |
| resolve | `layout.zig:193-257` | 206-234 (29) | 378-405 (28) | tier 0 |
| place | `layout.zig:292-337` | 235-258 (24) | 407-430 (24) | tier 0 |
| passesLiveText, prepare/clear, applyText, Mono measure | `comptime/layout.zig:440-470`, `layout.zig:36-60`, `protocol.zig:44` | 273-309 (37) | 432-493 (62) | 814-868 (a copy over runtime tables) |
| relayout (span) | `comptime/layout.zig:392-424` | 259-272, 367-390 (38) | 495-528, 695-717 (57) | — |
| Fold expand | `comptime/layout.zig:695-718` | 574-598 (25) | 816-846 (31) | 1031-1050 |
| finalize | `layout.zig:366-421` | 610-638 (29) | 848-883 (36) | tier 0 |
| Slots, geometry | `comptime/layout.zig:487-494`, columns.zig slots | 640-666 (27) | 1019-1063 (45) | 1052-1058, 1088-1103 |
| shown (quadVisible, paintBounds) | `comptime/paint.zig:310`, `draw/geometry.zig` | 668-679 (12) | 1065-1076 (12) | 1105-1114 |
| emit, emitLiveText | `comptime/paint.zig:231-360` | 681-698, 721-777 (75) | 1078-1095, 1120-1184 (83) | 1118-1182 |
| encode | `draw/paint.zig:152` | 699-720 (22) | 1097-1118 (22) | calls `paint.encode` |
| Patches | `comptime/paint.zig:151-230` | 391-416, 599-608 (36) | 719-776 (58) | 1064-1084 (`patchAll`) |
| Events: at, pointer, nextFocus, focusKeys, shortcut | `comptime/events.zig:168, 283-325, 418` | 311-334, 425-538 (~138) | 576-580, 885-1017 (~138) | — |
| Ui value, new, frame, draw | — | 336-366, 539-560 (~55) | 529-694 (~165) | 876-1030 |
| **Total** | | **780, hand-written** | **1,184, hand-written** | **≈480 (700-1183)** |

**The generator side:**
- `tools/lcgf-gen/main.zig:384-953` (`NativeBlock`, `StaticGen`, 570 lines) writes the native tables. About 150 of those lines (state, enums, `words`, setters) are also needed by `SeamUi`.
- `lcgf-macros/src/lib.rs:273-300` routes `include_ui!(.., static)` there.
- `bindings/cpp/check/ct_check.cpp` and `bindings/rust/lcgf-check/src/ct_check.rs` exercise both the compiled and the seam paths.

**Why the copies exist:**
- **Code comments**, `ct.hpp:1-13` and `ct.rs:1-11`: every row count, style value and template is a compile-time constant, "so they fold into the passes"; "nothing crosses the C seam".
- **DESIGN.md:124-131**: "ported … so the compiler folds them as Zig's does … Rust and clang run at Zig's speed or faster".
- **bindings.md:209-217 and 300-326**: the same reasoning, with the timing table (Rust 43–1,029 ns against Zig 60–1,481 ns) and "SeamUi takes 1.1 to 1.6 times Zig's, since a prebuilt library reads the tables as data".
- **Git history**: `git log -S` finds every item (`struct Sink {`, `Row(const Style& s)`, `View::push`, `struct Components`, `trait Animatable`, `fn round4`, `lcgf_row_from_style`) first in one commit, ac06f6fa (2026-11-25), "bindings: C++ and Rust over a C seam, with static UIs compiled natively". Its message lists the ports. The only later change to ct.rs or ct.hpp is the styling merge, bc0a3c6e.
- **The plans**: `bindings-rust.md` §3 T3 says "`ct.rs`: keep. It is measured at or below Zig's time", and T4 rejects per-UI code as "a third copy". `bindings-cpp.md` §10 Q3 says "Keep compiled ct.hpp/ct.rs".

### 1.2 Runtime-binding copies

| Copy | Zig original | C++ (`runtime.hpp`) | Rust (`runtime.rs`) | Stated reason |
|---|---|---|---|---|
| `Id::From`/`With` | `types.zig:20-32` (FNV-1a, `with`) | 39-58 (20) | 18-42 (25) | "inline here": a constexpr / const fn id |
| `Row` (`Template.from`) | `tree.zig:130-208` (79) | 120-200 (81) | 300-396 (97) | rows at host compile time "so only the row crosses"; gated by the 4,096-style rows sweep |
| `Push` (`Tree.pushRow`) | `tree.zig:473-547` (75) | 367-433 (67) | 478-584 (107) | "store for store … what Zig's inlined `open` does, with no call" |
| `Enter` (`Frame.enter`) | `runtime/frame.zig` | 435-444 (10) | 588-597 (10) | same |
| `Components`/`Animatable` | `anim/values.zig` (142: count, flatten, build, int round and clamp) | 230-280 (~50) | 884-962, round_f32 966-979, each 983-996 (~110) | Zig can't reflect host types; the int rounding and clamping is a copy |
| `Sink` | `fmt.zig:110-160` | in ct.hpp | in ct.rs | used only by the static `texts`; runtime `TextF` uses std::format / format! |

## 2. Why the ports are faster

### 2.1 Baseline on main (medians of 9, `data/measure-base.txt`)

Each cell is instructions / cycles per frame (IPC).

| UI | zig | engine | c++ (gate, SSE, l4) | rust | rust/sm |
|---|---|---|---|---|---|
| settings (32 rows) | 10,348 / 5,104 (2.03) | 13,614 / 5,509 (2.47) | 16,348 / 5,655 (2.89) | 8,707 / 3,916 (2.22) | 13,707 / 5,871 |
| todo (38 rows) | 18,397 / 7,669 (2.40) | 17,270 / 6,959 | 19,967 / 6,995 (2.85) | 10,632 / 4,701 (2.26) | 17,096 / 7,338 |
| dash (13 rows) | 5,041 / 2,269 (2.22) | 5,596 / 2,476 | 5,174 / 1,842 (2.81) | 3,479 / 1,688 (2.06) | 5,662 / 2,512 |
| mixer (8 rows, 2 folded) | 2,002 / 1,054 (1.90) | 3,347 / 1,431 | 2,322 / 800 (2.90) | 1,123 / 549 (2.05) | 3,346 / 1,421 |

ns medians, zig / engine / c++ / rust: settings 937 / 991 / 894 / 778; todo 1,372 / 1,414 / 1,407 / 910; dash 465 / 417 / 341 / 348; mixer 214 / 277 / 147 / 113.

Zig's comptime pipeline executes 1.19× (settings) to 1.78× (mixer) the instructions Rust does, and 1.30× to 1.92× the cycles.

### 2.2 Root cause 1: generic, out-of-line tier-0 passes

- **Code.** `src/comptime/layout.zig:461-469` calls `layout.fit(&v, .x)`, `layout.resolve(&v, .x, …)`, `layout.place(&v)` and `layout.finalizeWith(&v, …)`. These are plain functions:
  - `fit` and `resolve` are `pub fn` at `src/layout/layout.zig:63, 167`, with `axis` a run-time parameter;
  - `placeOf` is a plain `fn` at `:292`;
  - `finalizeSpanWith`/`finalizeSpanMode` are `fn` at `:359, 366`.

  LLVM keeps them out of line, and they receive the `View` by pointer. So every constant column is a load through a column pointer from the view: a dropped column that is one value in every row (`flow = 1`, `pct = -1`, `grow = 0`, `offset = 0`, `scroll = 0`) is loaded and multiplied every row instead of folded. And `a = @backingInt(axis)` is a run-time index.
- **Profile.** `perf record -e instructions:u` attributes 23.9–35.5% of instructions to one symbol `layout.layout.resolve__func_1035` and 11–26% to one `fit__func_1034` for all four UIs. `nm` shows only two copies of each (`fit__func_1034`/`_1128`, `resolve__func_1035`/`_1129`, 449–539 bytes), because identical bodies were merged. The comptime pipeline's hot loops are as table-driven as the engine's.
- **Rust** marks every pass `#[inline(always)]` and makes the axis a const generic (`fn fit<T, const A: usize>`, ct.rs:353).
- **The recorded decision.** The file comment `src/comptime/layout.zig:18-27` (C0165) kept the passes rolled for MCU code size, but it measured unrolling, not inlining the rolled loops into the UI's own instantiation.
- **Experiment (a1).** `@call(.always_inline, …)` at those call sites (Plain and Layout), and `placeOf`, `finalizeSpanWith` and `finalizeSpanMode` made `inline fn`:
  - all 10 static UIs and the 5 partial replays stay byte-identical with C++ (compiled and seam, GCC and clang) and Rust;
  - pass code size in `lcgf-ct-dump` is roughly unchanged: about 41 KB after, against ≥42 KB over the same symbols before.

| UI | instructions, before → after (a1) | Rust | cycles, before → after | Rust |
|---|---|---|---|---|
| settings | 10,348 → 8,659 (−16%) | 8,707 | 5,104 → 4,937 | 3,973 |
| todo | 18,397 → 15,399 (−16%) | 10,632 | 7,669 → 8,725* | 5,173 |
| dash | 5,041 → 3,596 (−29%) | 3,479 | 2,269 → 2,198 | 1,731 |
| mixer | 2,002 → 1,015 (−49%) | 1,123 | 1,054 → 708 | 564 |

\*todo's cycle count moved within noise (the 3-round runs gave 7,831–8,725). Its instruction count is deterministic.

- **Annotated code.** After inlining, settings' `contrib = nat * flow[i]` multiply is gone because `flow` is a splat of 1.0. Rust goes further: in `fit` it turns `main[a][p] != 0` into `bt` against a 64-bit immediate mask (the whole `main` column in one register) and unrolls 2×. Zig's inlined fit still does `vcmpneqss 0x103ad2c(,%rcx,4)`, a load per row.
- **Likely reason (untested):** Zig's constant columns are fields of one large `C.pushed.c` struct global, padded to `simd.rows(n)` = padded(n) + lanes rows, whereas lcgf-gen gives Rust one exact-length `&'static [u32]` per column.

### 2.3 Root cause 2: the `keep` copy

- **What it does.** After finalize, `Plain.runLiveTextRounded` calls `keep(scratch, ram)` (`src/comptime/layout.zig:498-524`). It copies every output column (size, pos, rect, vis, visible, child_clip, …) from the stack `Scratch` into the UI's `Dynamic` RAM: exact rows, coordinates narrowed to `Coordinate`, and for UIs with shared slots (a `choice`) a row-by-row gather through `slot_source` (`convert`, :512-523). Paint then reads `Dynamic` (`src/comptime/paint.zig:253`, `rectOf`).
- **Cost.** In todo, `convert__func_987` is 24% of the frame's instructions. In the other UIs, `memcpyFast` is 1.3–2.6%.
- **The others don't copy.** The ports keep outputs where finalize wrote them and apply the slot indirection only where paint reads a rect (`ct.rs:1019-1050`, `geometry`, `rect_of`). The Zig engine does the same (`src/abi/ct.zig:1088-1103`).
- **Measurement (a2).** `keep` made to return immediately. Paint then reads stale `Dynamic`, but its work is unchanged, so this measures only the copy's cost; it is not a fix.

| UI | (a1) | (a1)+(a2) instructions | Rust | (a1)+(a2) cycles | Rust | cycles ratio |
|---|---|---|---|---|---|---|
| settings | 8,659 | 8,059 | 8,707 | 4,352 | 3,973 | 1.10 |
| todo | 15,399 | 10,785 | 10,632 | 5,882 | 5,173 | 1.14 |
| dash | 3,596 | 3,347 | 3,479 | 1,902 | 1,731 | 1.10 |
| mixer | 1,015 | 938 | 1,123 | 604 | 564 | 1.07 |

With both fixes, Zig executes the same instructions as the Rust port or fewer (−17% to +1.4%).

### 2.4 The rest: lower IPC on the same instruction count (not fully attributed)

After (a1)+(a2), Zig still takes 7–14% more cycles at equal or fewer instructions (IPC 1.55–1.85 against 1.98–2.19).

- **Store forwarding is ruled out.** `ls_bad_status2.stli_other:u` per frame is 36 / 63 / 49 / 39 in Zig (mixer / settings / todo / dash) against Rust's 39 / 65 / 113 / 54.
- **Backend stalls are higher.** `de_no_dispatch_per_slot.backend_stalls:u` is 1.6–1.9× Rust's (settings 12,322 against 7,664 slots per frame).
- **Candidates, visible in the annotated code but not measured one by one:**
  - `finalizeSpanMode` reads `t.x.row[c.scope[i]].active_participation` (two dependent loads per row, `layout.zig:399`) and `xrow[extra[i]].border` (two more), where the port reads a `border[i]` column. It also rounds through `rounding.vector` with run-time scale and origin, using a `vgatherqps` for the column-strided rect.
  - `Plain.texts` (`src/comptime/layout.zig:297-314`) fills 10 `Texts` columns per label before `Mono.measure` and `applyText`, where the port computes `w = len · px · advance` directly.
  - `scratch.sense = C.pushed.c.sense` copies a padded array every frame (:442).
- **It is codegen detail, not structure.** mixer through clang (`c++clang`, the same LLVM family) takes 711 cycles, close to Zig's 708, while Rust takes 564.

### 2.5 C++

The gate's C++ runs at SSE / 4 lanes (§0), with GCC 16 as the CMake compiler.

| Build | settings / todo / dash / mixer instructions |
|---|---|
| Gate (GCC, SSE, l4) | 16,348 / 19,967 / 5,174 / 2,322 |
| GCC native | 12,033 / 14,961 / 3,854 / 1,457 |
| clang native | 8,538 / 10,779 / 3,581 / 1,235 (Rust's code) |

The gate's `c++` line can look as fast as Rust in ns while executing 1.5–2× the instructions: its IPC is 2.6–2.9.

## 3. The engine against compiled code

Medians of 9, `data/m-final.txt`, after (a1) and with the engine's own passes inlined too:

| UI | engine | rust/sm | c++/sm (native) | cbe-clang (C-backend engine) |
|---|---|---|---|---|
| settings | 13,534 / 5,871 | 13,707 / 5,910 | 13,694 / 5,851 | 13,445 / 5,806 |
| todo | 17,180 / 8,142 | 17,096 / 7,083 | 17,070 / 7,681 | 16,590 / 7,564 |
| dash | 5,516 / 2,533 | 5,662 / 2,539 | 5,671 / 2,563 | 5,688 / 2,490 |
| mixer | 3,266 / 1,466 | 3,346 / 1,479 | 3,336 / 1,507 | 3,385 / 1,437 |

- **The seam costs nothing:** the in-process engine and the two seam lines are within 1–3%.
- **Inlining doesn't help the engine.** The same `@call(.always_inline)` treatment of `Run.passes` and `finalize` changed instructions by −0.6% (settings), −0.5% (todo), −1.4% (dash) and −2.4% (mixer).
- **Its cost is interpreting the tables.** Every table is a run-time slice into `words` (`Run.carve`, :735). So:
  - no constant column folds;
  - loop trip counts, `h.labels`, `h.quads`, `h.regions`, `h.folded` and the coordinate type are loads and branches: `ui.h.coord != 0` in `rectOf` per rect, `h.has_child_clip` per clip, `h.regions != 0` per `shown`;
  - label text goes through a byte-coded segment switch (`frame`, :987-1007) instead of straight-line code;
  - `get(…)` rebuilds slices from header offsets in every helper.
- **Against Zig after (a1)+(a2):** mixer 3.5× instructions (3,266 / 938) and 2.4× cycles; settings 1.7× and 1.35×; dash 1.65× and 1.33×; todo 1.6× and 1.38×. The ratio is largest on small UIs, where per-frame header decoding is a bigger share.
- **Why it looked close before:** the comptime line was itself generic, unfolded code (§2.2) plus the `keep` copy (§2.3). On todo the engine (17.3k) was even below comptime Zig (18.4k), because it has no `keep`.

## 4. Removing the redundancy while keeping the speed

### (a) Fix Zig's comptime pipeline: feasible, measured

| Change | Where | Effect |
|---|---|---|
| **a1:** inline the tier-0 passes into each UI's instantiation, axis comptime-known | `src/comptime/layout.zig:359, 413-421, 456-469, 716` (`@call(.always_inline, …)`), and `placeOf`/`finalizeSpanMode` inlinable. Use `inline` wrappers (`fitInline`, …) so the runtime tree's callers keep their shared code. | measured: −16 to −49% instructions; byte-identical; pass code size unchanged in `lcgf-ct-dump` |
| **a2:** no `keep` copy in the frame. Finalize writes the outputs into `Dynamic` directly (converting the coordinate type at the store), or paint and events read `Scratch` through the slot map, as the engine and ports do. | `src/comptime/layout.zig:498-524`, `paint.zig:253` (`rectOf`), events' `Rects` | measured as a skip: −30% on todo, −4 to −8% on the others |
| **a3:** constant columns as exact-length globals per column (test whether LLVM then folds `main`/`clips` to bit masks as for Rust); for static UIs, finalize reads sense and border through direct columns; `Plain.texts` replaced by a direct `len · px · advance` when the font is `Mono` | `columns.zig` (`pushed`), `layout.zig:399, 409`, `src/comptime/layout.zig:297` | unmeasured; aimed at the 7–14% IPC residue |

After a1 and a2, Zig needs no port to be the fastest implementation on instructions. a3 is what closes the remaining cycles.

The microcontroller budget must be re-checked, because the C0165 decision was about code size: `zig build ct-layout-size`, `ct-sizes`, `ct-rodata` and the ct-budget lane. If inlining costs flash on the budget targets, put it behind an `Options` switch (on by default, off for MCU budgets).

### (b) C++ and Rust static UIs calling Zig code instead of a hand port

| Option | Per-frame cost (vs Zig after a1+a2) | "No Zig compiler for users" (bindings.md:3) | Build complexity | Hand code deleted |
|---|---|---|---|---|
| **b1** prebuilt generic engine through the seam (`SeamUi` only) | measured: 1.6–3.5× instructions, 1.33–2.4× cycles; a1-style inlining gains it ≤2.4% | kept | lower than today | ct.hpp 780 + ct.rs 1,184 + ≈420 of `StaticGen` (lcgf-gen:384-953) + the compiled branches of both ct_checks |
| **b2** lcgf-gen emits per-UI Zig, the user's build runs `zig build-obj` | equal to Zig comptime (it is Zig) | **broken**: needs Zig at user build time (the plans' opt-in `specialize`) | a Zig toolchain in CMake / build.rs, plus cross-target flags | same as b1 |
| **b3** lcgf-gen ships a per-UI object it compiles itself | — | lcgf-gen is a plain Zig program: it can't emit machine code without the Zig compiler, and embedding it (LLVM, ≈150 MB) isn't viable. Prebuilt objects can only exist for UIs known at `zig build abi` time. | — | — |
| **b4** generate C++/Rust from the Zig source mechanically | port speed (host compiler specializes) | kept | a Zig-subset → C++ and → Rust translator; none exists for Rust | ports become generated, but a translator is its own large codebase |
| **b5a** engine as C source from Zig's C backend, shipped in the prefix; per UI, lcgf-gen emits `words` as a constant array and a TU that inlines the engine's frame with `words` constant, so the host compiler specializes it as it does the ports | probe, unspecialized: clang builds run at the engine's speed (13,445 / 16,590 / 5,688 / 3,385 instructions); GCC builds run 3× slower (41,420 / 48,430 / 16,553 / 9,221). Specialized: not measured; the upper bound is Zig's own a1+a2 result, since it is the same passes over constant tables. | kept (the C file is made by `zig build abi`, like liblcgf) | C++: one generated .c per UI (clang recommended); Rust: a `cc` build step, so it needs a C compiler | ports deleted; only Zig source remains |
| **b5b** the same specialization through LTO: `zig build abi -Dlto` ships `liblcgf_l*.bc`; the frame takes `words` as an argument and is `alwaysinline`; rustc / clang LTO propagates the constant `words` | same bound as b5a | kept if the host LLVM major matches. Here Zig is LLVM 23.1 and rustc LLVM 23.1.3 (a match); `.#vs` clang is 21.1.8 (no match). | the plans' opt-in T-LTO / D7 | ports deleted |

**Evidence for b5a, from this research:**
- A probe build step compiled `src/abi/ct.zig`'s exports with `.ofmt = .c` into a 756 KB C file.
- gcc 16 and clang 21 compile it at `-O2 -ffp-contract=off -fno-strict-aliasing`.
- Linked in place of liblcgf's `lcgf_ct_*` (`-Wl,--allow-multiple-definition`), all 10 static UIs are byte-identical to Zig's dumps, events included.
- It is not yet specialized, because today's `Ui` stores `words` in the caller's buffer (`Ui.init`, :933) and `frame` reloads it.
- What b5 needs in Zig: a `frameWith(words, buf, state, viewport)` that takes the tables as an argument and is `inline`. Best done in the same refactor as WP3: one frame body generic over where its tables come from.

**One implementation.** If the comptime frame and the engine become one Zig frame body generic over its table source, then the comptime tables give Zig comptime, run-time `words` give the prebuilt engine (b1), and constant `words` seen by a host compiler give b5. That removes src/abi/ct.zig's re-implementation of paint, masks, expand and patches (≈480 lines, :700-1183) and leaves one implementation of the static frame in the repository.

### (c) The runtime-binding copies

| Copy | Can it call Zig instead? | Recommendation |
|---|---|---|
| `Row::from` / `Row` (`Template.from`) | Yes at run time: `lcgf_row_from_style` exists. No for compile-time rows: a constexpr / const row needs host-language code. | Drop host-compile-time rows. Constant styles become static rows made once at start-up by `lcgf_row_from_style` (one call per style per program, not per frame). Per-frame styles take the slow path (`lcgf_frame_open` with the style; Zig does `from` + `pushRow`). Measure that the folded-constant case costs ≤1.02× instructions before deleting. |
| `Push` / `View::push` (`Tree.pushRow`) | Yes: `lcgf_frame_open_row` / `leaf_row`. | The plans' all-call variant (b), plus LTO (b5b) for parity. The hybrid (c) still keeps a hand fast path (generated stores, ≈8 hand lines, plus the node-column half of `Template.from`), so it does not meet "no re-implementation". |
| `Components` / `Animatable` (`values.zig`) | Built-in types can call Zig's instantiations (f32, Color, `[2]f32`, `[4]f32`). Zig cannot reflect user types. | Keep only the flattening adapter for user types (a derive in Rust, a specialization in C++). Move the int rounding and clamping back into Zig: pass and return f32 components, and convert in a Zig `build` export. |
| `Sink` (`fmt.Sink`) | Only the static ports use it. | Deleted with ct.hpp/ct.rs: the engine formats labels with `fmt.Sink` itself (`ct.zig:983`). |
| `Id::From` / `With` | No for compile-time ids. | Keep, since it is the language's own constexpr / const fn and 20–25 lines. Pin it with a gate check over a name sweep (`lcgf-rt-dump ids` against `Id.hash`), as `rows` pins `Row`. |

**Do the plans go far enough?** No, given the user's position:
- `bindings-rust.md` §3 T3 keeps `ct.rs`, `Row::from`, `Id`, `Animatable` and `Sink`, and T4 rejects per-UI code.
- `bindings-cpp.md` §4 T2 keeps the node-column half of `Template.from` and a hand fast push, and §10 Q3 keeps ct.hpp.
- Both base "static parity already reached" on a Zig baseline that was itself running generic passes (§2.2) and copying its outputs (§2.3).

The plans' generated mirrors (abi-gen T1/T2) are right and should stay: they remove hand declarations. They do not remove hand logic.

## 5. Recommendation and ordered work packages

Fix Zig first (WP1–WP2). Then make one Zig static frame (WP3), move C++ and Rust static UIs onto it (WP4), and recover per-UI specialization through generated C or LTO (WP5). For the runtime front end, move the remaining logic copies to calls (WP6).

- WP1–WP3 are pure Zig and make Zig the fastest implementation.
- WP4 is what deletes the ports. Taken alone it costs C++ and Rust static UIs 1.33–2.4× in cycles (measured, b1). Run WP5's probe before WP4 if that regression isn't acceptable even for one release.

Every WP has the same exit checks:
- `nix develop .#vs -c ci/run.sh bindings` byte-identical;
- `nix develop -c zig build test fmt`;
- `nix develop -c ci/run.sh census-src` with no counter beyond today's 47;
- pinned instruction parity (Appendix A: `taskset -c 3`, 9 interleaved rounds, `perf stat -e instructions:u`, (reps 100 − reps 0) / 24,000).

| WP | Change | Deleted / changed | Extra checks | Expected per frame (Ryzen 7 8700F, pinned) |
|---|---|---|---|---|
| **WP1** | Inline the tier-0 passes into the comptime instantiations with the axis comptime-known (`inline` wrappers in layout.zig, used by src/comptime/layout.zig) | ≈20 lines changed | `ct-layout-size`, `ct-sizes`, `ct-rodata`, ct-budget: no flash regression on MCU targets, or an `Options` switch | settings 8.7k, todo 15.4k, dash 3.6k, mixer 1.0k instructions (measured) |
| **WP2** | Remove the `keep` copy from the frame: finalize writes `Dynamic` directly, or paint and events read `Scratch` through `slot_source` | `keep`/`convert` (≈30 lines) replaced; `Patched.rebuildLiveText`'s and events' rect reads adjusted | `zig build test` (the Layout = runtime-tree equivalence tests at src/comptime/layout.zig:767-965 read `ram`) | todo 10.8k, settings 8.1k, dash 3.3k, mixer 0.94k instructions: ≤ Rust on 3 of 4 UIs, +1.4% on todo (measured as a skip) |
| **WP3** | One static frame body in Zig, generic over its table source (comptime `Plain`/`Layout`/`Paint` tables, or `words`); src/abi/ct.zig keeps only the words format, `make`, `check`/`init` and the C exports | ≈400 of src/abi/ct.zig:700-1183 | the engine-vs-comptime tests in src/abi/ct.zig; the `lcgf-ct-dump` engine line ≤ today | engine unchanged or better (≈13.5k on settings); one implementation in the repo |
| **WP4** | C++ and Rust static UIs = `SeamUi` only | `bindings/cpp/include/lcgf/ct.hpp` (780), `bindings/rust/lcgf/src/ct.rs` (1,184), `NativeBlock` and most of `StaticGen` in tools/lcgf-gen/main.zig (≈420 of 384-953), the compiled branches of `ct_check.cpp`/`ct_check.rs`, the native path of `include_ui!(.., static)`; the guide's "Static UIs" cost table rewritten | the partial (`relayout`/`patch`) replay and events move to the seam (new `lcgf_ct_relayout`/`lcgf_ct_patch`/`lcgf_ct_pointer`/focus exports); the gate compares them | 1.33–2.4× Zig's cycles (b1, measured) until WP5 |
| **WP5** | Specialization by the host compiler without a Zig compiler: b5a (C backend → `lcgf_ct_frame.c` installed by `zig build abi`, a per-UI TU with constant `words`, clang) and/or b5b (LTO bitcode). Probe on mixer, dash, settings and todo first; adopt the first that reaches ≤1.05× of WP2's instructions. | no hand code added; the C file and bitcode are build outputs | the probe's parity numbers; the gate byte-identical through the C build (already true unspecialized: 10/10 UIs) | target: WP2's numbers, bounded by specialized Zig. GCC users fall back to b1 if b5a stays 3× slow under GCC. |
| **WP6** | Runtime copies: `Push`/`View::push` → all-call + LTO; `Row` → start-up rows and slow-path calls; `Components`/`Animatable` → adapters over Zig's `values` exports; `Id` kept and gated | runtime.hpp:120-200, 367-444 (≈160); runtime.rs:300-396, 478-597 (≈220); the rounding in runtime.rs:966-996 and `Components`' `make` | the `rows` sweep becomes "library row = Zig row"; the `rt-*` scenes byte-identical; the three-way push measurement, with all-call + LTO added | to measure: estimated 1–3 ns per call without LTO, 0 with |

Hand code removed across WP3–WP6: about 1,964 port lines, ≈420 generator lines, ≈400 engine lines and ≈380 runtime-binding lines, about 3,160 in all.

## 6. What was not done

- **Not run on the experiments:** `zig build test fmt`, `census-src` and the full `ci/run.sh bindings`. Byte-identity of the 10 static UIs (and the 5 partial replays for Rust) was verified for each experimental build directly with the harness binaries (Appendix A.5).
- **(a2) is a measurement, not a fix.** Paint read stale RAM while its work stayed the same.
- **b5's specialized speed is not measured.** It needs the `frameWith` refactor.
- **No per-candidate experiment for the residual IPC gap (§2.4).**
- **Wall-clock medians are noisy:** the machine was shared with other agents. Rust settings ran 599–835 ns across rounds.

## Appendix A. Reproducing

The scripts are in [`scripts/`](scripts/): `m2.sh` (pinned per-frame counters, reps 100 minus reps 0), `measure.sh` (the baseline), `summ.py` (medians per UI and implementation) and `stlf.sh` (store-forwarding and stall counters). Run them from an export root with the harness diff from [`experiments.diff`](experiments.diff) applied.

- **Build:** `zig build abi -Doptimize=ReleaseFast`.
- **C++ check:** CMake against the prefix.
- **Rust check:** `RUSTFLAGS='-C target-cpu=native' cargo build --release -p lcgf-check --bin lcgf-ct-check`.
- **Native C++ variants:** `g++`/`clang++ -O3 -DNDEBUG -std=gnu++20 -ffp-contract=off -march=znver4 -DLCGF_LANES=8` against `liblcgf_l8.a`. `-march=native` is stripped by the Nix wrapper, hence the explicit `-march`.
- **C-backend probe:** `zig build cprobe` → `zig-out/cprobe/lcgf_ct.c` (a 756 KB C file), compiled with `-O2 -march=znver4 -ffp-contract=off -fno-strict-aliasing -I<zig lib dir>`, and linked in place of liblcgf's `lcgf_ct_*` with `-Wl,--allow-multiple-definition`.

**Final measurement:**

```sh
scripts/m2.sh 9 "zig(a)=src/zig-out/bin/lcgf-ct-dump @UI@ 240 --bench zig @R@" \
 "engine=src/zig-out/bin/lcgf-ct-dump @UI@ 240 --bench engine @R@" \
 "rust=env LCGF_REPS=@R@ work/rust/release/lcgf-ct-check @UI@ 240 --bench" \
 "rust/sm=env LCGF_REPS=@R@ work/rust/release/lcgf-ct-check @UI@ 240 --bench seam" \
 "c++gate=env LCGF_REPS=@R@ work/cpp/lcgf-cpp-ct-check @UI@ 240 --bench" \
 "c++gcc=env LCGF_REPS=@R@ $C/gcc-l8 @UI@ 240 --bench" \
 "c++clang=env LCGF_REPS=@R@ $C/clang-l8 @UI@ 240 --bench" \
 "c++/sm=env LCGF_REPS=@R@ $C/gcc-l8 @UI@ 240 --bench seam" \
 "cbe-clang=env LCGF_REPS=@R@ $C/clang-cbe @UI@ 240 --bench seam" > m-final.txt
python3 scripts/summ.py m-final.txt
```

**Byte identity:** each of the 10 static UIs is dumped with `lcgf-ct-dump <ui> 240 out.bin`, and every C++ and Rust variant, compiled and `seam`, is compared with `cmp`, events included. The 5 partial replays are compared the same way. There were no differences with any experimental build.

## Appendix B. The keep-skip measurement (reverted; not in experiments.diff)

```diff
--- a/src/comptime/layout.zig
+++ b/src/comptime/layout.zig
@@ pub fn keep
         pub fn keep(scratch: *const Scratch, ram: *C.Dynamic) void {
             @setEvalBranchQuota(100_000);
+            if (@import("root").skip_keep) return;
--- a/bindings/check/ct_dump.zig
+++ b/bindings/check/ct_dump.zig
@@ (end of file)
+pub const skip_keep = true;
```

Measured with `scripts/m2.sh 3 "zig-nokeep=src/zig-out/bin/lcgf-ct-dump @UI@ 240 --bench zig @R@"` (`data/m-nokeep.txt`). It makes paint read stale `Dynamic`, so the output is wrong; it shows only the copy's cost.
