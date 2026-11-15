# Checks

The checks that were run on the prototype, how to repeat them, and what they printed. In the plan,
"Checks run earlier" refers to this file. Lanes `tools-*` turn these into CI jobs; until then, run
them by hand from `prototype/`.

The recorded numbers below were taken with Zig 0.17.1 on x86-64 Linux; the project now uses 0.18.0-dev.1151+8dfb7a7cc (see section 2 for the census on it). Timings came from a shared VM and move by
about a third between runs: compare runs on one machine, never across machines.

## 1. Tests

```
cd prototype
zig build test                                   # Debug, native CPU
zig build test -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseFast
zig build test -Dcpu=x86_64                      # 4 lanes
zig build test -Dcpu=x86_64_v3                   # 8 lanes
zig build cross                                  # compile only: aarch64-linux, aarch64-macos,
                                                 # x86_64-windows, wasm32-wasi, riscv64-linux
```

Expected: every step succeeds. `comptime_ui_probe.zig` prints its sizes to stderr
(`nodes=8 Index=u4 Runtime bytes=104 (state 32 + rects 64 + mask 1)`); the build runner echoes that
line and it is not a failure.

Lane counts 2 and 16 were checked by editing `simd.lanes` in a scratch copy of `ui.zig` (the std
width query never returns 16; see `ZIG_0_17_1.md`). All tests passed at both. The first `simd`
commit should make the lane count a build option so CI can do this without editing a file.

## 2. Branch census

```
cd prototype
zig build census-obj -Dcpu=x86_64_v3
python3 census.py zig-out/asm_probe.o
```

`asm_probe.zig` exports one function per pass; `census.py` disassembles them with `objdump` and
counts conditional jumps. Backward jumps are loop control. Recorded output:

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

On Zig 0.18.0-dev.1151+8dfb7a7cc (the move from 0.17.1) the census changed in three places, each
read in the disassembly and re-recorded in `tools/census/baseline.json` and `baseline-src.json`:
`p_push` and the ported `p_tree_push` (now in the src census) gained one `test`/`je` that skips
adding the root to its own child count: the compiler turned `fl * b01(i != 0)` back into a branch,
and an integer-mask rewrite gives the same code. It runs once per call, not inside a per-row loop,
and is taken only for row 0. `p_step` gained one remainder test after an unrolled vector loop
(loop control). No per-row loop gained a jump.

The selects are not enough on their own (found by lane simd, x86_64_v3). In a per-row loop where
one operand is loaded only for the select, `out[i] = simd.selU(c[i] > a[i], a[i], b[i])` compiles to
the same branches as a plain `if` (13 jumps, no cmov); with both operands already loaded for the
compare it is a cmov. Those branches span 0x36 bytes, past the census's 32-byte short-forward rule,
so they show only in the `jcc` column. The per-pass census against `tools/census/baseline.json` is
the gate, not the use of `simd` helpers. Prefer whole-vector selects (`@select` over `F`/`U`) in
batch loops.

## 3. Benchmark

```
cd prototype
zig build bench        # Linux only: it reads the monotonic clock through std.os.linux
```

A 330-row scene: 3,961 nodes, 1,320 text runs, 3,000 frames. Two recorded runs on the same VM core
(2.1 GHz Xeon, 8 lanes):

| Pass | Run A (median) | Run B (median) |
|---|---|---|
| begin + hit | 1.7 µs | 2.5 µs |
| build | 142 µs | 192 µs |
| layout | 163 µs | 225 µs |
| paint | 31 µs | 43 µs |
| whole frame | about 0.34 ms | about 0.46 ms |

The benchmark also prints a mean per layout pass (`measure`, `prepare`, `fit`, `resolve`, `wrap`,
`place`, `finalize`). `resolve` and `place` are the largest; they are the scalar, parent-following
passes.

## 4. GPU pixel check

```
cd prototype
zig build dump
./zig-out/bin/dump 3>quad.wgsl 4>quads.bin 5>glyphs.bin 6>cmds.txt
python3 render.py          # needs the Python package wgpu and any adapter (a software one is fine)
```

`dump` builds one frame and writes the shader text, the instance bytes and the command list exactly
as the renderer declares them. `render.py` draws that with a real wgpu device, including a host
pipeline for the `custom` command, reads the pixels back and compares eight of them. Recorded on
llvmpipe: all eight `ok`, 13 draw calls, picture in `wgpu-check.png`. This is the check that the WGSL
is valid and that `quad_attrs` matches the layout of `ui.Quad`.

## 5. API index

```
cd prototype
python3 mkindex.py         # rewrites API.md from ui.zig and ui_wgpu.zig
```

164 public functions and constants. Regenerate it when the public surface changes.

## 6. Compiler facts

```
python3 tools/zigcheck/zigcheck.py
```

70 small cases behind `docs/ZIG_0_17_1.md`. All agree on 0.17.1 and on 0.18.0-dev.1151+8dfb7a7cc (after the `bitpack` rename).
