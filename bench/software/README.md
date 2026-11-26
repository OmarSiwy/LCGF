# Software benchmark evidence

This directory preserves the final pre-packaging software measurements
described in [the performance report](../../docs/perf/software-optimizations.md).
The executable hashes and original absolute paths identify the historical
runs; those paths are not current reproduction commands. The upstream example
uses the same production runtime sources with updated build integration and
benchmark metadata. No new packaged-build timing run is claimed here.

| Directory | Contents |
|---|---|
| [results/static](results/static/) | 58 JSON files: full-frame/core/architecture raw runs, summaries, environment, and exact commands. |
| [results/retained](results/retained/) | 28 JSON files: incremental/reuse raw runs, per-frame validity counters, summaries, environment, and exact commands. |
| [results/borderless-ablation](results/borderless-ablation/) | 23 JSON files: five paired runs at each of two sizes, summary, commands, and untimed geometry inspection. |
| [reference-patches](reference-patches/README.md) | Original patches 01–03 reconstruct the previously optimized reference; a separate reversible patch reconstructs the ablation renderer. |

All 109 JSON files were copied byte-for-byte from the final
`architecture-lab-v2/evidence/v2/{static,retained,borderless-ablation}` results.
Intermediate experiments, binaries, unrelated validation logs, and full source
snapshots are excluded. The ablation source snapshot is represented by its
source difference instead. Invalid reference mixed-update reuse runs remain in
the raw JSON and are explicitly excluded from valid summary speed comparisons.

[provenance.json](provenance.json) records the upstream base, reference-patch
hashes, changed runtime-source hashes, and every copied JSON file's SHA-256.
Before importing these results, all 509 candidate files under `src/` were
compared by path and SHA-256 with the original measurement identity record;
every file matched. This records source identity at import time, not a promise
that future revisions will retain the same timing or source bytes.

For fresh runs use the
architecture-lab benchmark guide (`examples/architecture-lab/docs/BENCHMARKS.md` at `e0ad0404`).
Build both versions from the same packaged harness, finish compilation before
timing, preserve the full run range, and check equivalent output and updates
before interpreting a speed difference. Original raw reports predate the added
compiler/target/revision metadata in some packaged harnesses; they are retained
unchanged rather than presented as newly generated reports.
