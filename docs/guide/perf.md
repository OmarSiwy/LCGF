# Performance

What a frame costs, how to measure it, and what to do when it costs too much. Every number below
was measured with the tools of `docs/CHECKS.md` on commit e703492; the sizes in the two code
blocks are checked by `docs/guide/perf.zig`, which `zig build docs` runs.

Timings move with the machine and its load: compare runs on one machine, never across machines.
These were taken on an i9-14900HX (32 CPUs, not pinned) while other builds ran (1-minute load
average 15.6 to 18.2), ReleaseFast, 8 SIMD lanes, so treat them as an upper bound for this
machine. The bench job's baseline and gate are in `tools/bench/`; the per-change investigations
are in `docs/perf/`.

## Measure first

| Question | Command | What it prints |
|---|---|---|
| How long does a frame take, per pass? | `zig build bench` (`-- --scene NAME` for `bench/scenes/`) | median and p99 per pass, in microseconds |
| How much memory does the runtime front end take? | `Context.requiredBytes(limits)` | bytes, exactly; callable at compile time |
| Resident memory and idle wake-ups of a running UI | `zig build probe` | RSS after one frame, wake-ups in 2 s of idling |
| Binary size | `zig build size` | text, rodata, data and bss per example (ReleaseSmall) |
| Did a per-row loop gain a branch? | `zig build census-src-obj -Dcpu=x86_64_v3`, then `python3 tools/census/census.py zig-out/census_src.o --baseline tools/census/baseline-src.json` | conditional jumps per pass, against the baseline |
| Cache misses per pass | `nix develop .#bench`, see `docs/perf/cache.md` | hardware counters per pass |

## Frame time

`zig build bench`, scene `rows`: 3,961 nodes and 1,320 text runs, 3,000 frames, every frame
rebuilt from scratch.

| Pass | Median | p99 |
|---|---:|---:|
| begin + hit test | 2.3 µs | 4.2 µs |
| build (the application's `Frame` calls and the widgets) | 203.3 µs | 240.6 µs |
| layout | 161.0 µs | 302.7 µs |
| paint | 51.9 µs | 82.0 µs |
| whole frame | 418.1 µs | 626.7 µs |

Inside layout, the passes that follow parent links are the largest: `resolve.x` 35.4 µs,
`place` 31.7 µs, `resolve.y` 22.8 µs, against 3.4 µs for `prepare` and 0.5 µs for `measure`
(Mono). The smaller scenes of `bench/scenes/`, whole frame, median:

| Scene | Nodes | Text runs | Frame |
|---|---:|---:|---:|
| form | 200 | 67 | 30.6 µs |
| list | 144 | 70 | 16.3 µs |
| text | 184 | 180 | 23.1 µs |
| springs | 1,042 | 0 | 99.5 µs |
| resize | 184 | 180 | 25.0 µs |

The `idle` scene polls 3,000 times and builds 2 frames: after input stops, one settle frame, then
nothing.

**What to do with it.** Building is the largest share, and it is your code plus the widgets. A
subtree whose inputs did not change need not be built: wrap it in `Frame.reuse` with the signals
it reads (`docs/guide/runtime.md`), and it is copied from last frame instead, and kept out of
layout when it is a relayout boundary. The rest of a frame is linear in the number of nodes, so
fewer nodes is the other lever: build only the visible rows of a long list
(`widgets_vlist`).

## Not working when idle

`zig build probe` runs the `rows` scene for one frame and then idles: **0 wake-ups in 2 s**. The
host only builds a frame when `ctx.needsFrame(&in)` says so, and sleeps for `Output.wake`
seconds (`inf` when nothing is pending) with the reason in `Output.pace`. Springs, tweens and
timers keep it awake only while they run; under the accessibility setting `reduced_motion` they
jump to their end state and keep nothing awake.

## Memory

The runtime front end uses exactly the buffer you give `Context.init`, and its size is a linear
function of `Limits`:

```zig
const small = Context.requiredBytes(.{ .nodes = 4096 });
const large = Context.requiredBytes(.{ .nodes = 8192 });
try testing.expectEqual(1004 * 4096, large - small); // 1004 bytes per node
```

Two tree generations (this frame's, and last frame's for hit testing and reuse) take most of it;
`docs/perf/bytes.md` breaks the row down. At the default `Limits` (4,096 nodes, 1,024 text runs,
64 KB of text per frame) the buffer is 4,118,144 bytes; sized for the original example (1,024
nodes, 256 runs) it is 1,161,344. Size the limits to your UI: a limit hit in a frame is reported
in `Output.status`, never written past.

`zig build probe` measured **12,368 KiB resident** for the whole benchmark process after one
frame of the 3,961-node scene, its buffer included.

The comptime front end keeps the structure in read-only data (`ci/run.sh ct-rodata`: 5 tables in
`.rodata` in ReleaseSmall and ReleaseFast) and only the state and dirty masks in RAM:

```zig
const S = lcgf.signals.Signals(Mixer, mixer);
try testing.expectEqual(32, @sizeOf(Mixer));
try testing.expectEqual(u8, S.Mask); // 8 nodes, one bit each
try testing.expectEqual(40, @sizeOf(S.Runtime)); // the state, two masks, padding
```

A setter is one store and an OR with a constant (`ci/run.sh ct-setter`: `set_volume` is 6
instructions in ReleaseFast, ReleaseSmall and ReleaseSafe).

## Size

Run `nix develop -c zig build size -Dtarget=x86_64-linux -Dcpu=x86_64_v3` for the current ReleaseSmall section sizes of the production frame dumper and benchmark. At e703492 the original dumper measured 24,218 bytes of text and 9,920 bytes of rodata, and the benchmark measured 203,439 and 52,404 bytes, respectively. [Historical sources](https://github.com/OmarSiwy/LCGF/tree/e703492) The bare-metal example
(`ci/run.sh baremetal`, no OS) links to 113,478 bytes of text for Cortex-M7 and 203,862 for
RV32IMAC, with 663,680 bytes of bss (its framebuffer and buffers, all static).

## Rules the passes follow, and you can too

- **Columns and indices.** Per-node data is struct-of-arrays, linked by `u32` indices. Your own
  per-row data (a table's cells, a list's items) is fastest the same way.
- **Explicit SIMD.** Passes over independent rows use `@Vector` over columns padded to whole
  vectors (`simd.rows`, `simd.padded`). `-Dlanes=N` forces the lane count; CI tests 2, 4, 8 and 16.
- **No data-dependent branch in a per-row loop.** Use the selects in `lcgf.simd`; the census above
  is the check, and `docs/CHECKS.md` section 2 records where Zig 0.18 turned a select back into a
  branch and how that was removed.
- **Text.** Measuring is the expensive part of real text. `protocol.Cache` and
  `shape_cache` keep results across frames (`docs/guide/text.md`).
- **Repaint less.** `damage.cull(draw, region)` drops every quad that misses the changed region
  and records the region in `DrawList.damage`; the software back end's `redraw` then repaints
  only those rectangles, and `render_sw.tile` splits a frame into bands that threads can draw at
  once (`src/draw/damage.zig`, `src/render/sw/sw.zig`).
