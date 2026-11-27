# Code standard

How code in this repository is written. The reasons behind it are in `docs/DESIGN.md` (the four
rules) and in the two guides under `.claude/skills/`. Where this file and the compiler disagree
about Zig, `docs/ZIG_0_17_1.md` and the compiler win.

## Which "clean code" rules apply

Textbook clean code is half right for this project. The half that is about clarity is adopted. The
half that is about hiding data behind objects is rejected in tiers 0 and 1, because it costs exactly
what the framework exists to save: cache misses, indirect calls and per-node work (Muratori, *Clean
Code, Horrible Performance*).

### Adopted everywhere

| Rule | What it means here |
|---|---|
| Names say what a thing is for | `layout.applyText`, `Tree.Columns`, `requiredBytes`; not `process`, `data`, `tmp`. A column is named for what one row holds. |
| A function names one step | A function is one step of a pass (`layout.fit`, `layout.resolve`, `layout.place`), not one node. Length is fine if it is one step. |
| No hidden allocation | Tiers 0 to 2 take no allocator. Memory comes from the caller as a buffer; a function that needs scratch says so in its signature. |
| No hidden control flow | No callbacks, no framework-owned loop, no global state. The caller sequences the passes. |
| Comments say why | The code says what. A comment explains a choice, a contract (padding, index ranges) or a measured number. |
| Tests sit next to the code | `test` blocks in the same file. A new public function arrives with the test that uses it. |
| Compress after the second use | Write it out once; extract the shared part when the second caller appears, not before (Muratori, *Semantic Compression*). |
| One logical change per commit | Every commit builds and passes `zig build test` and `zig fmt --check .`. See `CONTRIBUTING.md`. |
| Format with `zig fmt` | New lines stay within 100 columns and new functions within 70 lines (`perf-tidy`, below). A pass that is one step and longer says so: `// tidy: allow-fn(function-too-long) reason`. |

### Rejected in tiers 0 and 1

| Textbook rule | Why not | Instead |
|---|---|---|
| Polymorphism over switch: interfaces, vtables, virtual dispatch per node | An indirect call per row, and per-type code that hides the shape the loop could exploit. | A tag column and a table index or coefficient; one loop over all rows. |
| Encapsulate data behind accessors | Hides the layout, which is the thing that matters for speed. | Public columns. Invariants are documented and asserted, not hidden. |
| Methods that process one object | One call per node defeats SIMD and keeps the loop from seeing many rows. | Free functions over columns: `fn pass(cols: Columns, n: u32)`. |
| Split a loop into small per-row functions | Each split is a call boundary inside the hot loop, and the reader loses the loop. | The loop body stays whole; helpers are `inline` and operate on vectors. |
| Objects referring to each other by pointer | Pointers are 8 bytes, break when columns move, and chase memory. | `u32` indices; `none` (`0xffff_ffff`) for "no link". |

Tier 2 (widgets, themes) may use whatever reads best, as long as it is written only against the
public API of tiers 0 and 1.

## Rules specific to this project

- **Columns, not objects.** Per-node properties are struct-of-arrays columns grouped by the pass
  that reads them. Fields always read together form one row.
- **Explicit SIMD.** Passes with independent rows use
  `@Vector` over columns padded to whole vectors, with no scalar tail.
- **Branchless per-row loops.** Selects are masks, modes are coefficients or table indices,
  filtering is "write always, advance by 0 or 1". Only loop control may branch.
- **Measure before claiming.** A performance or size statement carries a number from a tool in
  `docs/CHECKS.md`.
- **Preserve behavior.** When changing a ported pass, retain the behavior captured by its regression tests and golden fixtures. The original source remains available for comparison. [Archived prototype](https://github.com/OmarSiwy/LCGF/tree/b6c1319/prototype)

A commit that breaks one of these needs a measured reason in its message.

## The performance guide's rules, and what checks each

The thirteen rules of *The Ultimate System-Level Performance Guide* (its kit:
github.com/OmarSiwy/OmarSiwy.github.io, `Resources/perf-kit`) apply to this repository. A rule
counts as followed when a check fails without it. Where the repository's own check is stronger
than the guide's text-level linter, that check is the gate.

| # | Rule | Checked by |
|---|---|---|
| 1 | Clean code: the reader sees what the machine does | `perf-tidy`: `function-too-long`, `line-too-long`, `recursion`; no per-node dispatch in tiers 0 and 1 (above) |
| 2 | API in layers, the caller enters where it can afford | The tiers of `docs/DESIGN.md`; the test `tier 0 alone`; `perf-tidy`: `too-many-parameters`, `bool-parameters` |
| 3 | Data laid out for the loop | Columns and `u32` indices; layout-size tests on every `extern` and `packed` type; bytes per node in `zig build bench` |
| 4 | Branchless on unpredictable data | The branch census over the compiled passes (`ci/run.sh census-src`), which counts real jumps where the linter reads text |
| 5 | Explicit SIMD | Tests at 2, 4, 8 and 16 lanes against scalar references (`lanes-*`); `perf-tidy`: `fixed-vector-width` |
| 6 | Independent work, in a core and across cores | `docs/perf/chains.md` for the latency chains; `perf-tidy`: `atomic-array-unpadded`, `seqcst-unjustified`, `float-reduction-single-chain` |
| 7 | Measured claims | `docs/CHECKS.md`; the release gates of `bench/gates/`, which publish losses too |
| 8 | Allocation by lifetime | Tiers 0 to 2 take no allocator: one caller-owned buffer, carved once (`mem.Carver`) |
| 9 | Hardware-aware algorithms | `docs/perf/cache.md`, `columns.md`; the frame benchmark's instruction and miss counts |
| 10 | Facts the compiler cannot prove | `perf-tidy`: `member-accumulator`, `inline-always-large`, `large-generic-function`; size and census builds name `-Dcpu=x86_64_v3` |
| 11 | Binary size | `gates.py size`: each example within 2% of its budget; the embedded flash budget (`ci/run.sh embedded`) |
| 12 | I/O in batches | The X11 and Wayland shells queue requests in one buffer and write it when it fills or a reply is needed; `perf-tidy`: `flush-in-loop`, `print-in-loop`, `unbuffered-writer` |
| 13 | A slow version and a machine to check the fast one | Differential and golden tests, `release-safe`, the fuzz jobs; `perf-tidy`: `missing-assertion`, `compound-assertion`, `swallowed-error`, `unbounded-loop` |

`perf-tidy` is the guide's linter, copied unchanged (`ci/perf_tidy.py`), run as a ratchet
(`zig build lint`, `ci/run.sh perf-tidy`): the code predates it, so `ci/perf_tidy_baseline.json`
records what it found per file and rule, and no count may grow. A new finding is fixed, or
silenced where it is with `// tidy: allow(rule) reason`; an allow without a reason is a finding.
Fewer is fine: lower the baseline in the same commit (`python3 ci/perf_tidy_gate.py --record src
build.zig`). Its strict rules for code marked `// tidy: hot` are not switched on: the census
already gates branches in the compiled passes, and the text-level rule cannot tell a `comptime`
test from a run-time one.
