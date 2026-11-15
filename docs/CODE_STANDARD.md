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
| Format with `zig fmt` | No other style rules for layout. |

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
- **Port, do not redesign.** Code that cites `prototype/` keeps the prototype's results.

A commit that breaks one of these needs a measured reason in its message.
