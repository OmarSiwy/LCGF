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

A job's header lines choose how it runs: `# shell: <name>` the Nix dev shell (`golden` has
wgpu-py on lavapipe, Xvfb, weston and Wine), `# all: no` leaves it out of `ci/run.sh all`, and
`# runner: windows|macos` the GitHub runner (default ubuntu).

## 2. Branch census

```sh
nix develop -c ci/run.sh census-src
```

The job builds `src/census_probes.zig` for `x86_64_v3`, disassembles the object with `objdump` and checks conditional jumps against `tools/census/baseline-src.json`. Backward jumps usually control loops. The table below records the original prototype census.

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
(`step`'s id under the pointer: the real row or a constant zero id). The recorded disassembly showed no additional per-row jump. The production limits live in `tools/census/baseline-src.json`.

The selects are not enough on their own (found by lane simd, x86_64_v3). In a per-row loop where
one operand is loaded only for the select, `out[i] = simd.selU(c[i] > a[i], a[i], b[i])` compiles to
the same branches as a plain `if` (13 jumps, no cmov); with both operands already loaded for the
compare it is a cmov. Those branches span 0x36 bytes, past the census's 32-byte short-forward rule,
so they show only in the `jcc` column. The production gate checks the per-pass counts in `tools/census/baseline-src.json`. Prefer whole-vector selects (`@select` over `F`/`U`) in
batch loops.

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

## 5. API index

```sh
nix develop -c ci/run.sh docs
```

`zig build docs` writes the public declarations exported by `src/lcgf.zig` to `zig-out/docs/API.md`. CI compares the result with the checked-in `docs/api/API.md` and verifies the guide examples.

## 6. Compiler facts

```
python3 tools/zigcheck/zigcheck.py
```

70 small cases behind `docs/ZIG_0_17_1.md`. All agree on 0.17.1 and on 0.18.0-dev.1151+8dfb7a7cc (after the `bitpack` rename).
