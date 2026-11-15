# Architecture

How the code is layered, and the one rule that keeps the layers apart. The decisions behind it are
in `docs/DESIGN.md`; the working code it came from is the header of `prototype/ui.zig`.

## The tier rule

**A tier uses only the tiers below it.** Code in tier N may import tiers 0 to N-1 and its own tier,
never a higher tier and never anything outside the tiers. Renderers and shells sit outside: they
read and write the core's data, and the core never imports them.

| Tier | What | May use | Directories |
|---|---|---|---|
| 0 | Plain data and free functions over columns. | `std.simd`, `std.math`, `std.mem`, and std parts that neither allocate nor touch the OS (`std.hash`, `std.fmt.comptimePrint`, `std.meta`). No allocator, no `std.Io`, no OS, no GPU. | `src/core/`, `src/layout/`, `src/interact/`, `src/draw/`, `src/text/`, `src/anim/`, `src/a11y/` (tree only) |
| 1 | Front ends. Each owns the columns and sequences the tier-0 passes. Runtime: `Context` / `Frame`. Comptime: `Ui(State, spec)`. | Tier 0 | `src/runtime/`, `src/comptime/` |
| 2 | Conveniences written only against the public API of tiers 0 and 1. | Tiers 0 and 1, public API only | `src/widgets/`, `src/theme/` |
| outside | Renderers consume a `DrawList`. Shells produce `Input` and present frames. | Any tier, plus their platform or GPU API | `src/render/*/`, `src/shell/*/` |

Two consequences:

- **Granularity.** Every tier-1 or tier-2 call can be replaced by a few tier-0 calls. The test
  `tier 0 alone` in `prototype/example.zig` keeps that true; the ported core keeps an equivalent.
- **Portability.** Because tier 0 touches no OS, it builds for any target Zig supports, including
  freestanding ones (the embedded profile).

## The frame, as data

```
Input ──► front end ──► Tree columns ──► layout passes ──► hit test / interaction
(shell)   (tier 1)      (tier 0, SoA,    prepare, fit,      (one SIMD sweep)
                         u32 indices)    resolve, place,
                                         finalize                 │
                                                                  ▼
host GPU pass ◄── renderer ◄── DrawList (flat commands) ◄── paint
(outside)         (outside)    (tier 0)                     (tier 0)
```

Every arrow is plain data owned by the caller. Nothing crosses a tier boundary as a callback: text
measurement, custom drawing and platform effects (cursor, clipboard, IME position) are rows and
commands that the host reads and answers.

## The package root

`src/lcgr.zig` is the root of the `lcgr` module. Each file under `src/` is exported there with one
line, `pub const name = @import("dir/name.zig");`. `zig build test` runs every test reachable from
the root, so a file that is not exported is neither compiled nor tested. Adding that line is the
only edit a lane makes outside its home.

## How the rule is checked

- Tier 0 files import only `std` and other tier-0 files; review rejects anything else.
- The cross-compile CI job builds the core for targets with no OS support it could lean on.
- Renderers and shells are built as separate modules that import `lcgr`, never the reverse.
