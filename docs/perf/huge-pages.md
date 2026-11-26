# Huge pages for the column buffer (C0803)

The core never allocates: the caller hands `Context.init` (and the `Carver`s) one buffer. So huge
pages are the caller's choice, and the experiment is in the caller: `zig build bench -- --huge`
maps both column buffers (the prototype `Context`'s 3.3 MB and src's tables, 8 MB in all) with
`mmap`, 2 MB aligned, `madvise(MADV_HUGEPAGE)`, and touches them before the first frame. On this
machine transparent huge pages are in `madvise` mode; `/proc/PID/smaps_rollup` showed
`AnonHugePages: 8192 kB` for the bench with `--huge`, 0 without.

`zig build bench` (rows scene, 3,961 nodes), one binary run alternately without and with `--huge`,
five runs each, pinned to CPU 2 (P-core, i9-14900HX), load average 3.1 to 4.7 on 32 CPUs, medians:

| pass | 4 KB pages, runs (us) | median | huge pages, runs (us) | median |
|---|---|---|---|---|
| build | 124.1 124.2 124.4 125.4 126.3 | 124.4 | 107.2 108.5 108.9 116.1 117.3 | 108.9 (-12%) |
| layout | 150.6 150.7 150.8 150.8 154.1 | 150.8 | 149.3 149.4 149.6 149.8 160.1 | 149.6 (-1%) |
| paint | 37.6 37.8 37.8 38.0 39.6 | 37.8 | 37.3 37.3 37.4 37.7 41.6 | 37.4 (-1%) |
| frame | 314.8 314.9 315.2 316.7 320.9 | 315.2 | 296.2 297.7 298.1 306.5 316.0 | 298.1 (-5%) |

`perf stat` over a whole run: dTLB store misses 58,757 -> 1,124, dTLB load misses 2,269 -> 353,
cycles 13.50 G -> 13.25 G.

Build gains most: it writes about 50 columns per node, each in a different 4 KB page, so with 4 KB
pages every new row touches pages whose translations the second-level TLB no longer holds once the
working set passes its reach. The read-mostly passes stream few columns at a time and barely move.

Result: adopted as a recommendation for hosts, not as core code (tier 0 has no OS). A host that
can should allocate the buffer it gives `Context.init` from 2 MB huge pages; on Linux with THP in
`madvise` mode that is `mmap` + `madvise(MADV_HUGEPAGE)` as in `hugeBuffer` in bench/micro/bench.zig.
The gain is about 5% of a frame at 4,000 nodes; smaller trees fit the TLB without them.
